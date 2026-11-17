#!/bin/bash
# ============================================================================
# prepare-rootfs.sh — dsh-go Alpine rootfs for iSH (fakefs + zip)
# ============================================================================
# Downloads the pinned Alpine 3.21.0 aarch64 minirootfs, converts it to iSH's
# fakefs format with the iSH `fakefsify` tool, configures it for dsh-go, and
# zips it into app/ios/IShArtifacts/alpine-rootfs.zip for the prototype App.
#
# Adapted from OpenMinis deps/prepare_alpine_rootfs.sh (389 lines). Differences
# from upstream, all deliberate:
#   - Alpine version is PINNED to 3.21.0 (not "3.21" + a separate minor) and
#     the tarball SHA256 is checked on every run. The SHA256 below was
#     verified 2026-11-14 against Alpine's own published .sha256 file AND by
#     direct download (3,851,686 bytes).
#   - Output is the ZIP only, into app/ios/IShArtifacts/ (the contract with
#     the prototype App). The intermediate fakefs tree is kept under
#     third_party/ish/.work/alpine-rootfs/ for inspection, not in the bundle.
#   - Branding changed from MinisApp to dsh-go (/etc/profile PS1, /etc/motd).
#   - Extra packages (see rootfs-packages.txt: bash, python3, ripgrep,
#     curl, GNU coreutils/findutils/grep/sed, procps-ng, jq, make,
#     build-base, util-linux-misc) are installed into the fakefs tree by
#     install-rootfs-packages.py AFTER fakefsify and BEFORE the zip, so the
#     preinstalled. The helper also updates the apk db and the fakefs
#     meta.db — both are required for the guest to see the new files.
#   - Idempotent: if IShArtifacts/rootfs-manifest.json already records the
#     same Alpine tarball SHA256 + the same iSH commit + the same package
#     list SHA256 and the zip exists, the rebuild is skipped (use --force
#     to rebuild anyway).
#
# ORDERING — run build-ish.sh FIRST:
#   fakefsify is built from the iSH source tree (third_party/ish-src) with a
#   NATIVE (host) meson build. build-ish.sh is the step that downloads and
#   extracts that source tree. This script does NOT download iSH itself: if
#   third_party/ish-src is missing it fails with a message telling you to run
#   build-ish.sh first. (The cross-compiled .a libraries are NOT needed by
#   this script — only the source checkout is.)
#
# Prerequisites (installed via brew when missing):
#   ninja, libarchive, meson, python3. Plus curl/shasum/zip.
#   NOTE: fakefsify links the SYSTEM libarchive (brew), not the empty
#   deps/libarchive submodule dir inside the iSH tarball.
#
# Usage (run from the repository root, or anywhere):
#   third_party/ish/prepare-rootfs.sh [--force|clean]
#
#   (no flag)  build (or skip if manifest matches) -> IShArtifacts/alpine-rootfs.zip
#   --force    rebuild even if the manifest matches
#   clean      remove the fakefs tree, the native build dir, the zip and the
#              manifest (the downloaded Alpine tarball cache is kept)
#
# Output layout (contract with the prototype App — do not change):
#   app/ios/IShArtifacts/alpine-rootfs.zip
#   app/ios/IShArtifacts/rootfs-manifest.json   (provenance + zip SHA256)
#
# The zip is DETERMINISTIC: same input -> byte-identical zip -> the same
# SHA256 on every run. The zip format embeds per-entry timestamps and
# extra fields, and `zip -r` walks the directory in readdir order, so a
# naive zip varies between runs — and the App's RootfsManager compares
# the zip SHA256 against the installed marker, so any variation looks
# like a rootfs upgrade requiring an explicit reset (build 22 device
# test: the zip hash changed on every build, so every new build bricked
# the terminal until reset). To keep the hash stable, create_zip_archive()
# normalises every mtime in the tree to ROOTFS_EPOCH, feeds `zip` an
# LC_ALL=C-sorted file list, and strips extra fields with `zip -X`.
# fakefsify's own output (meta.db) was verified byte-identical across
# runs, so the zip step is the only source of variation. What is pinned
# is the INPUT tarball SHA256 (below); the zip SHA256 is printed and
# recorded in the manifest on every run, so a later step can verify the
# exact artifact it is about to ship.
#
# License note: Alpine rootfs is an aggregate of its packages' licenses
# (musl MIT, BusyBox GPL-2.0, ...). iSH itself is GPL-3.0. See design §5.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISH_SRC="$REPO_ROOT/third_party/ish-src"
CACHE_DIR="$REPO_ROOT/third_party/ish/.cache"
WORK_DIR="$REPO_ROOT/third_party/ish/.work"
ARTIFACTS="$REPO_ROOT/app/ios/IShArtifacts"

