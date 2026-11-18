//  ISHFakefsMeta.m
//  dsh-go — Stage 2 native bridge layer. See ISHFakefsMeta.h.
//  SQL shape follows OpenMinis RootfsManager.swift (ensureFakefsMetadata,
//  removeFakefsPath, registerSubtreeInMetaDB); the statements below are
//  rewritten against the verified meta.db schema (see the header).

#import "ISHFakefsMeta.h"

#include <sqlite3.h>
#include <dirent.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>

// 16-byte stat blob; only the first 4 bytes (little-endian mode) are
// meaningful to fakefs. The rest are zero.
static void ish_meta_make_stat_blob(uint32_t mode, unsigned char out[16]) {
    memset(out, 0, 16);
    out[0] = (unsigned char)(mode & 0xFF);
    out[1] = (unsigned char)((mode >> 8) & 0xFF);
    out[2] = (unsigned char)((mode >> 16) & 0xFF);
    out[3] = (unsigned char)((mode >> 24) & 0xFF);
}

static sqlite3 *ish_meta_open(const char *metaDBPath) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"ISHFakefsMeta: sqlite3_open failed for %s: %s",
              metaDBPath, db ? sqlite3_errmsg(db) : "(null)");
        if (db) sqlite3_close(db);
        return NULL;
    }
    // (M-9) The kernel also writes meta.db; with the default busy
    // timeout of 0 a racing guest write fails host-side registration
    // at once with SQLITE_BUSY. Wait up to 5 s for the lock instead.
    sqlite3_busy_timeout(db, 5000);
    return db;
}

// Returns the inode for guestPath, -1 if the path is not registered,
// or -2 on a sqlite error (prepare/step failure). Callers must not
// treat -2 as "missing": it means the lookup itself failed.
static sqlite3_int64 ish_meta_lookup_inode(sqlite3 *db, const char *guestPath) {
    sqlite3_stmt *st = NULL;
    sqlite3_int64 inode = -1;
    if (sqlite3_prepare_v2(db, "SELECT inode FROM paths WHERE path = ?",
                           -1, &st, NULL) != SQLITE_OK) {
        NSLog(@"ISHFakefsMeta: prepare lookup failed: %s", sqlite3_errmsg(db));
        return -2;
    }
    sqlite3_bind_blob(st, 1, guestPath, (int)strlen(guestPath), SQLITE_TRANSIENT);
    int step = sqlite3_step(st);
    if (step == SQLITE_ROW) {
        inode = sqlite3_column_int64(st, 0);
    } else if (step != SQLITE_DONE) {
        NSLog(@"ISHFakefsMeta: lookup step failed for %s: %s",
              guestPath, sqlite3_errmsg(db));
        sqlite3_finalize(st);
        return -2;
    }
    sqlite3_finalize(st);
    return inode;
}

// Returns 1 and fills *modeOut with the recorded st_mode when guestPath
// has a paths row, 0 when it has none, -1 on a sqlite error. (R5-3-3)
// The walker uses this single query for both existence and the recorded
// type bits, so a host-side type change (symlink <-> regular file,
// file <-> dir) is not silently skipped.
static int ish_meta_lookup_mode(sqlite3 *db, const char *guestPath,
                                uint32_t *modeOut) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db,
                           "SELECT s.stat FROM stats s "
                           "JOIN paths p ON p.inode = s.inode "
                           "WHERE p.path = ?",
                           -1, &st, NULL) != SQLITE_OK) {
        NSLog(@"ISHFakefsMeta: prepare mode lookup failed: %s", sqlite3_errmsg(db));
        return -1;
    }
    sqlite3_bind_blob(st, 1, guestPath, (int)strlen(guestPath), SQLITE_TRANSIENT);
    int step = sqlite3_step(st);
    int rc = -1;
    if (step == SQLITE_ROW) {
        const void *blob = sqlite3_column_blob(st, 0);
        int nbytes = sqlite3_column_bytes(st, 0);
        if (blob != NULL && nbytes >= 4) {
            const unsigned char *b = (const unsigned char *)blob;
            *modeOut = (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
                       ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
            rc = 1;
        } else {
            NSLog(@"ISHFakefsMeta: short stat blob for %s", guestPath);
        }
    } else if (step == SQLITE_DONE) {
        rc = 0;
    } else {
        NSLog(@"ISHFakefsMeta: mode lookup step failed for %s: %s",
              guestPath, sqlite3_errmsg(db));
    }
    sqlite3_finalize(st);
    return rc;
}

