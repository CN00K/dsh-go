#!/bin/bash
# ============================================================================
# build-ish.sh — dsh-go iSH static libraries for iOS (arm64 device only)
# ============================================================================
# Builds libish.a / libish_emu.a / libfakefs.a + the ARM64 guest VDSO from the
# pinned iSH fork (OpenMinis/ish-arm64 @ 0fd17a13, see source.json), and stages
# them into app/ios/IShArtifacts/ for the prototype App.
#
# Adapted from OpenMinis deps/build_ish.sh (518 lines). Differences from
# upstream, all deliberate:
#   - Source comes from a pinned codeload tarball (SHA256-checked), NOT from a
#     git submodule. The tarball's deps/libapps and deps/libarchive submodule
#     directories are empty, which is fine: no meson.build in the tree
#     references libapps, and libarchive is taken from brew (system dep).
#     The pinned commit is the single source of truth (source.json); the
#     stale "feature-arm64" branch name in upstream comments is ignored.
#   - Device only (iphoneos arm64). No simulator slice: iSH ships device
#     only by design, and the dsh-go prototype is device-only too. Passing
#     --simulator/--all is a hard error, not a silent no-op.
#   - iOS deployment target 15.0 (matches dsh-go's Runner), not upstream 14.0.
#   - NO AOT: v1 ships the pure gadget interpreter. This script never builds
#     or links libish_aot.a and never calls any build_aot.sh. Do not add
#     `-force_load libish_aot.a` until the AOT stage (design §2.8 / §3 stage 4).
#   - VDSO is a hard requirement, not a warning. Upstream's vdso/arm64
#     meson.build silently substitutes an EMPTY stub (a `touch`ed 0-byte file)
#     when no cross clang is found, and the build still "succeeds". This
#     script fails fast before meson setup if the VDSO toolchain cannot link
#     aarch64-linux-gnu, AND asserts after the build that the VDSO is
#     non-empty and a real ELF file. A fake VDSO must never ship.
#
# Prerequisites (installed via brew when missing):
#   llvm (brew clang + ld.lld — needed ONLY for the VDSO), ninja, libarchive,
#   meson. Plus Xcode (xcrun / iOS SDK) and python3 (meson needs it).
#
# Usage (run from the repository root, or anywhere — paths resolve from the
# script's own location):
#   third_party/ish/build-ish.sh [clean]
#
#   (no flag)  build device libs + VDSO + headers into app/ios/IShArtifacts/
#   clean      remove the meson build dir and the staged libs/headers/VDSO
#              (the downloaded tarball cache is kept)
#
# Output layout (this is the contract with the prototype App — do not change):
#   app/ios/IShArtifacts/lib/libish.a
#   app/ios/IShArtifacts/lib/libish_emu.a
#   app/ios/IShArtifacts/lib/libfakefs.a
#   app/ios/IShArtifacts/include/ish/ish.h            (umbrella header)
#   app/ios/IShArtifacts/include/ish/...              (kernel/emu/fs/... headers)
#   app/ios/IShArtifacts/vdso/arm64/libvdso.so.elf
#   app/ios/IShArtifacts/ish-manifest.json            (build provenance)
#
# Idempotency: re-running skips the download when the cached tarball already
# matches the pinned SHA256, skips re-extraction when the source marker
# already records the pinned commit, and lets meson/ninja do incremental
# rebuilds. Use `clean` to force a full rebuild.
#
# License note: iSH is GPL-3.0 (some contributions additionally GPL-2.0);
# LICENSE.IOS applies. See source.json and design §5.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root is two levels above third_party/ish/. (In the staging directory
# this resolves to the staging root, which mirrors the repo layout.)
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISH_SRC="$REPO_ROOT/third_party/ish-src"
CACHE_DIR="$REPO_ROOT/third_party/ish/.cache"
ARTIFACTS="$REPO_ROOT/app/ios/IShArtifacts"