# --- Pinned iSH source (must match third_party/ish/source.json) ---
ISH_COMMIT="0fd17a135e78b7a0cf08a4f5831217bbb76ed22f"

# --- Pinned Alpine minirootfs ---
ALPINE_VERSION="3.21.0"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_FILE="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="${ALPINE_MIRROR}/v3.21/releases/${ALPINE_ARCH}/${ALPINE_FILE}"
# SHA256 verified 2026-11-14 two ways: Alpine's published
#   ${ALPINE_URL}.sha256
# and a direct download (3,851,686 bytes). Both agree.
ALPINE_SHA256="f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1"

# --- Extra rootfs packages (see rootfs-packages.txt) ---
# Pinned top-level list + the helper that installs them into the fakefs
# tree. The list SHA256 is recorded in the manifest and checked by the
# skip guard, so editing the list forces a rebuild.
PACKAGES_FILE="$SCRIPT_DIR/rootfs-packages.txt"
PACKAGES_HELPER="$SCRIPT_DIR/install-rootfs-packages.py"
PACKAGES_LOCK="$ARTIFACTS/rootfs-packages.lock"

# --- Deterministic zip epoch ---
# Every mtime in the fakefs tree is normalised to this instant before
# zipping (touch -t format, POSIX — works on GNU and BSD/macOS touch).
# 2020-01-01 00:00:00 UTC. The guest never sees these mtimes (its
# metadata comes from meta.db), so the value is arbitrary — it only has
# to stay fixed. Changing it changes the zip SHA256 once, and the App
# then treats the next build as a rootfs upgrade (explicit reset), so
# do not change it casually.
ROOTFS_EPOCH="202001010000.00"

FORCE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}" >&2; exit 1; }

# ============================================================================
# Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    command -v curl >/dev/null || log_error "curl is required"
    command -v shasum >/dev/null || log_error "shasum is required"
    command -v zip >/dev/null || log_error "zip is required"
    command -v python3 >/dev/null || log_error "python3 is required"
    command -v meson >/dev/null || log_error "meson is required (brew install meson)"
    command -v ninja >/dev/null || log_error "ninja is required (brew install ninja)"

    # fakefsify links the system libarchive (brew). Upstream checks for the
    # dylib in the brew prefix dirs; do the same, and install if absent.
    local found=0
    for dir in "/opt/homebrew/opt/libarchive" "/usr/local/opt/libarchive" "/usr"; do
        if [ -f "$dir/lib/libarchive.dylib" ] || [ -f "$dir/lib/libarchive.a" ]; then found=1; break; fi
    done
    if [ "$found" -eq 0 ]; then
        if command -v brew >/dev/null; then
            log_info "libarchive not found, installing via brew..."
            brew install libarchive
        else
            log_error "libarchive is required. Install with: brew install libarchive"
        fi
    fi

    # iSH source must already be on disk — build-ish.sh owns that step.
    if [ ! -f "$ISH_SRC/meson.build" ] || [ ! -f "$ISH_SRC/tools/fakefsify.c" ]; then
        log_error "iSH source not found at $ISH_SRC. Run third_party/ish/build-ish.sh FIRST (it downloads + extracts the pinned iSH tarball), then re-run this script."
    fi
    local marker="$ISH_SRC/.ish-source-commit"
    # build-ish.sh writes "<commit> <patch-sha>" (the patch set is part of
    # the marker since the P0/P1 kernel patch landed); compare only the
    # commit field — a changed patch already forces a fresh extract there.
    if [ -f "$marker" ] && [ "$(awk '{print $1}' "$marker")" != "$ISH_COMMIT" ]; then
        log_error "iSH source on disk is at $(cat "$marker"), but this script pins $ISH_COMMIT. Re-run build-ish.sh to re-extract the pinned source first."
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Skip guard: same Alpine input + same iSH commit + zip present = skip.
# (Defined once, below main; uses the pinned constants via argv.)
# ============================================================================

