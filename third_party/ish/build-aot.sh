#!/bin/bash
# ============================================================================
# build-aot.sh — dsh-go AOT image staging for iOS (arm64 device only)
# ============================================================================
# Stages libish_aot.a into app/ios/IShArtifacts/lib/ for the Runner target,
# which links it with -force_load (see project.pbxproj OTHER_LDFLAGS). The
# images self-register via a constructor calling ish_aot_register(); without
# -force_load the linker would drop the archive entirely (no symbol is
# referenced from the app).
#
# Three modes, in priority order:
#   1. local .S (third_party/ish/aot/aot_*.S) — freshly recorded images.
#      Assembled here (xcrun clang -c -arch arm64, object cache) and packed
#      with libtool -static. This is the path record-aot.sh uses.
#   2. download (third_party/ish/aot-manifest.json with download.url +
#      download.sha256) — a recorded set from controlled storage (a GitHub
#      release on the fork, tag aot-minimal-<abi>). SHA256-verified; a
#      mismatch fails the build loudly, never silently ships a wrong image.
#   3. empty stub — no images at all. The archive still exists (one object
#      with `void ish_aot_none(void) {}`) so -force_load always has something
#      to load and the app builds and runs on the pure gadget interpreter.
#      This is the v1 shipping state (design §2.8 / §3 stage 4.3).
#
# The ABI gate is NOT in this script: it lives in the engine itself
# (asbestos/guest-arm64/jit.c aot_init(): an image whose abi /
# prologue_words / entry_off / n_pinned differs from this ish is rejected
# at startup, listed in /proc/ish/jit as "rejected", and the app runs
# without AOT — never a crash). Verify on device with:
#   cat /proc/ish/jit     # "images: N in use, M rejected (abi XXXXXXXX)"
# The abi recorded in app/ios/IShArtifacts/aot-manifest.json is the one to
# compare against the device's /proc/ish/jit abi.
#
# Adapted from OpenMinis deps/build_aot.sh. Differences from upstream, all
# deliberate:
#   - Device only (iphoneos arm64, min iOS 15.0 to match dsh-go's Runner).
#     No simulator slice: dsh-go is device-only by design (build-ish.sh).
#   - The download mode is new (OpenMinis keeps .S in deps/aot/ locally);
#     dsh-go records on Codemagic and downloads the .a from a release.
#   - Output is app/ios/IShArtifacts/lib/libish_aot.a (+ aot-manifest.json
#     provenance), not deps/libs/.
#
# Prerequisites (macOS): Xcode (xcrun / iOS SDK), python3 (manifest only).
# Plus curl + shasum for the download mode.
#
# Usage (run from the repository root, or anywhere — paths resolve from the
# script's own location):
#   third_party/ish/build-aot.sh [clean]
#
#   (no flag)  stage libish_aot.a + aot-manifest.json into IShArtifacts
#   clean      remove the staged libish_aot.a + aot-manifest.json (the .S
#              files and the download cache are kept)
#
# Output layout (this is the contract with the Runner target — do not change):
#   app/ios/IShArtifacts/lib/libish_aot.a
#   app/ios/IShArtifacts/aot-manifest.json   (mode, image list, abi, SHA256)
#
# Idempotency: assembling skips .S files whose object is newer (object
# cache in third_party/ish/aot/.build/); downloading skips when the staged
# .a already matches the manifest SHA256. Use `clean` to force a rebuild.
#
# License note: AOT images are translations of GPL-licensed guest code
# (Alpine packages) recorded by a GPL-3.0 tool; the images themselves are
# covered by the same corresponding-source duty as the iSH fork (design §5).
# See third_party/ish/source.json.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Repo root is two levels above third_party/ish/. (In the staging directory
# this resolves to the staging root, which mirrors the repo layout.)
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS="$REPO_ROOT/app/ios/IShArtifacts"
AOT_DIR="$REPO_ROOT/third_party/ish/aot"
MANIFEST_SRC="$REPO_ROOT/third_party/ish/aot-manifest.json"
OBJ_DIR="$AOT_DIR/.build"

IOS_DEPLOYMENT_TARGET="15.0"
PLATFORM="iphoneos"
MIN_FLAG="-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}" >&2; exit 1; }

if [ "${1:-}" = "clean" ]; then
    rm -f "$ARTIFACTS/lib/libish_aot.a" "$ARTIFACTS/aot-manifest.json"
    log_success "Cleaned staged libish_aot.a + aot-manifest.json"
    exit 0
fi

# ============================================================================
# Prerequisites
# ============================================================================
command -v xcrun >/dev/null || log_error "Xcode command line tools are required (xcrun not found)"
xcode-select -p >/dev/null 2>&1 || log_error "Xcode command line tools are required. Run: xcode-select --install"
command -v python3 >/dev/null || log_error "Python 3 is required (manifest only)"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
[ -n "$SDK" ] || log_error "Could not resolve iphoneos SDK path via xcrun"

mkdir -p "$ARTIFACTS/lib" "$OBJ_DIR"

# Pre-read the manifest download URL. An absent manifest, or a manifest
# with no download.url, means stub mode (AOT disabled). This lets us
# disable AOT by clearing the download section in aot-manifest.json
# without deleting the file (the recorded set stays documented for
# re-enablement). See build 29 (2026-11-15): the recorded images crash
# the device terminal on every boot, so AOT is off until the crash is
# diagnosed.
MANIFEST_URL=""
if [ -f "$MANIFEST_SRC" ]; then
    MANIFEST_URL="$(python3 -c "import json; print(json.load(open('$MANIFEST_SRC')).get('download', {}).get('url', ''))")"