# --- Pinned source (single source of truth: third_party/ish/source.json) ---
ISH_COMMIT="0fd17a135e78b7a0cf08a4f5831217bbb76ed22f"
ISH_URL="https://github.com/OpenMinis/ish-arm64"
ISH_TARBALL_URL="https://codeload.github.com/OpenMinis/ish-arm64/tar.gz/${ISH_COMMIT}"
# SHA256 of the codeload tarball, verified 2026-11-14 by direct download
# (2,990,131 bytes; tarball top dir is ish-arm64-<commit>, which confirms the
# commit). If the upstream tarball ever changes, this check fails loudly —
# update the hash only after re-downloading and re-verifying by hand.
ISH_TARBALL_SHA256="d26a47031c8ecf306e5c2c20989549be2383100c051c25cd0adab8d6e5c8e526"
ISH_TARBALL_NAME="ish-arm64-${ISH_COMMIT}.tar.gz"

IOS_DEPLOYMENT_TARGET="15.0"
BUILD_DIR="$ISH_SRC/build-ios"

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
# Prerequisites: brew packages, Xcode, python3
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    command -v python3 >/dev/null || log_error "Python 3 is required (meson needs it)"
    command -v xcrun >/dev/null || log_error "Xcode command line tools are required (xcrun not found)"
    xcode-select -p >/dev/null 2>&1 || log_error "Xcode command line tools are required. Run: xcode-select --install"
    command -v curl >/dev/null || log_error "curl is required"
    command -v shasum >/dev/null || log_error "shasum is required"
    command -v file >/dev/null || log_error "file is required (VDSO ELF assertion uses it)"
    command -v zip >/dev/null || log_warning "zip not found (only needed by prepare-rootfs.sh, not here)"

    if ! command -v brew >/dev/null; then
        log_error "Homebrew is required to install llvm/ninja/libarchive/meson. Install it from https://brew.sh first."
    fi

    # llvm provides the VDSO cross clang; lld provides ld.lld (the ELF
    # linker for the aarch64-linux-gnu VDSO). Newer Homebrew splits lld out
    # of the llvm formula, so install both — relying on llvm alone leaves
    # ld.lld missing and the VDSO check fails (build 2 hit exactly this).
    # ninja/meson/libarchive are the build tools. Install whatever is
    # missing, then re-check.
    for pkg in llvm lld ninja libarchive meson; do
        if brew list "$pkg" >/dev/null 2>&1; then
            log_info "brew package present: $pkg"
        else
            log_info "Installing brew package: $pkg ..."
            brew install "$pkg"
        fi
    done
    for t in ninja meson; do
        command -v "$t" >/dev/null || log_error "$t not found even after brew install (check PATH / brew linkage)"
    done

    log_success "Prerequisites check passed"
}

