#!/usr/bin/env python3
# ============================================================================
# install-rootfs-packages.py — add extra Alpine packages to an iSH fakefs
# rootfs (dsh-go)
# ============================================================================
# Installs the packages listed in rootfs-packages.txt into the fakefs data
# tree that prepare-rootfs.sh just built with fakefsify, so the shipped
# Alpine sandbox has them preinstalled (bash, Python 3.12, ripgrep, curl).
#
# What it does, in order:
#   1. Downloads APKINDEX.tar.gz (main + community) for the pinned Alpine
#      version/arch and resolves the full dependency closure. Packages
#      already in the base rootfs (the 15 minirootfs packages) count as
#      satisfied. Top-level packages pinned as `name=version` in the list
#      file must resolve to exactly that version, or the run fails loudly.
#   2. Downloads each .apk (HTTPS, into the cache dir) and verifies the
#      download size against the index `S:` field and the .PKGINFO
#      name/version against the expected package.
#   3. Extracts each .apk into the data tree (skipping .PKGINFO, .SIGN.*
#      and install scripts), preserving modes. Symlinks are written as
#      fakefs-style regular files whose content is the link target
#      (exactly like fakefsify does for the base image) — NOT real host
#      symlinks, because `zip` (without -y) dereferences those and stores
#      the target's content, which the guest kernel would then read as a
#      (garbage) link target. GNU packages (coreutils, grep, sed,
#      findutils, procps-ng, util-linux-misc, binutils) ship real files
#      at paths where the base image has BusyBox applet symlinks
#      (e.g. /bin/ls, /bin/grep, /bin/sed) — those are TAKEN OVER in place:
#      the installer overwrites the busybox symlink file with the real
#      binary, updates that path's meta.db row to a regular file (same
#      inode), and prunes the path from the old owner's installed-db
#      entry (busybox). Takeover is allowed ONLY when the existing path
#      is a symlink whose on-disk content is exactly "/bin/busybox";
#      any other collision is a hard error. Hardlinks (binutils/gcc ship
#      ld, ar, ... as hardlinks to the target-prefixed binaries) are
#      stored as real copies of the target's content — the guest fakefs
#      has no link-count concept in meta.db (one inode per path), so
#      only st_nlink/inode differ, which nothing here relies on; the
#      apk db records them as regular files with the content checksum,
#      like real apk does. Install scripts
#      (.pre-install/.post-install/.pre-upgrade/.post-upgrade/.trigger)
#      are collected into lib/apk/db/scripts.tar (named
#      `<pkg>-<ver>.<C>.<type>`, the apk convention) — they are NOT run
#      at build time. The only script with a build-time effect is bash's
#      post-install (`add-shell /bin/bash`), which this script replicates
#      directly by appending /bin/bash to etc/shells.
#   4. Writes lib/apk/db/installed entries for the new packages (metadata
#      copied verbatim from APKINDEX; file list from the tar; file
#      checksums Z: as Q1+base64(SHA1(content)) for files and
#      Q1+base64(SHA1(raw linkname)) for symlinks — the raw target exactly
#      as stored in the tar, NOT resolved to an absolute path; verified
#      against the base rootfs db, where all 32 base symlinks match raw)
#      and merges the top-level packages into /etc/apk/world (the real
#      world-file location).
#   5. Updates the fakefs meta.db (sibling of data/): inserts a paths row
#      (absolute path -> new inode) and a stats row (inode -> 16-byte
#      struct ish_stat {mode, uid, gid, rdev}) for every new file, dir
#      and symlink. For a busybox-symlink takeover (see step 3) the
#      existing row is UPDATED in place (same inode, new mode) instead of
#      a new row being inserted. This is REQUIRED: the kernel's
#      fakefs_rebuild only re-indexes paths already in the db — files added
#      to data/ without a db row are invisible to the guest. New inodes
#      continue from max(inode)+1 in deterministic (path-sorted) order.
#      The meta table (db_inode) is left alone: the kernel sets it on
#      first mount.
#   6. Writes the resolved lock file (all packages as name=version).
#      Also prunes taken-over paths from the previous owner's installed-db
#      entry, so no path is claimed by two packages (apk verify stays
#      clean).
#
# Determinism: every output is produced in sorted order from pinned
# inputs, so the same package list yields the same rootfs zip. The only
# live input is APKINDEX (dependency versions can drift); the lock file
# records exactly what was installed, and prepare-rootfs.sh records the
# lock hash in the manifest.
#
# Idempotent: packages already present in the installed db are skipped
# (files + db rows + meta.db rows are assumed present from the first run).
#
# Usage:
#   install-rootfs-packages.py --data-dir <fakefs data tree>
#       --packages <rootfs-packages.txt> [--mirror URL] [--version 3.21]
#       [--arch aarch64] [--cache-dir DIR] [--lock-file PATH]
#
# Requires: python3 (stdlib only), network access to the Alpine mirror.
# ============================================================================
import argparse
import base64
import hashlib
import io
import os
import re
import sqlite3
import struct
import sys
import tarfile
import urllib.request