# ============================================================================
# Download Alpine minirootfs (SHA256-pinned, cached)
# ============================================================================
download_alpine() {
    log_info "Downloading Alpine Linux $ALPINE_VERSION for $ALPINE_ARCH..."
    mkdir -p "$CACHE_DIR"
    local path="$CACHE_DIR/$ALPINE_FILE"

    if [ -f "$path" ]; then
        if printf '%s  %s\n' "$ALPINE_SHA256" "$path" | shasum -a 256 -c - >/dev/null 2>&1; then
            log_info "Cached rootfs already matches pinned SHA256, skipping download"
            return
        fi
        log_warning "Cached rootfs does NOT match pinned SHA256 — re-downloading"
        rm -f "$path"
    fi
    log_info "Downloading from $ALPINE_URL"
    curl --fail --location --retry 2 -o "$path" "$ALPINE_URL"
    printf '%s  %s\n' "$ALPINE_SHA256" "$path" | shasum -a 256 -c -
    log_success "Alpine rootfs ready: $(du -h "$path" | cut -f1)"
}

# ============================================================================
# Build fakefsify (native host tool — NOT cross-compiled)
# ============================================================================
build_fakefsify() {
    log_info "Building fakefsify tool (native host build)..."
    local build_dir="$ISH_SRC/build-native"

    if [ -x "$build_dir/tools/fakefsify" ]; then
        log_info "fakefsify already built"
        return
    fi

    mkdir -p "$build_dir"
    cd "$ISH_SRC"

    if [ ! -f "$build_dir/build.ninja" ]; then
        log_info "Configuring native meson build..."
        # Deliberately no -Db_ndebug here (unlike build-ish.sh, which
        # disables asserts for release). This build produces only
        # tools/fakefsify, a host-side tool that runs on this Mac and never
        # ships to a device, so a failed assert is a loud build failure
        # rather than a user crash — which is what we want while generating
        # a rootfs. Same reasoning as upstream.
        meson setup "$build_dir" \
            --buildtype=release \
            -Dlog="" \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    fi

    log_info "Building fakefsify..."
    ninja -C "$build_dir" tools/fakefsify

    [ -x "$build_dir/tools/fakefsify" ] || log_error "Failed to build fakefsify"
    cd "$SCRIPT_DIR"
    log_success "fakefsify built successfully"
}

# ============================================================================
# Convert to fakefs + configure for dsh-go
# ============================================================================
create_fakefs() {
    log_info "Creating fakefs rootfs..."
    local rootfs_path="$CACHE_DIR/$ALPINE_FILE"
    local fakefsify="$ISH_SRC/build-native/tools/fakefsify"
    local output_rootfs="$WORK_DIR/alpine-rootfs"

    rm -rf "$output_rootfs"
    mkdir -p "$WORK_DIR"

    log_info "Converting rootfs to fakefs format..."
    "$fakefsify" "$rootfs_path" "$output_rootfs"

    [ -d "$output_rootfs/data" ] || log_error "Failed to create fakefs rootfs (no data/ dir)"
    [ -f "$output_rootfs/meta.db" ] || log_error "Failed to create fakefs rootfs (no meta.db)"
    log_success "Fakefs rootfs created"
}