// Same 1/0/-1 contract as ish_meta_lookup_mode, opening its own
// connection like ish_fakefs_meta_path_exists.
static int ish_meta_path_mode(const char *metaDBPath, const char *guestPath,
                              uint32_t *modeOut) {
    sqlite3 *db = ish_meta_open(metaDBPath);
    if (!db) return -1;
    int rc = ish_meta_lookup_mode(db, guestPath, modeOut);
    sqlite3_close(db);
    return rc;
}

int ish_fakefs_meta_register_path(const char *metaDBPath,
                                  const char *guestPath,
                                  uint32_t mode) {
    if (!metaDBPath || !guestPath || guestPath[0] != '/') return -1;
    sqlite3 *db = ish_meta_open(metaDBPath);
    if (!db) return -1;
    unsigned char statBlob[16];
    ish_meta_make_stat_blob(mode, statBlob);
    int rc = -1;
    sqlite3_int64 inode = ish_meta_lookup_inode(db, guestPath);
    if (inode >= 0) {
        // Path exists: update its stat mode in place.
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "UPDATE stats SET stat = ? WHERE inode = ?",
                               -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(st, 1, statBlob, 16, SQLITE_TRANSIENT);
            sqlite3_bind_int64(st, 2, inode);
            if (sqlite3_step(st) == SQLITE_DONE) rc = 0;
            else NSLog(@"ISHFakefsMeta: UPDATE stats failed for %s: %s",
                       guestPath, sqlite3_errmsg(db));
        } else {
            NSLog(@"ISHFakefsMeta: prepare UPDATE failed: %s", sqlite3_errmsg(db));
        }
        sqlite3_finalize(st);
    } else {
        // New path: INSERT stat, then INSERT path with the new rowid.
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "INSERT INTO stats (stat) VALUES (?)",
                               -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(st, 1, statBlob, 16, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_DONE) {
                sqlite3_int64 newInode = sqlite3_last_insert_rowid(db);
                sqlite3_finalize(st);
                st = NULL;
                if (sqlite3_prepare_v2(
                        db, "INSERT OR REPLACE INTO paths (path, inode) VALUES (?, ?)",
                        -1, &st, NULL) == SQLITE_OK) {
                    sqlite3_bind_blob(st, 1, guestPath, (int)strlen(guestPath),
                                      SQLITE_TRANSIENT);
                    sqlite3_bind_int64(st, 2, newInode);
                    if (sqlite3_step(st) == SQLITE_DONE) rc = 0;
                    else NSLog(@"ISHFakefsMeta: INSERT paths failed for %s: %s",
                               guestPath, sqlite3_errmsg(db));
                } else {
                    NSLog(@"ISHFakefsMeta: prepare INSERT paths failed: %s",
                          sqlite3_errmsg(db));
                }
            } else {
                NSLog(@"ISHFakefsMeta: INSERT stats failed for %s: %s",
                      guestPath, sqlite3_errmsg(db));
            }
        } else {
            NSLog(@"ISHFakefsMeta: prepare INSERT stats failed: %s",
                  sqlite3_errmsg(db));
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return rc;
}