# ============================================================================
# VDSO toolchain: fail fast if the aarch64 cross link cannot work.
# ----------------------------------------------------------------------------
# Upstream's vdso/arm64/meson.build only *messages* when no clang is found
# and then builds a 0-byte stub via `touch` — the build exits 0 and the app
# ships a fake VDSO. We refuse that: the exact compiler invocation meson
# will use (brew llvm clang, -target aarch64-linux-gnu, -fuse-ld=lld) must
# link a trivial shared object here, before meson setup runs.
# ============================================================================
check_vdso_toolchain() {
    log_info "Checking VDSO cross toolchain (brew llvm clang + lld)..."

    LLVM_CLANG=""
    for clang_path in "/opt/homebrew/opt/llvm/bin/clang" "/usr/local/opt/llvm/bin/clang" "/opt/local/bin/clang"; do
        if [ -x "$clang_path" ]; then LLVM_CLANG="$clang_path"; break; fi
    done
    [ -n "$LLVM_CLANG" ] || log_error "No brew LLVM clang found (looked in /opt/homebrew, /usr/local, /opt/local). Run: brew install llvm"

    LLVM_LLD=""
    # ld.lld ships either inside the llvm formula or (newer Homebrew) in
    # the separate lld formula. Check both, plus PATH as a last resort.
    for lld_path in "/opt/homebrew/opt/llvm/bin/ld.lld" "/usr/local/opt/llvm/bin/ld.lld" "/opt/local/bin/ld.lld" "/opt/homebrew/opt/lld/bin/ld.lld" "/usr/local/opt/lld/bin/ld.lld"; do
        if [ -x "$lld_path" ]; then LLVM_LLD="$lld_path"; break; fi
    done
    if [ -z "$LLVM_LLD" ] && command -v ld.lld >/dev/null 2>&1; then
        LLVM_LLD="$(command -v ld.lld)"
    fi
    [ -n "$LLVM_LLD" ] || log_error "ld.lld not found (looked in llvm + lld formula paths and PATH). Run: brew install lld (and brew reinstall llvm if the llvm formula is stale); lld ships the ELF linker the aarch64 VDSO needs."

    log_info "VDSO clang: $LLVM_CLANG"
    log_info "VDSO lld:   $LLVM_LLD"

    # Link test with the exact flags vdso/arm64/meson.build will use.
    # (No RETURN trap here: macOS /bin/bash is 3.2 and has no RETURN trap.
    # Cleanup is explicit on every exit path instead.)
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/ish-vdso-check.XXXXXX")"
    printf 'void _start(void) {}\n' > "$tmpdir/vdso-test.c"
    if ! "$LLVM_CLANG" -target aarch64-linux-gnu -fuse-ld=lld \
            -nostdlib -shared -fPIC -ffreestanding \
            -o "$tmpdir/libvdso-test.so" "$tmpdir/vdso-test.c" 2>"$tmpdir/link.err"; then
        cat "$tmpdir/link.err" >&2
        rm -rf "$tmpdir"
        log_error "VDSO cross link failed with $LLVM_CLANG -target aarch64-linux-gnu -fuse-ld=lld. Refusing to build (meson would silently emit an empty VDSO stub)."
    fi
    if ! file "$tmpdir/libvdso-test.so" | grep -q "ELF"; then
        rm -rf "$tmpdir"
        log_error "VDSO link test produced a non-ELF file — toolchain is broken, refusing to build."
    fi
    rm -rf "$tmpdir"
    log_success "VDSO toolchain OK: $LLVM_CLANG can link aarch64-linux-gnu ELF"
}

# ============================================================================
# Fetch + verify + extract the pinned iSH source tarball (idempotent)
# ============================================================================
fetch_ish_source() {
    log_info "Fetching iSH source @ $ISH_COMMIT ..."

    mkdir -p "$CACHE_DIR"
    local tarball="$CACHE_DIR/$ISH_TARBALL_NAME"

    if [ -f "$tarball" ]; then
        if printf '%s  %s\n' "$ISH_TARBALL_SHA256" "$tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
            log_info "Cached tarball already matches pinned SHA256, skipping download"
        else
            log_warning "Cached tarball does NOT match pinned SHA256 — re-downloading"
            rm -f "$tarball"
            curl --fail --location --retry 2 "$ISH_TARBALL_URL" -o "$tarball"
            printf '%s  %s\n' "$ISH_TARBALL_SHA256" "$tarball" | shasum -a 256 -c -
        fi
    else
        log_info "Downloading $ISH_TARBALL_URL"
        curl --fail --location --retry 2 "$ISH_TARBALL_URL" -o "$tarball"
        printf '%s  %s\n' "$ISH_TARBALL_SHA256" "$tarball" | shasum -a 256 -c -
    fi

    # Extract once per pinned commit + kernel-patch set; the marker records
    # both, so changing either the commit or a patch forces a fresh extract
    # (a patch can never be applied twice, and a changed patch can never be
    # silently skipped on an already-extracted tree).
    local patch_file="$REPO_ROOT/third_party/ish/patches/ish-kernel-fixes.diff"
    local patch_sha="none"
    if [ -f "$patch_file" ]; then
        patch_sha="$(shasum -a 256 "$patch_file" | awk '{print $1}')"
    fi
    local marker="$ISH_SRC/.ish-source-commit"
    local expected_marker="$ISH_COMMIT $patch_sha"
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$expected_marker" ] && [ -f "$ISH_SRC/meson.build" ]; then
        log_info "Source already extracted at $ISH_COMMIT (patches $patch_sha), skipping"
        return
    fi
    log_info "Extracting tarball to $ISH_SRC ..."
    rm -rf "$ISH_SRC"
    mkdir -p "$ISH_SRC"
    tar xzf "$tarball" -C "$ISH_SRC" --strip-components=1
    [ -f "$ISH_SRC/meson.build" ] || log_error "Extracted source has no meson.build — tarball contents unexpected"
    [ -f "$ISH_SRC/tools/fakefsify.c" ] || log_error "Extracted source has no tools/fakefsify.c — tarball contents unexpected"
    [ -d "$ISH_SRC/vdso/arm64" ] || log_error "Extracted source has no vdso/arm64 — tarball contents unexpected"
    # Apply the dsh-go iSH kernel patches (P0 AF_UNIX backing prefix, P1
    # proc-fd magic link). The tree is freshly extracted, so `patch` applies
    # cleanly; a failure here is fatal — a half-patched kernel must never build.
    if [ -f "$patch_file" ]; then
        log_info "Applying iSH kernel patches ($patch_file) ..."
        (cd "$ISH_SRC" && patch -p1 < "$patch_file") || log_error "Failed to apply iSH kernel patches"
        log_success "iSH kernel patches applied"
    fi
    printf '%s\n' "$expected_marker" > "$marker"
    log_success "Source extracted at $ISH_COMMIT"
}