configure_rootfs() {
    log_info "Configuring rootfs for dsh-go..."
    local rootfs_data="$WORK_DIR/alpine-rootfs/data"

    mkdir -p "$rootfs_data/dev" "$rootfs_data/proc" "$rootfs_data/sys" \
             "$rootfs_data/tmp" "$rootfs_data/run" "$rootfs_data/root" \
             "$rootfs_data/home"

    # Root shell: /bin/sh (BusyBox ash).
    if [ -f "$rootfs_data/etc/passwd" ]; then
        sed -i.bak 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$rootfs_data/etc/passwd"
        rm -f "$rootfs_data/etc/passwd.bak"
    fi

    # Shell defaults. NOTE: this appends on every run; create_fakefs wipes
    # the tree first, so the append happens exactly once per fresh rootfs.
    # No `cd ~` here (ENV-12): the harness owns the working directory
    # (cd -- /home/workspace per call); a profile cd would race it.
    cat >> "$rootfs_data/etc/profile" << 'EOF'

# dsh-go iSH Configuration
export PS1='\u@dsh-go:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin

# Aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
EOF

    cat > "$rootfs_data/etc/motd" << 'EOF'

  __  __ _       _        _    _ _
 |  \/  (_)_ __ (_)___   | |  (_) |_ ___
 | |\/| | | '_ \| / __|  | |  | | __/ _ \
 | |  | | | | | | \__ \  | |__| | ||  __/
 |_|  |_|_|_| |_|_|___/  |____|_|\__\___|

 Welcome to dsh-go Linux Shell
 Alpine Linux aarch64 on iSH-ARM64 Emulator

EOF

    # inittab for single-user mode (iSH handles the tty).
    cat > "$rootfs_data/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

    # DNS placeholder (8.8.8.8/8.8.4.4); the App overwrites this at boot
    # from the iOS system resolver (design §1.4/§1.9).
    cat > "$rootfs_data/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    # Deterministic mode (cat > uses the caller's umask, which varies);
    # the guest reads the mode from meta.db, and the indexer below
    # records it — so the mode must be fixed here, not left to umask.
    chmod 644 "$rootfs_data/etc/resolv.conf"

    # APK repositories for the pinned Alpine version.
    cat > "$rootfs_data/etc/apk/repositories" << EOF
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
EOF

    log_success "Rootfs configured"
}

# ============================================================================
# Install extra packages (see rootfs-packages.txt) into the fakefs tree
# ============================================================================
install_rootfs_packages() {
    log_info "Installing extra rootfs packages (see rootfs-packages.txt)..."
    [ -f "$PACKAGES_FILE" ] || log_error "Package list not found: $PACKAGES_FILE"
    [ -f "$PACKAGES_HELPER" ] || log_error "Package installer not found: $PACKAGES_HELPER"
    [ -d "$WORK_DIR/alpine-rootfs/data" ] || log_error "fakefs data tree missing — run create_fakefs first"
    python3 "$PACKAGES_HELPER" \
        --data-dir "$WORK_DIR/alpine-rootfs/data" \
        --packages "$PACKAGES_FILE" \
        --mirror "$ALPINE_MIRROR" \
        --version "3.21" \
        --arch "$ALPINE_ARCH" \
        --cache-dir "$CACHE_DIR/rootfs-packages" \
        --lock-file "$PACKAGES_LOCK"
    log_success "Extra packages installed (lock: $PACKAGES_LOCK)"
}