int ish_fakefs_meta_ensure_parents(const char *metaDBPath,
                                   const char *guestPath) {
    if (!metaDBPath || !guestPath || guestPath[0] != '/') return -1;
    // Collect ancestors from "/" down to the parent of guestPath.
    // guestPath "/a/b/c" -> parents "/a", "/a/b" ("/" itself is implicit
    // in the shipped meta.db; registering it is harmless but skipped).
    char buf[PATH_MAX];
    size_t len = strlen(guestPath);
    if (len >= sizeof(buf)) return -1;
    memcpy(buf, guestPath, len + 1);
    // Strip the last component to get the parent chain.
    char *slash = strrchr(buf, '/');
    if (slash == buf) return 0; // parent is "/" — nothing to do.
    if (slash) *slash = '\0';
    // Walk each prefix: "/a", "/a/b", ...
    for (char *p = buf + 1; ; p++) {
        if (*p == '/' || *p == '\0') {
            char save = *p;
            *p = '\0';
            // (R4-3-1) Skip ancestors that are already registered:
            // blindly UPDATE-ing them to 040755 would clobber a
            // factory mode if a future mount point lands under a
            // special-mode directory (e.g. /tmp 1777, /root 0700).
            // register_path itself is untouched — bind mounts still
            // rely on its UPDATE semantics (ISHKernel.m).
            // (R5-3-2) path_exists returns 1 for an existing row,
            // 0 for missing, -1 on a sqlite error. A -1 is a failed
            // check, not a missing ancestor: fail instead of falling
            // through to register_path, whose retry could UPDATE a
            // factory row after a transient error (e.g. SQLITE_BUSY).
            int exists = ish_fakefs_meta_path_exists(metaDBPath, buf);
            if (exists < 0) {
                *p = save;
                return -1;
            }
            if (exists != 1) {
                int rc = ish_fakefs_meta_register_path(metaDBPath, buf, 0040755);
                if (rc != 0) {
                    *p = save;
                    return -1;
                }
            }
            *p = save;
            if (save == '\0') break;
        }
    }
    return 0;
}

int ish_fakefs_meta_remove_path(const char *metaDBPath,
                                const char *guestPath) {
    if (!metaDBPath || !guestPath || guestPath[0] != '/') return -1;
    sqlite3 *db = ish_meta_open(metaDBPath);
    if (!db) return -1;
    int rc = -1;
    // Exact path, or any path under it with a "/" boundary ("/foo" removes
    // "/foo/bar" but not "/foobar").
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(
            db,
            "DELETE FROM paths WHERE path = ?1 "
            "OR substr(path, 1, length(?1) + 1) = ?1 || '/'",
            -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_blob(st, 1, guestPath, (int)strlen(guestPath),
                          SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_DONE) rc = 0;
        else NSLog(@"ISHFakefsMeta: DELETE paths failed for %s: %s",
                   guestPath, sqlite3_errmsg(db));
    } else {
        NSLog(@"ISHFakefsMeta: prepare DELETE paths failed: %s",
              sqlite3_errmsg(db));
    }
    sqlite3_finalize(st);
    if (rc == 0) {
        // meta.db has no FK cascade: drop stats rows nothing references.
        char *errmsg = NULL;
        if (sqlite3_exec(db,
                         "DELETE FROM stats WHERE inode NOT IN "
                         "(SELECT inode FROM paths)",
                         NULL, NULL, &errmsg) != SQLITE_OK) {
            NSLog(@"ISHFakefsMeta: orphan stats cleanup failed: %s",
                  errmsg ? errmsg : "(null)");
            if (errmsg) sqlite3_free(errmsg);
            rc = -1;
        }
    }
    sqlite3_close(db);
    return rc;
}