fi

# ============================================================================
# Mode 1: local .S images — assemble them (record-aot.sh's output)
# ============================================================================
shopt -s nullglob
images=("$AOT_DIR"/aot_*.S)
shopt -u nullglob

OUT="$ARTIFACTS/lib/libish_aot.a"

if [ "${#images[@]}" -gt 0 ]; then
    log_info "Assembling ${#images[@]} local AOT image(s) for $PLATFORM ..."
    objs=()
    pids=()
    for src in "${images[@]}"; do
        obj="$OBJ_DIR/$(basename "${src%.S}").o"
        objs+=("$obj")
        # Assembling the large images takes minutes: skip unchanged ones.
        if [ "$obj" -nt "$src" ]; then
            echo "⏭️  $(basename "$src") unchanged"
            continue
        fi
        echo "🔧 assembling $(basename "$src") ($(du -h "$src" | cut -f1)) for $PLATFORM"
        xcrun --sdk "$PLATFORM" clang -c -arch arm64 -isysroot "$SDK" \
            "$MIN_FLAG" -o "$obj.tmp" "$src" && mv "$obj.tmp" "$obj" &
        pids+=($!)
    done
    for pid in "${pids[@]:-}"; do wait "$pid"; done

    rm -f "$OUT"
    xcrun libtool -static -o "$OUT" "${objs[@]}"
    MODE="assembled"
    log_success "$OUT ($(du -h "$OUT" | cut -f1), ${#images[@]} image(s))"

# ============================================================================
# Mode 2: download a recorded set (aot-manifest.json, SHA256-pinned)
# ============================================================================
elif [ -n "$MANIFEST_URL" ]; then
    URL="$MANIFEST_URL"
    SHA="$(python3 -c "import json; print(json.load(open('$MANIFEST_SRC')).get('download', {}).get('sha256', ''))")"
    [ -n "$SHA" ] || log_error "aot-manifest.json has no download.sha256 — refusing to download an unpinned image"
    command -v curl >/dev/null || log_error "curl is required (download mode)"
    command -v shasum >/dev/null || log_error "shasum is required (download mode)"

    if [ -f "$OUT" ] && printf '%s  %s\n' "$SHA" "$OUT" | shasum -a 256 -c - >/dev/null 2>&1; then
        log_info "Staged libish_aot.a already matches manifest SHA256, skipping download"
    else
        log_info "Downloading libish_aot.a from $URL ..."
        tmp="$(mktemp "${TMPDIR:-/tmp}/libish_aot.XXXXXX")"
        curl --fail --location --retry 2 "$URL" -o "$tmp"
        printf '%s  %s\n' "$SHA" "$tmp" | shasum -a 256 -c - \
            || { rm -f "$tmp"; log_error "Downloaded libish_aot.a does NOT match manifest SHA256 $SHA — refusing to stage it"; }
        mv "$tmp" "$OUT"
        log_success "Downloaded + verified $OUT ($(du -h "$OUT" | cut -f1))"
    fi
    MODE="downloaded"

# ============================================================================
# Mode 3: empty stub — no images, pure gadget interpreter (v1 shipping state)
# ============================================================================
else
    log_info "No local .S images and no manifest download URL (AOT disabled) — building an empty libish_aot.a (stub)"
    stub="$OBJ_DIR/aot_none.o"
    echo 'void ish_aot_none(void) {}' | xcrun --sdk "$PLATFORM" clang -x c -c -arch arm64 \
        -isysroot "$SDK" "$MIN_FLAG" -o "$stub" -
    rm -f "$OUT"
    xcrun libtool -static -o "$OUT" "$stub"
    MODE="stub"
    log_success "$OUT (empty stub, $(du -h "$OUT" | cut -f1))"
fi

# ============================================================================
# Provenance manifest (staged next to the archive)
# ============================================================================
python3 - "$ARTIFACTS/aot-manifest.json" "$MODE" "$OUT" "$MANIFEST_SRC" << PYEOF
import hashlib, json, os, sys
out_manifest, mode, lib_path, src_manifest = sys.argv[1:5]
sha = hashlib.sha256(open(lib_path, 'rb').read()).hexdigest()
doc = {
    "mode": mode,
    "libish_aot_a": {"sha256": sha, "size": os.path.getsize(lib_path)},
    "platform": "iphoneos",
    "deployment_target": "$IOS_DEPLOYMENT_TARGET",
}
if mode == "assembled":
    import glob
    doc["images"] = sorted(os.path.basename(p) for p in glob.glob(os.path.join("$AOT_DIR", "aot_*.S")))
elif mode == "downloaded" and os.path.isfile(src_manifest):
    src = json.load(open(src_manifest))
    doc["abi"] = src.get("abi")
    doc["ish_commit"] = src.get("ish_commit")
    doc["recorded_at"] = src.get("recorded_at")
    doc["download"] = src.get("download")
    doc["images"] = src.get("images", [])
elif mode == "stub":
    doc["images"] = []
json.dump(doc, open(out_manifest, 'w'), indent=2)
print(f"aot-manifest.json: mode={mode}, libish_aot.a sha256={sha[:12]}..., images={len(doc['images'])}")
PYEOF

log_success "AOT staging done (mode=$MODE)"