# ============================================================================
# Pre-compile Python bytecode (ENV-03)
# ============================================================================
# The guest ships no .pyc files at all, and PYTHONDONTWRITEBYTECODE=1
# blocks creating them at runtime, so every `pip` run recompiles ~100
# stdlib / site-packages modules from source (optparse alone costs 6 s
# in the emulator; pip startup routinely exceeds 60 s and gets killed).
# Baking __pycache__ into the image at build time fixes it: imports then
# load the .pyc directly.
#
# Why --invalidation-mode checked-hash (PEP 552) instead of the default
# timestamp mode: a timestamp .pyc is only valid when the source file's
# mtime matches the mtime baked into the .pyc header. The guest's fakefs
# does NOT store mtimes in meta.db (struct ish_stat has no mtime field);
# fakefs_stat reports the HOST file's mtime, which is whatever the App's
# unzip set at extract time — the zip step normalises it to ROOTFS_EPOCH,
# but that depends on the App preserving zip entry mtimes, which is not
# guaranteed. A hash-based .pyc is valid whenever the source bytes are
# unchanged, regardless of mtime, so it is robust to all of that. The
# header embeds the first 8 bytes of the source's SHA256 — fully
# deterministic across runs (same source -> same .pyc bytes).
# .pyc files are written by the HOST python3 (3.12); the guest python is
# 3.12.16 — same magic number (3531), so the .pyc load. (If the guest
# ever moves to a different Python minor, the magic changes and the
# .pyc are silently ignored — safe fallback, just slow again.)
# Modes are fixed explicitly (644 for .pyc, 755 for __pycache__ dirs):
# compileall writes with the caller's umask, which varies between build
# machines and would make meta.db (and the zip SHA) non-deterministic.
# The whole data tree is compiled, not just /usr/lib/python3.12: npm's
# bundled node-gyp also ships Python (gyp/*.py, 58 files), which runs
# under the guest python during native builds. Runs after
# install_rootfs_packages (so site-packages is compiled too) and before
# index_missing_rootfs_files (so the new __pycache__ dirs and .pyc files
# get meta.db rows — without them the guest cannot see them).
precompile_python() {
    log_info "Pre-compiling Python bytecode into the image (ENV-03)..."
    local data_dir="$WORK_DIR/alpine-rootfs/data"
    [ -d "$data_dir/usr/lib/python3.12" ] || log_error "Python lib dir missing: $data_dir/usr/lib/python3.12"
    python3 - "$data_dir" << 'PYEOF'
import compileall, sys
ok = compileall.compile_dir(sys.argv[1], quiet=1, force=True,
                            invalidation_mode="checked-hash", workers=1)
if not ok:
    print("error: compileall reported failures", file=sys.stderr)
    sys.exit(1)
PYEOF
    # Deterministic modes (see the comment above).
    find "$data_dir" -type d -name __pycache__ -exec chmod 755 {} +
    find "$data_dir" -type f -name '*.pyc' -exec chmod 644 {} +
    local n_pyc
    n_pyc="$(find "$data_dir" -type f -name '*.pyc' | wc -l)"
    log_success "Python pre-compiled: $n_pyc .pyc files"
}