// Recursive walker for register_subtree. `rel` is the path relative to
// hostRoot ("" for the root itself); guestPrefix is absolute.
static int ish_meta_register_tree(const char *metaDBPath,
                                  const char *hostRoot,
                                  const char *guestPrefix,
                                  const char *rel) {
    char hostPath[PATH_MAX];
    char guestPath[PATH_MAX];
    if (rel[0] == '\0') {
        if (snprintf(hostPath, sizeof(hostPath), "%s", hostRoot) >= (int)sizeof(hostPath)) return -1;
        if (snprintf(guestPath, sizeof(guestPath), "%s", guestPrefix) >= (int)sizeof(guestPath)) return -1;
    } else {
        if (snprintf(hostPath, sizeof(hostPath), "%s/%s", hostRoot, rel) >= (int)sizeof(hostPath)) return -1;
        // (R5-3-1) Pick the join format by the prefix's trailing slash:
        // guestPrefix "/" + "bin" must be "/bin", not "//bin" (the
        // kernel matches paths byte-exactly, so "//..." rows are dead
        // rows the guest never sees). "/root" has no trailing slash
        // and still joins as "/root/...".
        if (guestPrefix[strlen(guestPrefix) - 1] == '/') {
            if (snprintf(guestPath, sizeof(guestPath), "%s%s", guestPrefix, rel) >= (int)sizeof(guestPath)) return -1;
        } else {
            if (snprintf(guestPath, sizeof(guestPath), "%s/%s", guestPrefix, rel) >= (int)sizeof(guestPath)) return -1;
        }
    }
    struct stat st;
    if (lstat(hostPath, &st) != 0) {
        NSLog(@"ISHFakefsMeta: lstat failed for %s", hostPath);
        return -1;
    }
    // (R4-3-1) Only INSERT rows that are missing. The host mode comes
    // from extract(), which flattens every file to 0660 and stores
    // symlinks as regular files, so UPDATE-ing an existing row would
    // clobber the shipped mode (+x bits, symlink type) in meta.db.
    // The skip is per-node: a directory that already exists is still
    // recursed into, so missing children are INSERTed below it.
    // register_path itself is untouched — bind mounts rely on its
    // UPDATE semantics (ISHKernel.m).
    // (R5-3-1) The root node of a "/" walk is guest path "/" itself,
    // which the kernel never looks up (it uses "" for the root, as in
    // the shipped meta.db), so do not register it; still recurse below.
    // (R5-3-2) A lookup error (-1) fails the walk instead of falling
    // through to register_path: a transient error (e.g. SQLITE_BUSY)
    // followed by a successful register_path retry would UPDATE a
    // factory row. (R5-3-3) A row whose recorded type bits differ from
    // the host lstat type is not skipped — it falls through to
    // register_path, whose UPDATE corrects the type.
    if (!(rel[0] == '\0' && strcmp(guestPath, "/") == 0)) {
        uint32_t recordedMode = 0;
        int exists = ish_meta_path_mode(metaDBPath, guestPath, &recordedMode);
        if (exists < 0) {
            return -1;
        }
        if (exists == 0 ||
            (recordedMode & S_IFMT) != (st.st_mode & S_IFMT)) {
            if (ish_fakefs_meta_register_path(metaDBPath, guestPath,
                                              (uint32_t)st.st_mode) != 0) {
                return -1;
            }
        }
    }
    if (!S_ISDIR(st.st_mode)) return 0;
    DIR *dir = opendir(hostPath);
    if (!dir) {
        NSLog(@"ISHFakefsMeta: opendir failed for %s", hostPath);
        return -1;
    }
    struct dirent *ent;
    int rc = 0;
    while (rc == 0 && (ent = readdir(dir)) != NULL) {
        if (ent->d_name[0] == '.' &&
            (ent->d_name[1] == '\0' ||
             (ent->d_name[1] == '.' && ent->d_name[2] == '\0'))) {
            continue;
        }
        char childRel[PATH_MAX];
        if (rel[0] == '\0') {
            if (snprintf(childRel, sizeof(childRel), "%s", ent->d_name) >= (int)sizeof(childRel)) { rc = -1; break; }
        } else {
            if (snprintf(childRel, sizeof(childRel), "%s/%s", rel, ent->d_name) >= (int)sizeof(childRel)) { rc = -1; break; }
        }
        rc = ish_meta_register_tree(metaDBPath, hostRoot, guestPrefix, childRel);
    }
    closedir(dir);
    return rc;
}

int ish_fakefs_meta_register_subtree(const char *metaDBPath,
                                     const char *hostRoot,
                                     const char *guestPrefix) {
    if (!metaDBPath || !hostRoot || !guestPrefix || guestPrefix[0] != '/') return -1;
    return ish_meta_register_tree(metaDBPath, hostRoot, guestPrefix, "");
}

int ish_fakefs_meta_path_exists(const char *metaDBPath,
                                const char *guestPath) {
    if (!metaDBPath || !guestPath || guestPath[0] != '/') return -1;
    sqlite3 *db = ish_meta_open(metaDBPath);
    if (!db) return -1;
    // (R5-3-2) ish_meta_lookup_inode returns -2 on a sqlite error,
    // -1 when there is no row: only the latter is "missing" (0).
    // An error returns -1, matching the .h contract, so callers fail
    // instead of treating a failed check as a missing path.
    sqlite3_int64 inode = ish_meta_lookup_inode(db, guestPath);
    sqlite3_close(db);
    if (inode == -2) return -1;
    return inode >= 0 ? 1 : 0;
}