# apk db file checksum: "Q1" + base64(SHA1(bytes)). Verified against the
# base rootfs db (3 regular files + the /bin/sh symlink).
def apk_checksum(data: bytes) -> str:
    return "Q1" + base64.b64encode(hashlib.sha1(data).digest()).decode("ascii")

def parse_db_raw(path):
    """Parse an installed-db file into {name: raw entry text} preserving the
    file-list lines verbatim. Entries are blank-line separated."""
    text = open(path, encoding="utf-8", errors="replace").read()
    entries = {}
    order = []
    for chunk in text.split("\n\n"):
        chunk = chunk.strip("\n")
        if not chunk:
            continue
        name = None
        for line in chunk.split("\n"):
            if line.startswith("P:"):
                name = line[2:]
                break
        if name:
            entries[name] = chunk + "\n"
            order.append(name)
    return entries, order

def parse_index_bytes(data: bytes):
    pkgs = {}
    cur = {}
    for line in data.decode("utf-8", errors="replace").split("\n"):
        if not line:
            if cur.get("P"):
                pkgs[cur["P"]] = cur
            cur = {}
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            cur[k] = v
    if cur.get("P"):
        pkgs[cur["P"]] = cur
    return pkgs

def dep_key(dep):
    """Dependency token -> lookup key (so:/pc:/cmd: keep prefix, else name)."""
    m = re.match(r"^((?:so|pc|cmd):[^=<>~\s]+|[A-Za-z0-9_+\-.]+)", dep)
    return m.group(1) if m else dep

def resolve(targets, pins, allpkgs, provides, installed):
    """BFS dependency closure. Returns list of APKINDEX entries (sorted)."""
    seen = set()
    result = []
    queue = list(targets)
    while queue:
        dep = queue.pop(0)
        if dep.startswith("!"):
            continue
        key = dep_key(dep)
        if key in installed or key in seen:
            continue
        if key in provides and provides[key] in installed:
            continue
        pkg = allpkgs.get(key) or allpkgs.get(provides.get(key, ""))
        if pkg is None:
            raise SystemExit(f"error: unresolved dependency {dep!r} (no such package/provides)")
        pname = pkg["P"]
        if pname in seen:
            continue
        if pname in pins and pkg["V"] != pins[pname]:
            raise SystemExit(
                f"error: {pname} resolved to {pkg['V']} but rootfs-packages.txt "
                f"pins {pins[pname]} — update the pin or the repo moved"
            )
        seen.add(pname)
        result.append(pkg)
        queue.extend(d for d in pkg.get("D", "").split() if not d.startswith("!"))
    return sorted(result, key=lambda p: p["P"])

def download(url, dest):
    if os.path.exists(dest):
        return
    tmp = dest + ".tmp"
    urllib.request.urlretrieve(url, tmp)
    os.rename(tmp, dest)

def read_pkginfo(apk_path):
    """Return the .PKGINFO dict of a .apk file."""
    with tarfile.open(apk_path, "r:gz") as tf:
        try:
            m = tf.getmember(".PKGINFO")
        except KeyError:
            raise SystemExit(f"error: {apk_path} has no .PKGINFO")
        raw = tf.extractfile(m).read().decode("utf-8", errors="replace")
    info = {}
    for line in raw.split("\n"):
        if " = " in line:
            k, v = line.split(" = ", 1)
            info[k.strip()] = v.strip()
    return info