# ============================================================================
# Index files that exist on disk but have no meta.db row
# ============================================================================
# configure_rootfs() creates /etc/resolv.conf on disk, but the Alpine
# minirootfs tarball does not ship it, so fakefsify never indexed it and
# the package installer (which only indexes package files) never sees it.
# A file on disk with no meta.db row is invisible to the guest's fakefs:
# the device showed an empty /etc/resolv.conf and could not resolve DNS
# even though the file (8.8.8.8/8.8.4.4) was in the zip. This step scans
# data/ for any path missing from meta.db and inserts a paths+stats row
# for it, using the file's actual mode from disk (configure_rootfs sets it
# explicitly) and root ownership (uid 0, gid 0 — the build machine's
# uid/gid would make meta.db non-deterministic) and the next free
# inode (continuing from the current max, in deterministic path-sorted
# order, matching the installer's convention). It runs after
# install_rootfs_packages and before create_zip_archive, so it applies to
# every build (base rootfs included), not just the package batch. Files
# already in meta.db are skipped. The WAL is checkpointed back into the
# main db file (the zip step excludes *.db-wal/*.db-shm).
index_missing_rootfs_files() {
    log_info "Indexing files missing from meta.db (e.g. /etc/resolv.conf)..."
    python3 - "$WORK_DIR/alpine-rootfs/meta.db" "$WORK_DIR/alpine-rootfs/data" << 'PYEOF'
import os, sqlite3, stat as statmod, struct, sys
meta_db, data_dir = sys.argv[1], sys.argv[2]
con = sqlite3.connect(meta_db)
try:
    cur = con.cursor()
    existing = {row[0] for row in cur.execute("SELECT path FROM paths")}
    max_inode = cur.execute("SELECT COALESCE(MAX(inode), 0) FROM stats").fetchone()[0]
    missing = []
    for dirpath, dirnames, filenames in os.walk(data_dir):
        dirnames.sort()
        for name in sorted(dirnames) + sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, data_dir)
            abs_path = ("/" + rel).encode()
            if abs_path in existing:
                continue
            st = os.lstat(full)
            if statmod.S_ISDIR(st.st_mode):
                mode = 0o040000 | (st.st_mode & 0o7777)
            elif statmod.S_ISLNK(st.st_mode):
                mode = 0o120000 | (st.st_mode & 0o7777)
            elif statmod.S_ISREG(st.st_mode):
                mode = 0o100000 | (st.st_mode & 0o7777)
            else:
                print(f"warning: skipping non-regular entry {abs_path!r}", file=sys.stderr)
                continue
            missing.append((abs_path, mode))
    missing.sort(key=lambda t: t[0])
    if not missing:
        print("meta.db: no unindexed files found")
        sys.exit(0)
    rows_stat, rows_path = [], []
    for i, (abs_path, mode) in enumerate(missing):
        # Owner is always root in the guest (uid 0, gid 0): the file's
        # on-disk uid/gid are the build machine's, which vary between
        # machines and would make meta.db (and the zip SHA) non-
        # deterministic. The mode comes from the file (configure_rootfs
        # sets it explicitly, e.g. chmod 644 for resolv.conf).
        uid, gid = 0, 0
        inode = max_inode + 1 + i
        blob = struct.pack("<IIII", mode, uid, gid, 0)
        rows_stat.append((inode, blob))
        rows_path.append((abs_path, inode))
        print(f"indexing {abs_path.decode()} mode={oct(mode)} uid={uid} gid={gid} inode={inode}")
    cur.executemany("INSERT INTO stats (inode, stat) VALUES (?, ?)", rows_stat)
    cur.executemany("INSERT INTO paths (path, inode) VALUES (?, ?)", rows_path)
    con.commit()
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.commit()
    print(f"meta.db: {len(rows_path)} previously-unindexed path(s) added")
finally:
    con.close()
PYEOF
    log_success "Unindexed files indexed into meta.db"
}

