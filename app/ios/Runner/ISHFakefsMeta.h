//  ISHFakefsMeta.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1/2.2).
//
//  Thin C wrapper over the fakefs `meta.db` (SQLite) for host-side
//  registration of paths the kernel must see. Mechanism follows OpenMinis
//  `RootfsManager.swift` (ensureFakefsMetadata / ensureParentDirsInMetaDB /
//  removeFakefsPath / registerSubtreeInMetaDB), rewritten in C so both the
//  ObjC kernel (bind mounts) and the Swift RootfsManager can share one
//  implementation instead of duplicating the SQL.
//
//  Schema (verified against the shipped alpine-rootfs.zip meta.db):
//    meta  (id integer unique default 0, db_inode integer)
//    stats (inode integer primary key, stat blob)
//    paths (path blob primary key, inode integer references stats(inode))
//    index inode_to_path on paths (inode, path)
//  The stat blob is 16 bytes; its first 4 bytes are the little-endian
//  mode (directory 0o040755, regular file 0o100644, symlink 0o120777).
//  The rowid of a stats row IS its inode (paths.inode references it).
//
//  Threading: each call opens its own sqlite3 connection, so callers may
//  use these from any queue. Calls are NOT atomic across processes — the
//  kernel is the only other meta.db writer and it holds its own
//  transactions; a host-side registration racing a guest write to the
//  same path can lose (last writer wins on the stat row).
//
//  Link requirement (stage 4): libsqlite3.tbd.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Register one guest path in meta.db (creating parent entries is the
/// caller's job — see ish_fakefs_meta_ensure_parents). If the path
/// already exists, its stat mode is updated — or, when its stats row
/// is missing (orphan paths row), the stats row is re-created under
/// the same inode; otherwise a new stats row
/// (inode = last_insert_rowid) and paths row are inserted.
/// `guestPath` must be absolute (leading "/"), already normalized.
/// `mode` is the full st_mode value (type bits + perms), e.g. 0o040755
/// for a directory, 0o100644 for a file. Returns 0 on success, -1 on
/// any sqlite error (the error is logged).
int ish_fakefs_meta_register_path(const char *metaDBPath,
                                  const char *guestPath,
                                  uint32_t mode);

/// Register a guest path and every ancestor directory up to "/" in
/// meta.db (newly registered directories get mode 0o040755;
/// already-registered ancestors keep their recorded mode).
/// Idempotent. Returns 0 on success, -1 on any sqlite error.
int ish_fakefs_meta_ensure_parents(const char *metaDBPath,
                                   const char *guestPath);

/// Remove a guest path and its whole subtree from meta.db, then delete
/// orphan stats rows (meta.db has no FK cascade). `guestPath` is matched
/// exactly and as a "/-bounded prefix (so "/foo" removes "/foo/bar" but
/// not "/foobar"). Returns 0 on success, -1 on any sqlite error.
int ish_fakefs_meta_remove_path(const char *metaDBPath,
                                const char *guestPath);

/// Delete dead paths rows whose guest path starts with "//" (left by
/// pre-R5-3-1 walks, which registered the tree under "//..."), and rows
/// with a trailing slash (e.g. '/root/', matched by GLOB '?*/'); the "/"
/// row is never deleted. Then delete orphan stats rows (meta.db has no
/// FK cascade). No-op on a clean database. Returns 0 on success, -1 on
/// any sqlite error.
int ish_fakefs_meta_prune_dead_paths(const char *metaDBPath);

/// Recursively register a host directory tree under a guest prefix:
/// every entry found under `hostRoot` (via lstat, so symlinks keep
/// their link mode) is registered at `guestPrefix` + relative path,
/// with its real st_mode — but only when it has no row yet: an entry
/// already in meta.db keeps its recorded mode, so re-registration
/// never clobbers the shipped modes (+x bits, symlink type) with the
/// flattened host mode. The one exception (R6-3-1) is a row recorded
/// as a non-directory whose host entry is a directory: a host
/// directory is always a guest directory, so that row is updated to
/// a directory. No other recorded type is ever overwritten, because
/// host lstat cannot express guest types: fakefs stores symlinks
/// (and fifo/socket/device nodes) as plain host files and only the
/// meta.db row carries the guest type (see GuestRootfsArchive:
/// "No symlinks are made on the host."). `guestPrefix` must be an
/// absolute, normalized path (no trailing slash; the root is "/");
/// `hostRoot` must be an absolute host path.
/// Returns 0 on success, -1 on the first error encountered (entries
/// registered before the failure stay registered).
int ish_fakefs_meta_register_subtree(const char *metaDBPath,
                                     const char *hostRoot,
                                     const char *guestPrefix);

/// Whether `guestPath` is registered in meta.db. Returns 1 when it is,
/// 0 when it is not, -1 on a sqlite error (including a missing or
/// unreadable meta.db). Used by RootfsManager to verify the shipped
/// meta.db is intact (sentinel "/bin/sh") before boot.
int ish_fakefs_meta_path_exists(const char *metaDBPath,
                                const char *guestPath);

NS_ASSUME_NONNULL_END
