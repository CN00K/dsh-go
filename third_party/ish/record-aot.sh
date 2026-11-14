#!/bin/bash
# ============================================================================
# record-aot.sh — record the minimal AOT set for dsh-go (macOS arm64 only)
# ============================================================================
# Records the six minimal AOT images (design §3 stage 4.3) with a CLI ish
# built from the same pinned commit as the app's libish, on the app's own
# rootfs, and assembles them into libish_aot.a via build-aot.sh:
#   musl, busybox, zlib, libcrypto, libssl, pcre2
# (The full 25-image set is a later iteration; these six are the ones the
# design names for stage 4.)
#
# HOW IT WORKS (OpenMinis deps/aot/README.md "Re-recording" + the ish fork's
# benchmark/aojit suite):
#   1. A CLI ish is built from the pinned ish commit with the EMITTING JIT
#      (-Djit=true, no -Djit_emit=false — the recorder must emit code).
#   2. The app's rootfs (from prepare-rootfs.sh) is copied to a scratch
#      rootfs A; the training packages are installed in it with apk.
#   3. Each module is recorded in ONE ish run (ISH_JIT_PIC=1, so the code
#      is position-independent and has the app's abi): the workload runs,
#      the translations are written to a .jsonl recording, and gen.py turns
#      it into a .S image (symbol _ish_aot_module_<name>, constructor calls
#      ish_aot_register()).
#   4. build-aot.sh assembles the .S files into libish_aot.a; a manifest
#      (aot-manifest.json) records the abi, per-image build-id and the
#      archive SHA256.
#
# MACOS ARM64 ONLY. The recorder is a CLI ish built for the host, and the
# JIT emits host-native code: on an x86_64 host it would emit x86_64 code,
# which is useless for the arm64 iOS device. There is no cross-recording
# mode. This script refuses to run on a non-arm64 host. On Codemagic use
# the ios-aot-record workflow (mac_mini_m2, Apple Silicon).
#
# The ish CLI is invoked with -r <data-dir> throughout (the AOJIT suite's
# mode: install.sh, record.sh and the suite README's apk add all use -r;
# -r reads the data dir directly, so host-staged workloads are visible
# without fakefs metadata). The app itself uses -f (fakefs); the recording
# rootfs A is throwaway, so the mode difference does not matter — only the
# module code that runs matters, and it is identical.
#
# GATES (each one stops the run — a silent partial recording is how the abi
# 1f3bb5a0 copies from ish-arm64 lost 80% of libssl's coverage):
#   * the recorder's abi is readable (it is printed and stored; it must
#     equal the app's abi because both come from the same pinned commit —
#     if it is not 1f3bb5a0, that only means a layout changed since
#     OpenMinis recorded; the images still match the app, which is built
#     from the same commit);
#   * the bundled package versions are the expected ones (musl 1.2.5-r8,
#     busybox 1.37.0-r8, zlib 1.3.1-r2, libcrypto3/libssl3 3.3.2-r4,
#     pcre2 10.43-r0) — a different version means the image name would be
#     wrong, so fail loudly and update the EXPECTED_* below;
#   * NEVER install the openssl CLI in the guest: it upgrades libcrypto3
#     away from 3.3.2-r4 (the localhost certificates are made on the host
#     instead, as in OpenMinis record_local.sh);
#   * a dry run of each workload prints its ok markers and no FAIL;
#   * each recording has at least its translation floor (about 80% of the
#     2026-10-05 OpenMinis recording at abi 1f3bb5a0).
#
# Usage: third_party/ish/record-aot.sh [musl busybox zlib libcrypto libssl pcre2]
#   (default: all six)
#   WORK=<dir>   scratch (default ${TMPDIR:-/tmp}/dsh-aot-rec), ~2 GB
#   OUT=<dir>    where the .S go (default third_party/ish/aot)
#
# Outputs:
#   third_party/ish/aot/aot_<name>.S   (gitignored, ~100-300 MB for the six)
#   app/ios/IShArtifacts/lib/libish_aot.a  (assembled by build-aot.sh)
#   app/ios/IShArtifacts/aot-manifest.json (abi, images, SHA256 — copy the
#     download block into third_party/ish/aot-manifest.json after uploading
#     the .a to the GitHub release aot-minimal-<abi>; see STAGE4-NOTES.md)
#
# Adapted from OpenMinis deps/aot/tools/record_local.sh (libcrypto/libssl/
# pcre2) + the ish fork's benchmark/aojit suite (install.sh, record.sh,
# images.json) + the AOT README's re-recording steps. The workloads are the
# fork's own (benchmark/aojit/guest/) except pcre_train.sh, which is
# OpenMinis's (vendored in third_party/ish/aot-workloads/).
#
# License note: see build-aot.sh (same corresponding-source duty).
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ISH_SRC="$REPO_ROOT/third_party/ish-src"
CACHE_DIR="$REPO_ROOT/third_party/ish/.cache"
ARTIFACTS="$REPO_ROOT/app/ios/IShArtifacts"
AOT_DIR="${OUT:-$REPO_ROOT/third_party/ish/aot}"
WORK="${WORK:-${TMPDIR:-/tmp}/dsh-aot-rec}"