# ============================================================================
# Zip into app/ios/IShArtifacts/ + manifest (zip SHA256 printed + recorded)
# ============================================================================
create_zip_archive() {
    log_info "Creating ZIP archive..."
    local zip_file="$ARTIFACTS/alpine-rootfs.zip"

    mkdir -p "$ARTIFACTS"
    rm -f "$zip_file"

    # The prototype App's RootfsManager unzips with a minimal ZIP reader
    # (stored/deflate only) and strips the common prefix, so the tree must
    # be zipped as a single top-level dir, same as upstream.
    # Deterministic zip (see the header comment): the App compares the zip
    # SHA256 against the installed marker, so any byte-level variation
    # looks like a rootfs upgrade and bricks the terminal until an
    # explicit reset. Three sources of variation, all removed here:
    #   1. mtimes — directory mtimes are set at extraction time and
    #      configure_rootfs() writes files with "now" mtimes. Normalise
    #      every entry (files, dirs, and symlinks via -h) to ROOTFS_EPOCH.
    #   2. order — `zip -r` walks readdir order. Feed zip an
    #      LC_ALL=C-sorted file list via -@ instead.
    #   3. extra fields — uid/gid + extended timestamps. Strip with -X.
    # The guest never sees these mtimes (metadata comes from meta.db).
    find "$WORK_DIR/alpine-rootfs" -exec touch -h -t "$ROOTFS_EPOCH" {} +
    (cd "$WORK_DIR" && find "alpine-rootfs" -print | LC_ALL=C sort | zip -X -@ "$zip_file" \
        -x "*.db-shm" \
        -x "*.db-wal" \
        > /dev/null)

    [ -f "$zip_file" ] || log_error "Failed to create ZIP archive"
    # Sanity: the zip must contain the fakefs markers the App will check.
    # Verified with Python's zipfile (reads the central directory directly,
    # platform-independent) instead of `unzip -l | grep`: the unzip-based
    # check failed on the Codemagic Mac (build 3) even though a local repro
    # with the real fakefsify output passes (zip exit 0, meta.db present,
    # grep finds it) — the cause is environmental (unzip -l on macOS),
    # not the zip itself. If this check fails, dump the listing for
    # diagnosis before exiting.
    if ! python3 - "$zip_file" << 'PYEOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
print(f"zip entries: {len(names)}")
missing = [n for n in ("alpine-rootfs/meta.db", "alpine-rootfs/data/bin/sh") if n not in names]
if missing:
    print("MISSING: " + ", ".join(missing))
    sys.exit(1)
PYEOF
    then
        echo "--- zip listing (unzip -l, first 30 lines) ---" >&2
        unzip -l "$zip_file" 2>&1 | head -30 >&2 || true
        echo "--- zip file ---" >&2
        ls -la "$zip_file" >&2
        log_error "ZIP archive is missing alpine-rootfs/meta.db or alpine-rootfs/data/bin/sh — conversion is broken"
    fi

    local zip_sha zip_bytes
    zip_sha="$(shasum -a 256 "$zip_file" | cut -d' ' -f1)"
    zip_bytes="$(stat -f%z "$zip_file" 2>/dev/null || stat -c%s "$zip_file")"
    log_success "ZIP archive created: $(du -h "$zip_file" | cut -f1)"
    echo "alpine-rootfs.zip SHA256: $zip_sha"
    echo "alpine-rootfs.zip bytes:  $zip_bytes"

    # The package list hash + the resolved lock are recorded so the skip
    # guard can tell a package-list change from an unchanged rebuild, and
    # so a later build can show exactly which package versions shipped.
    local lock_sha packages_sha
    lock_sha="$(shasum -a 256 "$PACKAGES_LOCK" | cut -d' ' -f1)"
    packages_sha="$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)"
    python3 - "$ARTIFACTS/rootfs-manifest.json" << PYEOF
import json, sys
lock = [l.strip() for l in open("$PACKAGES_LOCK") if l.strip() and not l.startswith("#")]
manifest = {
    "alpine_version": "$ALPINE_VERSION",
    "alpine_arch": "$ALPINE_ARCH",
    "alpine_tarball_url": "$ALPINE_URL",
    "alpine_tarball_sha256": "$ALPINE_SHA256",
    "alpine_tarball_bytes": 3851686,
    "ish_commit": "$ISH_COMMIT",
    "rootfs_packages_sha256": "$packages_sha",
    "rootfs_packages_lock_sha256": "$lock_sha",
    "rootfs_packages": lock,
    "rootfs_zip": "alpine-rootfs.zip",
    "rootfs_zip_sha256": "$zip_sha",
    "rootfs_zip_bytes": $zip_bytes,
    "built_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
}
with open(sys.argv[1], "w") as f:
    json.dump(manifest, f, indent=2, sort_keys=True)
    f.write("\n")
print("manifest written:", sys.argv[1])
PYEOF
}