def _check_takeover(dest, abs_path_b, existing_modes, takeover_paths):
    """Gate for overwriting an existing meta.db path with a new package
    file. Allowed ONLY when the existing path is a BusyBox applet symlink
    (meta.db mode symlink, on-disk fakefs-style file whose content is
    exactly b"/bin/busybox"). Anything else is a hard error — the new
    package would silently clobber a real file owned by the base image
    or another package. Also errors if another package in this same run
    already took the path over."""
    if abs_path_b in takeover_paths:
        raise SystemExit(f"error: {abs_path_b.decode()!r} is taken over by two "
                         "packages in this run — refusing to overwrite")
    mode = existing_modes[abs_path_b]
    if mode & 0o170000 != 0o120000:
        raise SystemExit(f"error: {abs_path_b.decode()!r} already exists in meta.db "
                         "as a non-symlink — refusing to overwrite")
    try:
        with open(dest, "rb") as f:
            content = f.read()
    except OSError as e:
        raise SystemExit(f"error: cannot read existing {abs_path_b.decode()!r}: {e}")
    if content != b"/bin/busybox":
        raise SystemExit(f"error: {abs_path_b.decode()!r} already exists in meta.db "
                         f"as a symlink to {content!r} (not /bin/busybox) — refusing "
                         "to overwrite")

def prune_takeovers(merged, takeover_paths):
    """Remove taken-over paths from the previous owner's installed-db
    entry, so no path is claimed by two packages (apk verify stays
    clean). takeover_paths are absolute-path bytes (b"/bin/ls"); db
    entries list files as F:<dir> / R:<base> pairs. Dropped: the R: line
    plus its following a:/Z: lines. F: lines are kept (apk lists empty
    dirs too)."""
    pruned = {}
    for name, entry in merged.items():
        lines = entry.split("\n")
        out = []
        cur_dir = None
        skip_rest = False  # dropping the a:/Z: lines after a pruned R:
        for line in lines:
            if line.startswith("F:"):
                cur_dir = line[2:]
                skip_rest = False
                out.append(line)
                continue
            if line.startswith("R:"):
                base = line[2:]
                full = (cur_dir + "/" + base) if cur_dir else base
                if ("/" + full).encode() in takeover_paths:
                    skip_rest = True
                    continue  # drop the R: line
                skip_rest = False
                out.append(line)
                continue
            if skip_rest and (line.startswith("a:") or line.startswith("Z:")):
                continue  # drop the checksum/perm lines of a pruned R:
            skip_rest = False
            out.append(line)
        pruned[name] = "\n".join(out)
    return pruned