# --- Pinned source (must match third_party/ish/source.json + build-ish.sh) ---
ISH_COMMIT="0fd17a135e78b7a0cf08a4f5831217bbb76ed22f"
ISH_URL="https://github.com/OpenMinis/ish-arm64"
ISH_TARBALL_URL="https://codeload.github.com/OpenMinis/ish-arm64/tar.gz/${ISH_COMMIT}"
ISH_TARBALL_SHA256="d26a47031c8ecf306e5c2c20989549be2383100c051c25cd0adab8d6e5c8e526"
ISH_TARBALL_NAME="ish-arm64-${ISH_COMMIT}.tar.gz"

# --- Expected bundled package versions (Alpine 3.21.0 minirootfs, pinned) ---
# Gate: fail loudly if the rootfs has different ones (the image file name
# carries the version; a silent mismatch would ship a misnamed image).
EXPECTED_MUSL="1.2.5-r8"
EXPECTED_BUSYBOX="1.37.0-r8"
EXPECTED_ZLIB="1.3.1-r2"
EXPECTED_OPENSSL="3.3.2-r4"
EXPECTED_PCRE2="10.43-r0"

# --- Per-module settings: file | record substring | floor | workload | ok markers
# Floors are ~80% of OpenMinis's 2026-10-05 recording at abi 1f3bb5a0
# (musl 4807, busybox 6559, libcrypto 19316, libssl 7327, pcre2 5138).
# zlib's count was not published; its floor is a smoke floor only.
spec() {
    case "$1" in
        musl)      echo "aot_musl_1.2.5-r8.S|ld-musl|3800|/tmp/aojit/shell/musl_train.sh|zlib-train-ok" ;;
        busybox)   echo "aot_busybox_1.37.0-r8.S|/bin/busybox|5200|/tmp/aojit/busybox/busybox_train.sh|" ;;
        zlib)      echo "aot_zlib_1.3.1-r2.S|libz.so|200|/tmp/aojit/zlib/zlib_train.sh|zlib-train-ok" ;;
        libcrypto) echo "aot_libcrypto_3.3.2-r4.S|libcrypto.so|15000|/tmp/aojit/net/tls_train.sh|agent-cold-ok tls-train-ok" ;;
        libssl)    echo "aot_libssl_3.3.2-r4.S|libssl.so|5800|/tmp/aojit/net/tls_train.sh|agent-cold-ok tls-train-ok" ;;
        pcre2)     echo "aot_pcre2_10.43-r0.S|libpcre2-8.so|4100|/tmp/aojit/minis/pcre_train.sh|pcre-train-ok" ;;
        *) return 1 ;;
    esac
}
field() { spec "$1" | cut -d'|' -f"$2"; }