# ============================================================================
# Meson cross file (iphoneos arm64 device only) + build
# ============================================================================
setup_cross_compile() {
    log_info "Setting up cross-compilation (iphoneos, arm64, min iOS $IOS_DEPLOYMENT_TARGET)..."
    mkdir -p "$BUILD_DIR"
    local ios_sdk
    ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
    [ -n "$ios_sdk" ] || log_error "Could not resolve iphoneos SDK path via xcrun"

    cat > "$BUILD_DIR/ios-cross.txt" << EOF
[binaries]
c = ['clang', '-arch', 'arm64', '-isysroot', '$ios_sdk', '-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET']
ar = 'ar'
strip = 'strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = []
c_link_args = ['-L$ios_sdk/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$ios_sdk'
library_dirs = ['$ios_sdk/usr/lib']
EOF
    log_success "Cross-compilation file created"
}

build_ish() {
    log_info "Building iSH libraries (release, AOT-only: -Djit=true -Djit_emit=false)..."
    cd "$ISH_SRC"

    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        log_info "Configuring meson build..."
        # -Db_ndebug=true: meson's `release` buildtype is only -O3, it does
        # NOT define NDEBUG. Without it every assert() in the kernel stays
        # live in a shipping build (upstream: a mem_ptr() CoW assert reached
        # TestFlight as a SIGABRT). Keep asserts in debug builds only.
        # -Djit=true -Djit_emit=false: the AOT-only runtime. The JIT compiler
        # is compiled in but never emits code at run time and never maps
        # executable memory (no dynamic-codesigning entitlement needed); it
        # only installs translations from AOT images linked into the app.
        # v1 ships NO AOT image, so blocks run on the gadget interpreter.
        meson setup "$BUILD_DIR" \
            --cross-file "$BUILD_DIR/ios-cross.txt" \
            --buildtype=release \
            -Db_ndebug=true \
            -Dlog="" \
            -Dlog_handler=nslog \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64 \
            -Djit=true \
            -Djit_emit=false
    else
        log_info "Meson already configured, reconfiguring..."
        meson configure "$BUILD_DIR" \
            --buildtype=release \
            -Db_ndebug=true \
            -Djit=true \
            -Djit_emit=false
    fi

    log_info "Building with ninja..."
    ninja -C "$BUILD_DIR" libish.a libish_emu.a libfakefs.a

    # VDSO: must succeed AND produce a real file (see assert_vdso below).
    # NOTE: do NOT add `|| true` / `|| log_warning` here. Upstream tolerates
    # a failed VDSO build; we do not.
    log_info "Building VDSO..."
    ninja -C "$BUILD_DIR" vdso/arm64/libvdso.so.elf

    cd "$SCRIPT_DIR"
    log_success "iSH libraries built"
}

# ============================================================================
# VDSO assertion: non-empty AND ELF, or the build fails.
# ----------------------------------------------------------------------------
# Catches the upstream silent-stub trap (meson `touch`es a 0-byte
# libvdso.so.elf when no cross clang exists) and any truncated/corrupt
# output. Checked twice: right after ninja, and again on the staged copy.
# ============================================================================
assert_vdso() {
    local vdso_path="$1"
    [ -f "$vdso_path" ] || log_error "VDSO missing: $vdso_path"
    local size
    size="$(stat -f%z "$vdso_path" 2>/dev/null || stat -c%s "$vdso_path")"
    [ "$size" -gt 0 ] || log_error "VDSO is EMPTY (0 bytes): $vdso_path — this is the silent-stub trap; check the brew llvm/lld toolchain."
    # ELF magic: first 4 bytes must be 7f 45 4c 46. `file` is the readable
    # check; the od check is the exact one (no reliance on file's database).
    local magic
    magic="$(head -c 4 "$vdso_path" | od -An -tx1 | tr -d ' \n')"
    [ "$magic" = "7f454c46" ] || log_error "VDSO is not an ELF file (magic=$magic): $vdso_path"
    file "$vdso_path" | grep -q "ELF" || log_error "VDSO failed 'file' ELF check: $vdso_path"
    log_success "VDSO OK: $vdso_path ($size bytes, ELF)"
}

# ============================================================================
# Stage outputs into app/ios/IShArtifacts/ (contract with the prototype App)
# ============================================================================
copy_outputs() {
    log_info "Staging outputs to $ARTIFACTS ..."

    mkdir -p "$ARTIFACTS/lib" "$ARTIFACTS/include/ish" "$ARTIFACTS/vdso/arm64"

    cp "$BUILD_DIR/libish.a" "$ARTIFACTS/lib/"
    cp "$BUILD_DIR/libish_emu.a" "$ARTIFACTS/lib/"
    cp "$BUILD_DIR/libfakefs.a" "$ARTIFACTS/lib/"

    # VDSO (asserted before AND after the copy)
    assert_vdso "$BUILD_DIR/vdso/arm64/libvdso.so.elf"
    cp "$BUILD_DIR/vdso/arm64/libvdso.so.elf" "$ARTIFACTS/vdso/arm64/"
    assert_vdso "$ARTIFACTS/vdso/arm64/libvdso.so.elf"

    # Headers — same layout as upstream build_ish.sh copy_outputs.
    mkdir -p "$ARTIFACTS/include/ish/emu" "$ARTIFACTS/include/ish/kernel" \
             "$ARTIFACTS/include/ish/fs" "$ARTIFACTS/include/ish/fs/proc" \
             "$ARTIFACTS/include/ish/util" "$ARTIFACTS/include/ish/platform" \
             "$ARTIFACTS/include/ish/asbestos"
    cp "$ISH_SRC/debug.h" "$ISH_SRC/misc.h" "$ISH_SRC/xX_main_Xx.h" "$ARTIFACTS/include/ish/"
    cp "$ISH_SRC"/emu/*.h "$ARTIFACTS/include/ish/emu/"
    cp "$ISH_SRC"/kernel/*.h "$ARTIFACTS/include/ish/kernel/"
    cp "$ISH_SRC"/fs/*.h "$ARTIFACTS/include/ish/fs/"
    if [ -d "$ISH_SRC/fs/proc" ]; then
        cp "$ISH_SRC"/fs/proc/*.h "$ARTIFACTS/include/ish/fs/proc/" 2>/dev/null || true
    fi
    cp "$ISH_SRC"/util/*.h "$ARTIFACTS/include/ish/util/" 2>/dev/null || true
    cp "$ISH_SRC"/platform/*.h "$ARTIFACTS/include/ish/platform/"
    cp "$ISH_SRC"/asbestos/*.h "$ARTIFACTS/include/ish/asbestos/"
    mkdir -p "$ARTIFACTS/include/ish/asbestos/guest-arm64/gadgets-aarch64"
    cp "$ISH_SRC"/asbestos/guest-arm64/gadgets-aarch64/*.h "$ARTIFACTS/include/ish/asbestos/guest-arm64/gadgets-aarch64/" 2>/dev/null || true
    cp "$ISH_SRC"/asbestos/gadgets-generic.h "$ARTIFACTS/include/ish/asbestos/" 2>/dev/null || true
    mkdir -p "$ARTIFACTS/include/ish/emu/arch/arm64"
    cp "$ISH_SRC"/emu/arch/arm64/*.h "$ARTIFACTS/include/ish/emu/arch/arm64/" 2>/dev/null || true
    mkdir -p "$ARTIFACTS/include/ish/kernel/arch/arm64"
    cp "$ISH_SRC"/kernel/arch/arm64/*.h "$ARTIFACTS/include/ish/kernel/arch/arm64/" 2>/dev/null || true
    # cpu-offsets.h is Meson-generated (top-level custom_target 'offsets',
    # meson.build:73) and is a hard requirement: the prototype's JIT-crash
    # handler takes all its offsets from ish/cpu-offsets.h. Fail loudly
    # here instead of silently shipping a header set the prototype cannot
    # compile against (a missing header would only surface as a confusing
    # Xcode error a full Codemagic build later).
    if [ -f "$BUILD_DIR/cpu-offsets.h" ]; then
        cp "$BUILD_DIR/cpu-offsets.h" "$ARTIFACTS/include/ish/"
        log_success "cpu-offsets.h staged"
    else
        log_error "cpu-offsets.h MISSING from $BUILD_DIR (Meson 'offsets' custom_target did not run) — the prototype requires ish/cpu-offsets.h; refusing to stage an incomplete header set."
    fi
    if [ -f "$ISH_SRC/deps/config.h" ]; then
        mkdir -p "$ARTIFACTS/include/ish/deps"
        cp "$ISH_SRC/deps/config.h" "$ARTIFACTS/include/ish/deps/"
    fi

    # RootfsPatch bundle, only if the pinned source carries one (upstream
    # copies it conditionally too; at 0fd17a13 there is no such bundle).
    if [ -d "$ISH_SRC/app/RootfsPatch.bundle" ]; then
        cp -r "$ISH_SRC/app/RootfsPatch.bundle" "$ARTIFACTS/"
        log_success "RootfsPatch.bundle copied"
    fi

    create_umbrella_header
    write_manifest
    log_success "Outputs staged"
}

# Umbrella header — same include list as upstream build_ish.sh.
create_umbrella_header() {
    log_info "Creating umbrella header..."
    cat > "$ARTIFACTS/include/ish/ish.h" << 'EOF'
/*
 * iSH-ARM64 - Linux shell for iOS (ARM64 guest emulation)
 * Umbrella header for static library integration
 *
 * https://github.com/OpenMinis/ish-arm64
 */

#ifndef ISH_H
#define ISH_H

#include "misc.h"
#include "debug.h"
#include "util/verbosetrace.h"

// Kernel
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/errno.h"

// File System
#include "fs/fd.h"
#include "fs/stat.h"
#include "fs/tty.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/poll.h"
#include "fs/dev.h"

// EMU
#include "emu/cpu.h"
#include "emu/tlb.h"
#include "emu/mmu.h"
#if defined(GUEST_X86)
#include "emu/float80.h"
#endif

// Platform
#include "platform/platform.h"

#endif /* ISH_H */
EOF
    log_success "Umbrella header created"
}

# Provenance manifest — the Codemagic skip-guard reads this file to decide
# whether a rebuild can be skipped (commit + tarball SHA256 must match).
write_manifest() {
    local vdso_sha libish_sha libemu_sha libfakefs_sha
    vdso_sha="$(shasum -a 256 "$ARTIFACTS/vdso/arm64/libvdso.so.elf" | cut -d' ' -f1)"
    libish_sha="$(shasum -a 256 "$ARTIFACTS/lib/libish.a" | cut -d' ' -f1)"
    libemu_sha="$(shasum -a 256 "$ARTIFACTS/lib/libish_emu.a" | cut -d' ' -f1)"
    libfakefs_sha="$(shasum -a 256 "$ARTIFACTS/lib/libfakefs.a" | cut -d' ' -f1)"
    python3 - "$ARTIFACTS/ish-manifest.json" << PYEOF
import json, sys
manifest = {
    "ish_commit": "$ISH_COMMIT",
    "ish_url": "$ISH_URL",
    "ish_tarball_url": "$ISH_TARBALL_URL",
    "ish_tarball_sha256": "$ISH_TARBALL_SHA256",
    "deployment_target": "$IOS_DEPLOYMENT_TARGET",
    "meson_options": {
        "buildtype": "release",
        "b_ndebug": True,
        "log": "",
        "log_handler": "nslog",
        "kernel": "ish",
        "engine": "asbestos",
        "guest_arch": "arm64",
        "jit": True,
        "jit_emit": False,
    },
    "aot": None,
    "libs": {
        "libish.a": "$libish_sha",
        "libish_emu.a": "$libemu_sha",
        "libfakefs.a": "$libfakefs_sha",
    },
    "vdso": {
        "path": "vdso/arm64/libvdso.so.elf",
        "sha256": "$vdso_sha",
    },
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
    echo -e "${GREEN}🎉 iSH Build Complete (device arm64, no AOT)!${NC}"
    echo "============================================================"
    echo ""
    echo "Libraries:"
    ls -lh "$ARTIFACTS/lib/"*.a
    echo ""
    echo "VDSO:"
    ls -lh "$ARTIFACTS/vdso/arm64/libvdso.so.elf"
    file "$ARTIFACTS/vdso/arm64/libvdso.so.elf"
    echo ""
    echo "Headers:   $ARTIFACTS/include/ish/"
    echo "Manifest:  $ARTIFACTS/ish-manifest.json"
    echo ""
    echo "Xcode integration (prototype App owner):"
    echo "  1. Add lib/*.a to 'Link Binary With Libraries'"
    echo "  2. HEADER_SEARCH_PATHS -> IShArtifacts/include"
    echo "  3. LIBRARY_SEARCH_PATHS -> IShArtifacts/lib"
    echo "  4. Link libsqlite3.tbd (iSH fakefs needs SQLite)"
    echo "  5. Copy Bundle Resources: vdso/arm64/libvdso.so.elf (+ later alpine-rootfs.zip)"
    echo "  6. Do NOT add -force_load libish_aot.a in v1 (no AOT image yet)"
    echo ""
    echo "============================================================"
}

clean_build() {
    log_info "Cleaning iSH build artifacts..."
    rm -rf "$BUILD_DIR"
    rm -rf "$ARTIFACTS/lib" "$ARTIFACTS/include" "$ARTIFACTS/vdso" "$ARTIFACTS/ish-manifest.json"
    log_success "Clean completed (tarball cache kept in $CACHE_DIR)"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  dsh-go iSH Static Library Builder (device arm64, no AOT)"
    echo "  Source: $ISH_URL @ $ISH_COMMIT"
    echo "============================================================"
    echo ""

    case "${1:-}" in
        clean)
            clean_build
            exit 0
            ;;
        --simulator|--all)
            log_error "Simulator slices are not built: iSH ships device-only by design (and the dsh-go prototype is device-only). Remove $1."
            ;;
        "")
            ;;
        *)
            log_error "Unknown argument: $1 (expected: no args, or clean)"
            ;;
    esac

    check_prerequisites
    check_vdso_toolchain
    fetch_ish_source
    setup_cross_compile
    build_ish
    copy_outputs
    print_summary
}

main "$@"