SCRIPT_TYPES = (".pre-install", ".post-install", ".pre-upgrade", ".post-upgrade",
                ".pre-deinstall", ".post-deinstall", ".trigger")

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--data-dir", required=True, help="fakefs data tree (…/alpine-rootfs/data)")
    ap.add_argument("--packages", required=True, help="package list file (name or name=version per line)")
    ap.add_argument("--mirror", default="https://dl-cdn.alpinelinux.org/alpine")
    ap.add_argument("--version", default="3.21")
    ap.add_argument("--arch", default="aarch64")
    ap.add_argument("--cache-dir", default=None)
    ap.add_argument("--lock-file", default=None)
    args = ap.parse_args()

    data_dir = args.data_dir.rstrip("/")
    if not os.path.isdir(os.path.join(data_dir, "lib", "apk", "db")):
        raise SystemExit(f"error: {data_dir} does not look like a fakefs data tree (no lib/apk/db)")
    cache_dir = args.cache_dir or os.path.join(os.path.dirname(data_dir), ".pkg-cache")
    os.makedirs(cache_dir, exist_ok=True)

    # --- 1. package list ---
    targets, pins = [], {}
    for line in open(args.packages, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" in line:
            name, ver = line.split("=", 1)
            targets.append(name.strip())
            pins[name.strip()] = ver.strip()
        else:
            targets.append(line)
    if not targets:
        raise SystemExit("error: no packages listed in " + args.packages)
    print(f"top-level packages: {', '.join(targets)}")

    # --- 2. APKINDEX (main + community) ---
    allpkgs = {}
    for repo in ("main", "community"):
        url = f"{args.mirror}/v{args.version}/{repo}/{args.arch}/APKINDEX.tar.gz"
        dest = os.path.join(cache_dir, f"APKINDEX-{repo}.tar.gz")
        print(f"downloading {url}")
        download(url, dest)
        with tarfile.open(dest, "r:gz") as tf:
            raw = tf.extractfile("APKINDEX").read()
        allpkgs.update(parse_index_bytes(raw))
    print(f"index: {len(allpkgs)} packages")

    # --- 3. already-installed set (base rootfs) + provides map ---
    # The installed db is kept as raw entry text (existing entries are
    # written back verbatim); a parsed copy is used for dependency checks.
    installed_db_path = os.path.join(data_dir, "lib", "apk", "db", "installed")
    installed_raw, _ = parse_db_raw(installed_db_path)
    installed = parse_index_bytes(
        "\n\n".join(installed_raw.values()).encode("utf-8"))
    provides = {}
    for name, p in allpkgs.items():
        provides.setdefault(name, name)
        for prov in p.get("p", "").split():
            provides.setdefault(prov.split("=")[0], name)
    for name, p in installed.items():
        for prov in p.get("p", "").split():
            provides.setdefault(prov.split("=")[0], name)
    print(f"already installed: {len(installed)} packages")

    # --- 4. resolve closure ---
    to_install = resolve(targets, pins, allpkgs, provides, set(installed))
    # skip packages already installed (idempotent re-run)
    to_install = [p for p in to_install if p["P"] not in installed]
    if not to_install:
        print("all packages already installed, nothing to do")
        return 0
    total_inst = sum(int(p["I"]) for p in to_install)
    print(f"installing {len(to_install)} packages "
          f"({total_inst // 1024} KiB installed):")
    for p in to_install:
        print(f"  {p['P']} {p['V']}")

    # --- 5. download .apk files, verify size + .PKGINFO ---
    apk_paths = {}
    for p in to_install:
        apk_name = f"{p['P']}-{p['V']}.apk"
        dest = os.path.join(cache_dir, apk_name)
        if not os.path.exists(dest):
            # try main first, then community
            downloaded = False
            for repo in ("main", "community"):
                url = f"{args.mirror}/v{args.version}/{repo}/{args.arch}/{apk_name}"
                try:
                    urllib.request.urlretrieve(url, dest + ".tmp")
                    downloaded = True
                    break
                except Exception:
                    continue
            if not downloaded:
                raise SystemExit(f"error: could not download {apk_name} from main or community")
            os.rename(dest + ".tmp", dest)
        if os.path.getsize(dest) != int(p["S"]):
            # stale/corrupt cache entry — drop it and re-download once
            print(f"warning: cached {apk_name} size mismatch, re-downloading")
            os.unlink(dest)
            downloaded = False
            for repo in ("main", "community"):
                url = f"{args.mirror}/v{args.version}/{repo}/{args.arch}/{apk_name}"
                try:
                    urllib.request.urlretrieve(url, dest + ".tmp")
                    downloaded = True
                    break
                except Exception:
                    continue
            if not downloaded:
                raise SystemExit(f"error: could not download {apk_name} from main or community")
            os.rename(dest + ".tmp", dest)
            if os.path.getsize(dest) != int(p["S"]):
                raise SystemExit(f"error: {apk_name} size mismatch after re-download "
                                 f"({os.path.getsize(dest)} != index S={p['S']})")
        info = read_pkginfo(dest)
        if info.get("pkgname") != p["P"] or info.get("pkgver") != p["V"]:
            raise SystemExit(f"error: {apk_name} .PKGINFO says "
                             f"{info.get('pkgname')}={info.get('pkgver')}")
        apk_paths[p["P"]] = dest
    print("downloads verified (size + .PKGINFO)")

    # --- 6. extract + build db entries + collect meta.db rows ---
    # meta.db lives next to data/
    meta_db_path = os.path.join(os.path.dirname(data_dir), "meta.db")
    have_meta = os.path.exists(meta_db_path)
    new_paths = []  # (abs_path_bytes, mode, uid, gid, rdev)
    takeovers = []  # (abs_path_bytes, mode, uid, gid, rdev) — busybox
    #   symlinks overwritten in place (same inode, mode updated)
    takeover_paths = set()
    new_entries = {}  # pkgname -> installed-db entry text
    scripts = {}  # scripts.tar member name -> bytes
    # Existing meta.db paths+modes, for the busybox-symlink takeover
    # check: a new file/symlink may only overwrite an existing path when
    # that path is a symlink whose on-disk content is "/bin/busybox".
    existing_modes = {}
    if have_meta:
        _con = sqlite3.connect(f"file:{meta_db_path}?mode=ro", uri=True)
        try:
            for _path_b, _blob in _con.execute(
                    "SELECT paths.path, stats.stat FROM paths "
                    "JOIN stats ON paths.inode = stats.inode"):
                existing_modes[_path_b] = struct.unpack("<IIII", _blob)[0]
        finally:
            _con.close()
    for p in to_install:
        apk_path = apk_paths[p["P"]]
        with tarfile.open(apk_path, "r:gz") as tf:
            members = [m for m in tf.getmembers() if not m.name.startswith(".")]
            members_by_name = {m.name: m for m in members}
            # collect install scripts (dotfiles) for scripts.tar
            for m in tf.getmembers():
                if m.name in SCRIPT_TYPES:
                    scripts[f"{p['P']}-{p['V']}.{p['C']}{m.name}"] = tf.extractfile(m).read()
            # extract data members
            for m in members:
                rel = m.name
                dest = os.path.join(data_dir, rel)
                abs_path_b = ("/" + rel).encode()
                if m.isdir():
                    if abs_path_b in existing_modes and \
                            existing_modes[abs_path_b] & 0o170000 != 0o040000:
                        raise SystemExit(f"error: {apk_path} dir {rel} collides "
                                         "with a non-directory in meta.db")
                    os.makedirs(dest, exist_ok=True)
                    os.chmod(dest, m.mode & 0o7777)
                elif m.issym():
                    parent = os.path.dirname(dest)
                    os.makedirs(parent, exist_ok=True)
                    if abs_path_b in existing_modes:
                        _check_takeover(dest, abs_path_b, existing_modes,
                                        takeover_paths)
                        takeovers.append((abs_path_b, 0o120000 | 0o777,
                                          m.uid, m.gid, 0))
                        takeover_paths.add(abs_path_b)
                    if os.path.lexists(dest):
                        os.unlink(dest)
                    # fakefs-style symlink: write the link target as the
                    # content of a regular file, exactly like fakefsify
                    # does for the base image (e.g. data/bin/sh is a
                    # regular file whose content is "/bin/busybox").
                    # A real host symlink must NOT be used: `zip` (without
                    # -y) dereferences it and stores the target's full
                    # content, so the zip entry becomes a regular file
                    # containing binary/text — but meta.db records
                    # mode=symlink, so the guest kernel reads that content
                    # as the link target and the link is broken (python3,
                    # npm, git-*, lib*.so.* all broke this way). The
                    # on-disk mode matches fakefsify's symlink files
                    # (0o660); the guest reads the mode from meta.db
                    # (0o120777), not from the disk file.
                    with open(dest, "wb") as f:
                        f.write(m.linkname.encode())
                    os.chmod(dest, 0o660)
                elif m.islnk():
                    # Hardlink: same content as the link target member in
                    # this same .apk (binutils/gcc ship ld, ar, ... as
                    # hardlinks to the target-prefixed binaries). The
                    # guest fakefs has no link-count concept in meta.db
                    # (one inode per path), so store a real copy of the
                    # target's content — functionally identical (only
                    # st_nlink/inode differ, which nothing here relies
                    # on). The apk db records it as a regular file with
                    # the content checksum, like real apk does.
                    parent = os.path.dirname(dest)
                    os.makedirs(parent, exist_ok=True)
                    target = members_by_name.get(m.linkname)
                    if target is None or not target.isfile():
                        raise SystemExit(f"error: {apk_path} hardlink {rel} -> "
                                         f"{m.linkname} (target not a regular "
                                         "file in this apk)")
                    if abs_path_b in existing_modes:
                        _check_takeover(dest, abs_path_b, existing_modes,
                                        takeover_paths)
                        takeovers.append((abs_path_b,
                                          0o100000 | (m.mode & 0o7777),
                                          m.uid, m.gid, 0))
                        takeover_paths.add(abs_path_b)
                    with open(dest, "wb") as f:
                        f.write(tf.extractfile(target).read())
                    os.chmod(dest, m.mode & 0o7777)
                elif m.isfile():
                    parent = os.path.dirname(dest)
                    os.makedirs(parent, exist_ok=True)
                    if abs_path_b in existing_modes:
                        _check_takeover(dest, abs_path_b, existing_modes,
                                        takeover_paths)
                        takeovers.append((abs_path_b,
                                          0o100000 | (m.mode & 0o7777),
                                          m.uid, m.gid, 0))
                        takeover_paths.add(abs_path_b)
                    with open(dest, "wb") as f:
                        f.write(tf.extractfile(m).read())
                    os.chmod(dest, m.mode & 0o7777)
                else:
                    raise SystemExit(f"error: {apk_path} member {rel} has unsupported "
                                     f"type {m.type!r}")
        # build the installed-db entry from the tar listing
        new_entries[p["P"]] = build_db_entry(p, apk_path)
        # record meta.db rows (paths + stats) for this package's members
        if have_meta:
            for m in members:
                abs_path = "/" + m.name
                if abs_path.encode() in takeover_paths:
                    continue  # takeover: same inode, mode updated in place
                if m.isdir():
                    mode = 0o040000 | (m.mode & 0o7777)
                    new_paths.append((abs_path.encode(), mode, m.uid, m.gid, 0))
                elif m.issym():
                    new_paths.append((abs_path.encode(), 0o120000 | 0o777, m.uid, m.gid, 0))
                elif m.islnk():
                    # Hardlink: recorded as a regular file with the
                    # target's content (see the extraction branch above).
                    mode = 0o100000 | (m.mode & 0o7777)
                    new_paths.append((abs_path.encode(), mode, m.uid, m.gid, 0))
                elif m.isfile():
                    mode = 0o100000 | (m.mode & 0o7777)
                    new_paths.append((abs_path.encode(), mode, m.uid, m.gid, 0))
    print(f"extracted {len(to_install)} packages into {data_dir}")

    # --- 7. write installed db (existing entries verbatim + new, sorted) ---
    # Taken-over paths are pruned from the previous owner's entry first,
    # so no path is claimed by two packages.
    merged = dict(installed_raw)
    for name, entry in new_entries.items():
        merged[name] = entry
    if takeovers:
        merged = prune_takeovers(merged, takeover_paths)
        print(f"installed db: pruned {len(takeover_paths)} taken-over path(s) "
              "from previous owner(s)")
    with open(installed_db_path, "w", encoding="utf-8") as f:
        for name in sorted(merged):
            f.write(merged[name])
            f.write("\n")
    print(f"installed db: {len(merged)} packages")

    # --- 8. world file: /etc/apk/world (the real location — it already
    # exists in the base rootfs with the minirootfs top-level packages).
    # Merge the new top-level packages in, sorted, deduplicated. This
    # modifies an existing file, so no new meta.db row is needed.
    world_path = os.path.join(data_dir, "etc", "apk", "world")
    existing_world = []
    if os.path.exists(world_path):
        existing_world = [l.strip() for l in open(world_path, encoding="utf-8")
                          if l.strip()]
    merged_world = sorted(set(existing_world) | set(targets))
    with open(world_path, "w", encoding="utf-8") as f:
        for name in merged_world:
            f.write(name + "\n")
    os.chmod(world_path, 0o644)
    print(f"world file: {len(merged_world)} top-level packages "
          f"({len(existing_world)} base + {len(set(targets) - set(existing_world))} new)")

    # --- 9. scripts.tar (existing entries preserved, new ones appended, sorted) ---
    scripts_tar_path = os.path.join(data_dir, "lib", "apk", "db", "scripts.tar")
    if scripts:
        existing = {}
        if os.path.exists(scripts_tar_path):
            with tarfile.open(scripts_tar_path, "r:") as tf:
                for m in tf.getmembers():
                    existing[m.name] = (tf.extractfile(m).read(), m.mode, m.mtime)
        for name, data in scripts.items():
            # script mtime: fixed 0 for determinism (content is what matters)
            existing[name] = (data, 0o755, 0)
        with tarfile.open(scripts_tar_path, "w", format=tarfile.USTAR_FORMAT) as tf:
            for name in sorted(existing):
                data, mode, mtime = existing[name]
                ti = tarfile.TarInfo(name)
                ti.size = len(data)
                ti.mode = mode
                ti.mtime = mtime
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = ""
                tf.addfile(ti, io.BytesIO(data))
        print(f"scripts.tar: {len(scripts)} new script(s)")

    # --- 10. bash post-install effect: add-shell /bin/bash ---
    if "bash" in [p["P"] for p in to_install]:
        shells_path = os.path.join(data_dir, "etc", "shells")
        try:
            lines = open(shells_path, encoding="utf-8").read().splitlines()
        except FileNotFoundError:
            lines = ["# valid login shells"]
        if "/bin/bash" not in lines:
            with open(shells_path, "a", encoding="utf-8") as f:
                f.write("/bin/bash\n")
            print("etc/shells: added /bin/bash (bash post-install effect)")

    # --- 11. meta.db: insert paths + stats rows ---
    if have_meta:
        update_meta_db(meta_db_path, new_paths, takeovers)
        print(f"meta.db: {len(new_paths)} new path(s), "
              f"{len(takeovers)} busybox symlink takeover(s)")
    else:
        print("warning: no meta.db next to data/ — skipped meta.db update "
              "(fakefsify must run after this helper, or the guest will not see the new files)")

    # --- 12. lock file ---
    if args.lock_file:
        with open(args.lock_file, "w", encoding="utf-8") as f:
            f.write(f"# rootfs packages lock — Alpine {args.version} {args.arch}\n")
            f.write(f"# mirror: {args.mirror}\n")
            for p in to_install:
                f.write(f"{p['P']}={p['V']}\n")
        print(f"lock file: {args.lock_file}")

    print(f"done: {len(to_install)} packages, {total_inst // 1024} KiB installed, "
          f"{len(new_paths)} new filesystem entries, "
          f"{len(takeovers)} busybox symlink takeover(s)")
    return 0

def build_db_entry(pkg, apk_path):
    """Build the installed-db entry text for one package from its .apk."""
    with tarfile.open(apk_path, "r:gz") as tf:
        members = [m for m in tf.getmembers() if not m.name.startswith(".")]
        contents = {}
        by_name = {m.name: m for m in members}
        for m in members:
            if m.isfile():
                contents[m.name] = tf.extractfile(m).read()
            elif m.islnk():
                # Hardlink: same content as its target member in this apk
                # (binutils/gcc ship ld/ar/... this way). Real apk records
                # hardlinked paths as regular file entries with the
                # content checksum.
                target = by_name.get(m.linkname)
                if target is None or not target.isfile():
                    raise SystemExit(f"error: {apk_path} hardlink {m.name} -> "
                                     f"{m.linkname} (target not a regular "
                                     "file in this apk)")
                contents[m.name] = tf.extractfile(target).read()
    fields = ["C", "P", "V", "A", "S", "I", "T", "U", "L", "o", "m", "t", "c",
              "k", "D", "q", "p", "r"]
    lines = []
    for k in fields:
        if k in pkg:
            lines.append(f"{k}:{pkg[k]}")
    # group members by parent dir (sorted), files within each dir sorted.
    # Every dir is listed, including empty ones (from dir members) and
    # every parent dir of a file — matching how apk writes the db.
    dirs = set()
    for m in members:
        if m.isdir():
            dirs.add(m.name.rstrip("/"))
        d = os.path.dirname(m.name)
        if d:
            dirs.add(d)
    dirs = sorted(dirs)
    for d in dirs:
        lines.append(f"F:{d}" if d else "F:")
        for m in sorted([m for m in members if os.path.dirname(m.name) == d],
                        key=lambda m: os.path.basename(m.name)):
            base = os.path.basename(m.name)
            if m.isdir():
                continue  # dirs are listed as F: only
            lines.append(f"R:{base}")
            if m.issym():
                lines.append(f"a:{m.uid}:{m.gid}:777")
                # apk checksums the link target EXACTLY as stored in the
                # tar (the raw linkname), NOT resolved to an absolute path.
                # Verified against the base rootfs db: all 32 base symlinks
                # match SHA1(raw linkname) and none match SHA1(resolved
                # absolute). (Resolving first was the previous behaviour;
                # it agreed with the old verifier only because the verifier
                # resolved the same way — circular. Real apk uses raw.)
                lines.append(f"Z:{apk_checksum(m.linkname.encode())}")
            elif m.isfile() or m.islnk():
                perm = m.mode & 0o7777
                if (m.uid, m.gid, perm) != (0, 0, 0o644):
                    lines.append(f"a:{m.uid}:{m.gid}:{perm:o}")
                lines.append(f"Z:{apk_checksum(contents[m.name])}")
    return "\n".join(lines) + "\n"

def update_meta_db(meta_db_path, new_paths, takeovers=None):
    """Insert paths + stats rows for new files. new_paths: list of
    (abs_path_bytes, mode, uid, gid, rdev). takeovers: same shape — paths
    that already exist in the db as BusyBox applet symlinks and were
    overwritten in place; their stats row is UPDATED (same inode, new
    mode) instead of a new row being inserted. Directories that already
    exist in the db (e.g. /usr/bin, shared by many packages) are skipped;
    a file/symlink colliding with an existing path is a hard error."""
    # dedup by path (several packages ship the same dirs)
    by_path = {}
    for path, mode, uid, gid, rdev in new_paths:
        if path in by_path and by_path[path] != (mode, uid, gid, rdev):
            raise SystemExit(f"error: conflicting entries for {path!r} in the package set")
        by_path.setdefault(path, (mode, uid, gid, rdev))
    new_paths = sorted(by_path.items(), key=lambda kv: kv[0])
    takeovers = sorted(takeovers or [], key=lambda t: t[0])
    con = sqlite3.connect(meta_db_path)
    try:
        cur = con.cursor()
        existing = {row[0] for row in cur.execute("SELECT path FROM paths")}
        max_inode = cur.execute("SELECT COALESCE(MAX(inode), 0) FROM stats").fetchone()[0]
        rows_stat, rows_path = [], []
        skipped_dirs = 0
        for path, (mode, uid, gid, rdev) in new_paths:
            if path in existing:
                if mode & 0o170000 == 0o040000:
                    skipped_dirs += 1
                    continue  # shared dir, already indexed
                raise SystemExit(
                    f"error: {path!r} already exists in meta.db — a new package "
                    "would overwrite a base file")
            inode = max_inode + 1 + len(rows_stat)
            blob = struct.pack("<IIII", mode, uid, gid, rdev)
            rows_stat.append((inode, blob))
            rows_path.append((path, inode))
        cur.executemany("INSERT INTO stats (inode, stat) VALUES (?, ?)", rows_stat)
        cur.executemany("INSERT INTO paths (path, inode) VALUES (?, ?)", rows_path)
        # Takeovers: same inode, new mode (symlink -> regular file, or
        # symlink -> symlink with a new target). The row must already
        # exist — the extraction step verified the path was a busybox
        # symlink before overwriting it.
        for path, mode, uid, gid, rdev in takeovers:
            row = cur.execute("SELECT inode FROM paths WHERE path = ?",
                              (path,)).fetchone()
            if row is None:
                raise SystemExit(f"error: takeover path {path!r} not in meta.db")
            blob = struct.pack("<IIII", mode, uid, gid, rdev)
            cur.execute("UPDATE stats SET stat = ? WHERE inode = ?",
                        (blob, row[0]))
        con.commit()
        # merge the WAL back into the main db file so the shipped db (the
        # zip step excludes *.db-wal/*.db-shm) contains the new rows
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        con.commit()
        print(f"meta.db: {len(rows_path)} new path(s), {skipped_dirs} shared dir(s) skipped, "
              f"{len(takeovers)} takeover(s) updated in place")
    finally:
        con.close()
    # sanity: re-open read-only and confirm the rows are in the main db file
    con = sqlite3.connect(f"file:{meta_db_path}?mode=ro", uri=True)
    try:
        n = con.execute("SELECT COUNT(*) FROM paths").fetchone()[0]
    finally:
        con.close()
    print(f"meta.db now has {n} paths")

if __name__ == "__main__":
    sys.exit(main())