MODULES=("${@:-musl busybox zlib libcrypto libssl pcre2}"); MODULES=(${MODULES[@]})

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

fail() { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }
step() { echo; echo -e "${BLUE}==> $*${NC}"; }
log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }

# ============================================================================
# Prerequisites (macOS arm64 only — the JIT emits host-native code)
# ============================================================================
[ "$(uname -m)" = "arm64" ] || fail "record-aot.sh runs on macOS arm64 only (this host is $(uname -m)): the JIT emits host-native code, and an x86_64 host cannot produce arm64 images. Use the ios-aot-record Codemagic workflow (mac_mini_m2)."
[ "$(uname -s)" = "Darwin" ] || fail "record-aot.sh runs on macOS only (this host is $(uname -s)). Use the ios-aot-record Codemagic workflow."
for t in xcrun meson ninja python3 pip3 curl shasum unzip openssl tar; do
    command -v "$t" >/dev/null || fail "$t not found (install it first: brew install llvm ninja libarchive meson; pip3 install tqdm)"
done
python3 -c "import tqdm" 2>/dev/null || fail "Python module tqdm is missing (gen.py needs it): pip3 install tqdm"

mkdir -p "$WORK" "$AOT_DIR"

# ============================================================================
# Pinned iSH source (same tarball logic as build-ish.sh)
# ============================================================================
step "📥 iSH source @ $ISH_COMMIT"
mkdir -p "$CACHE_DIR"
tarball="$CACHE_DIR/$ISH_TARBALL_NAME"
if [ -f "$tarball" ]; then
    if printf '%s  %s\n' "$ISH_TARBALL_SHA256" "$tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
        log_info "Cached tarball already matches pinned SHA256, skipping download"
    else
        log_info "Cached tarball does NOT match pinned SHA256 — re-downloading"
        rm -f "$tarball"
        curl --fail --location --retry 2 "$ISH_TARBALL_URL" -o "$tarball"
        printf '%s  %s\n' "$ISH_TARBALL_SHA256" "$tarball" | shasum -a 256 -c -
    fi
else
    log_info "Downloading $ISH_TARBALL_URL"
    curl --fail --location --retry 2 "$ISH_TARBALL_URL" -o "$tarball"
    printf '%s  %s\n' "$ISH_TARBALL_SHA256" "$tarball" | shasum -a 256 -c -
fi
marker="$ISH_SRC/.ish-source-commit"
if [ -f "$marker" ] && [ "$(cat "$marker")" = "$ISH_COMMIT" ] && [ -f "$ISH_SRC/meson.build" ]; then
    log_info "Source already extracted at $ISH_COMMIT, skipping"
else
    log_info "Extracting tarball to $ISH_SRC ..."
    rm -rf "$ISH_SRC"
    mkdir -p "$ISH_SRC"
    tar xzf "$tarball" -C "$ISH_SRC" --strip-components=1
    [ -f "$ISH_SRC/meson.build" ] || fail "Extracted source has no meson.build — tarball contents unexpected"
    [ -f "$ISH_SRC/tools/jit_aot/gen.py" ] || fail "Extracted source has no tools/jit_aot/gen.py — tarball contents unexpected"
    [ -d "$ISH_SRC/benchmark/aojit/guest" ] || fail "Extracted source has no benchmark/aojit/guest — tarball contents unexpected"
    printf '%s\n' "$ISH_COMMIT" > "$marker"
    log_success "Source extracted at $ISH_COMMIT"
fi

# ============================================================================
# Rootfs (the app's own, from prepare-rootfs.sh — deterministic zip)
# ============================================================================
step "📦 rootfs (prepare-rootfs.sh)"
bash "$SCRIPT_DIR/prepare-rootfs.sh" 2>&1 | tail -5
[ -f "$ARTIFACTS/alpine-rootfs.zip" ] || fail "prepare-rootfs.sh did not produce app/ios/IShArtifacts/alpine-rootfs.zip"