print_summary() {
    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 Alpine Rootfs Preparation Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Output files:"
    echo "  📁 $WORK_DIR/alpine-rootfs"
    echo "  📦 $ARTIFACTS/alpine-rootfs.zip"
    echo "  📄 $ARTIFACTS/rootfs-manifest.json"
    echo ""
    echo "Sizes:"
    echo "  Data:     $(du -sh "$WORK_DIR/alpine-rootfs/data" | cut -f1)"
    echo "  Database: $(du -h "$WORK_DIR/alpine-rootfs/meta.db" | cut -f1)"
    echo "  ZIP:      $(du -h "$ARTIFACTS/alpine-rootfs.zip" | cut -f1)"
    echo ""
    echo "To use in the prototype App:"
    echo "  1. Add alpine-rootfs.zip to Xcode project resources"
    echo "  2. Extract to Application Support on first launch"
    echo "  3. Use mount_root(&fakefs, path_to_data)"
    echo ""
    echo "============================================================"
}

clean() {
    log_info "Cleaning..."
    rm -rf "$WORK_DIR/alpine-rootfs"
    rm -rf "$ISH_SRC/build-native"
    rm -f "$ARTIFACTS/alpine-rootfs.zip" "$ARTIFACTS/rootfs-manifest.json" "$PACKAGES_LOCK"
    log_success "Clean completed (Alpine tarball cache kept in $CACHE_DIR)"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  Alpine Linux aarch64 Rootfs Preparation for dsh-go iSH"
    echo "  Version: $ALPINE_VERSION ($ALPINE_ARCH)"
    echo "  iSH commit: $ISH_COMMIT"
    echo "============================================================"
    echo ""

    # Skip guard (defined below, before main is invoked).
    check_prerequisites
    if already_staged; then
        log_success "alpine-rootfs.zip already staged for this Alpine SHA256 + iSH commit — skipping rebuild (use --force to rebuild)"
        exit 0
    fi
    download_alpine
    build_fakefsify
    create_fakefs
    configure_rootfs
    install_rootfs_packages
    precompile_python
    index_missing_rootfs_files
    create_zip_archive
    print_summary
}

# Skip guard: same Alpine input + same iSH commit + same package list + zip
# present = skip. Compares the staged manifest against this script's pinned
# constants and the package list hash.
already_staged() {
    local manifest="$ARTIFACTS/rootfs-manifest.json"
    local zip="$ARTIFACTS/alpine-rootfs.zip"
    [ "$FORCE" -eq 0 ] || return 1
    [ -f "$manifest" ] && [ -f "$zip" ] || return 1
    local packages_sha
    packages_sha="$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)"
    python3 - "$manifest" "$ALPINE_SHA256" "$ISH_COMMIT" "$packages_sha" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
ok = (m.get("alpine_tarball_sha256") == sys.argv[2]
      and m.get("ish_commit") == sys.argv[3]
      and m.get("rootfs_packages_sha256") == sys.argv[4])
sys.exit(0 if ok else 1)
PYEOF
}

case "${1:-}" in
    clean)
        clean
        exit 0
        ;;
    --force)
        FORCE=1
        main
        ;;
    --help|-h)
        echo "Usage: $0 [--force|clean]"
        echo ""
        echo "  (no flag)  build (or skip if manifest matches)"
        echo "  --force    rebuild even if the manifest matches"
        echo "  clean      remove generated rootfs/zip/manifest"
        echo ""
        echo "Run third_party/ish/build-ish.sh FIRST (it fetches the iSH source)."
        exit 0
        ;;
    "")
        main
        ;;
    *)
        log_error "Unknown argument: $1 (expected: --force, clean, --help)"
        ;;
esac