# ============================================================================
# Recorder: CLI ish from the pinned commit, emitting JIT (-Djit=true)
# ============================================================================
step "🔧 recorder: CLI ish from $ISH_COMMIT (-Djit=true, emitting JIT)"
REC="$WORK/ish-rec"; I="$REC/ish"
if [ ! -d "$REC" ]; then
    meson setup "$REC" "$ISH_SRC" -Dguest_arch=arm64 -Dengine=asbestos -Dkernel=ish -Djit=true \
        -Db_ndebug=true --buildtype=release > "$WORK/meson.log" 2>&1 \
        || fail "meson setup for the recorder failed ($WORK/meson.log)"
fi
ninja -C "$REC" > "$WORK/ninja.log" 2>&1 || ninja -C "$REC" >> "$WORK/ninja.log" 2>&1 \
    || fail "recorder build failed ($WORK/ninja.log)"
[ -x "$I" ] || fail "recorder binary missing: $I"
log_success "Recorder built: $I"

# ============================================================================
# Rootfs A: the recording environment (throwaway copy of the shipped rootfs)
# ============================================================================
step "📦 rootfs A (recording environment) + training packages"
rm -rf "$WORK/rec-A"; mkdir -p "$WORK/rec-A"
unzip -q "$ARTIFACTS/alpine-rootfs.zip" -d "$WORK/rec-A"
ROOT="$WORK/rec-A/alpine-rootfs"
DATA="$ROOT/data"
[ -d "$DATA" ] || fail "rootfs A has no data/ dir — the zip layout changed"

# -r takes the data dir (the AOJIT suite's mode; see the header note).
g() { "$I" -r "$DATA" /bin/sh -c "$1" 2>&1 | { grep -v '^NETDIAG' || true; }; }

ABI_REC=$(ISH_JIT_PIC=1 "$I" -r "$DATA" /bin/sh -c 'grep -o "abi [0-9a-f]*" /proc/ish/jit' 2>/dev/null | awk '{print $2}')
[ -n "$ABI_REC" ] || fail "could not read the recorder's abi (/proc/ish/jit)"
log_info "recorder abi: $ABI_REC (expected 1f3bb5a0 for this commit; a different value only means a layout changed since OpenMinis recorded — the images still match the app, which is built from the same commit)"
if [ "$ABI_REC" != "1f3bb5a0" ]; then
    echo -e "${YELLOW}⚠️  recorder abi is $ABI_REC, not 1f3bb5a0 — the recorded images will carry $ABI_REC and the app (same commit) will accept them; update the release tag accordingly (aot-minimal-$ABI_REC)${NC}"
fi

# Training packages. NEVER install the openssl CLI: it upgrades libcrypto3
# away from 3.3.2-r4 (the TLS certificates are made on the host, below).
g 'echo nameserver 223.5.5.5 > /etc/resolv.conf; apk update >/dev/null 2>&1; apk add python3 py3-pip py3-numpy py3-matplotlib py3-requests nodejs bzip2 git ripgrep >/dev/null 2>&1; true'
V=$(g 'apk info -v 2>/dev/null | grep -E "^(musl|busybox|zlib|libcrypto3|libssl3|pcre2|python3|py3-requests|nodejs|git|ripgrep)-[0-9]" | sort | tr "\n" " "')
echo "guest: $V"
echo "$V" | grep -q "musl-$EXPECTED_MUSL" || fail "bundled musl is not $EXPECTED_MUSL: $V (update EXPECTED_MUSL)"
echo "$V" | grep -q "busybox-$EXPECTED_BUSYBOX" || fail "bundled busybox is not $EXPECTED_BUSYBOX: $V (update EXPECTED_BUSYBOX)"
echo "$V" | grep -q "zlib-$EXPECTED_ZLIB" || fail "bundled zlib is not $EXPECTED_ZLIB: $V (update EXPECTED_ZLIB)"
echo "$V" | grep -q "libcrypto3-$EXPECTED_OPENSSL" && echo "$V" | grep -q "libssl3-$EXPECTED_OPENSSL" \
    || fail "rootfs A no longer has OpenSSL $EXPECTED_OPENSSL: $V (update EXPECTED_OPENSSL)"
echo "$V" | grep -q "pcre2-$EXPECTED_PCRE2" || fail "pcre2 is not $EXPECTED_PCRE2: $V (update EXPECTED_PCRE2 — the Alpine repo may have moved on)"
echo "$V" | grep -q "py3-requests-" || fail "py3-requests missing: agent_cold.sh would FAIL and the TLS images would lose the verification path"

# ============================================================================
# Workloads: the AOJIT suite (install.sh) + host-made TLS certs + pcre_train
# ============================================================================
step "📂 workloads (AOJIT suite) + host-made TLS certificates"
"$ISH_SRC/benchmark/aojit/install.sh" "$I" "$DATA" > "$WORK/install.log" 2>&1 \
    || fail "AOJIT suite staging failed ($WORK/install.log)"
# install.sh runs setup.sh in the guest; check it finished.
g 'test -f /tmp/aojit/.setup_done' || fail "AOJIT suite setup did not finish (/tmp/aojit/.setup_done missing; see $WORK/install.log)"

S="$WORK/stage"; rm -rf "$S"; mkdir -p "$S/net" "$S/minis"
cp "$ISH_SRC/benchmark/aojit/guest/net"/* "$S/net/"
cp "$SCRIPT_DIR/aot-workloads/pcre_train.sh" "$S/minis/"
( cd "$S/net"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.crt -days 365 -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost,IP:127.0.0.1 2>/dev/null
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ec.key -out ec.crt -days 365 \
      -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 2>/dev/null )
# Host-side copy into the data dir (visible in -r mode; see the header note).
cp "$S/net"/rsa.key "$S/net"/rsa.crt "$S/net"/ec.key "$S/net"/ec.crt "$DATA/tmp/aojit/net/"
cp "$S/minis/pcre_train.sh" "$DATA/tmp/aojit/minis/"
g 'cd /tmp/aojit/net && cat /etc/ssl/certs/ca-certificates.crt rsa.crt ec.crt > ca_bundle.pem && test -f ca_bundle.pem' \
    || fail "could not build ca_bundle.pem in the guest"
log_success "Workloads staged (suite + certs + pcre_train.sh)"

# ============================================================================
# Per-module: dry run -> record -> gen.py -> floor gate
# ============================================================================
for m in "${MODULES[@]}"; do
    spec "$m" >/dev/null || fail "unknown module $m (musl busybox zlib libcrypto libssl pcre2)"
    F_=$(field "$m" 1); M_=$(field "$m" 2); MIN_=$(field "$m" 3); WL_=$(field "$m" 4); OK_=$(field "$m" 5)

    step "🧪 dry run for $m: $WL_"
    "$I" -r "$DATA" /bin/sh "$WL_" 2>&1 | { grep -v "^NETDIAG" || true; } > "$WORK/dry_$m.log" || true
    grep -q FAIL "$WORK/dry_$m.log" && fail "dry run printed FAIL ($WORK/dry_$m.log)"
    for k in $OK_; do grep -q "$k" "$WORK/dry_$m.log" || fail "dry run missing '$k' ($WORK/dry_$m.log)"; done

    step "📼 recording $m ($M_)"
    rec="$WORK/$m.jsonl"; rm -f "$rec"
    ISH_JIT_PIC=1 ISH_JIT_RECORD="$rec" ISH_JIT_RECORD_MOD="$M_" \
        "$I" -r "$DATA" /bin/sh "$WL_" 2>&1 | { grep -v "^NETDIAG" || true; } > "$WORK/rec_$m.log" || true
    grep -q FAIL "$WORK/rec_$m.log" && fail "recording run printed FAIL ($WORK/rec_$m.log)"
    n=$(wc -l < "$rec" | tr -d ' ')
    [ "$n" -ge "$MIN_" ] || fail "$m: only $n translations (floor $MIN_) — the workload did not run fully"
    name=$(basename "$F_" .S | sed 's/^aot_//' | tr '.-' '__')
    python3 "$ISH_SRC/tools/jit_aot/gen.py" "$rec" "$I" "$DATA" "$WORK/$F_" --name "$name" 2>&1 | grep '✅' \
        || fail "gen.py $m (see the log above)"
    cp "$WORK/$F_" "$AOT_DIR/$F_"
    echo "✅ $m: $n translations -> $AOT_DIR/$F_"
done

# ============================================================================
# Assemble + manifest
# ============================================================================
step "📋 assemble libish_aot.a (build-aot.sh)"
bash "$SCRIPT_DIR/build-aot.sh" 2>&1 | tail -8
[ -f "$ARTIFACTS/lib/libish_aot.a" ] || fail "build-aot.sh did not produce libish_aot.a"

step "📋 result"
python3 "$SCRIPT_DIR/aot-tools/image_info.py" "$AOT_DIR"
LIB_SHA=$(shasum -a 256 "$ARTIFACTS/lib/libish_aot.a" | cut -d' ' -f1)
LIB_SIZE=$(stat -f%z "$ARTIFACTS/lib/libish_aot.a" 2>/dev/null || stat -c%s "$ARTIFACTS/lib/libish_aot.a")
python3 - "$AOT_DIR" "$ABI_REC" "$ISH_COMMIT" "$LIB_SHA" "$LIB_SIZE" << PYEOF
import glob, json, os, subprocess, sys
aot_dir, abi, ish_commit, lib_sha, lib_size = sys.argv[1:6]
def info(path):
    out = subprocess.run([sys.executable, "$SCRIPT_DIR/aot-tools/image_info.py", "--json", path],
                         capture_output=True, text=True).stdout
    return json.loads(out)[0]
images = []
for p in sorted(glob.glob(os.path.join(aot_dir, "aot_*.S"))):
    i = info(p)
    images.append({
        "file": i["file"], "module": i["module"], "family": i["family"],
        "build_id": i["build_id"], "abi": i["abi"], "translations": i["translations"],
        "sha256": __import__("hashlib").sha256(open(p, 'rb').read()).hexdigest(),
        "size": i["size"],
    })
doc = {
    "abi": abi, "ish_commit": ish_commit,
    "recorded_at": __import__("datetime").date.today().isoformat(),
    "download": {"url": f"REPLACE-ME: https://github.com/CN00K/dsh-go/releases/download/aot-minimal-{abi}/libish_aot.a",
                 "sha256": lib_sha},
    "libish_aot_a": {"sha256": lib_sha, "size": int(lib_size)},
    "images": images,
}
json.dump(doc, open("$ARTIFACTS/aot-manifest.json", 'w'), indent=2)
print(f"aot-manifest.json: abi={abi}, {len(images)} images, libish_aot.a sha256={lib_sha[:12]}...")
PYEOF

cat << EOF

✅ Recording done. Next steps (for the main agent):
   1. Upload app/ios/IShArtifacts/lib/libish_aot.a to the GitHub release
      tag aot-minimal-$ABI_REC (create it on CN00K/dsh-go if missing).
   2. Copy app/ios/IShArtifacts/aot-manifest.json to
      third_party/ish/aot-manifest.json, replacing REPLACE-ME in
      download.url with the real release asset URL, and commit it.
      (Then every app build downloads + SHA256-verifies the .a.)
   3. Trigger the ios-stage2-verify workflow and check the 07c step log.
   4. On device: cat /proc/ish/jit — it must list 6 images "in use",
      0 rejected, abi $ABI_REC; then time grep/find before/after.
EOF
