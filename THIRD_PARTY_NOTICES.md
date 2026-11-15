# Third-Party Notices — dsh-go iOS Linux sandbox (iSH)

This build of dsh-go bundles third-party software. The notices below cover
the components added by the iSH Linux sandbox integration
(`feat/ish-linux-sandbox`). The app itself is licensed under the
GNU Affero General Public License v3 (see `LICENSE` at the repo root).

Source for this build (including all modifications): the `feat/ish-linux-sandbox`
branch of <https://github.com/CN00K/dsh-go>. Upstream dsh-go:
<https://github.com/wedfkewn/dsh-go>.

## iSH — Linux shell environment

- **What:** iSH, the user-mode Linux kernel + Alpine userland that powers the
  in-app Linux sandbox and shell (terminal + agent `bash`).
- **Version/pin:** OpenMinis/ish-arm64 @ `0fd17a135e78b7a0cf08a4f5831217bbb76ed22f`
  (see `third_party/ish/source.json`).
- **License:** GNU General Public License v3 (GPLv3). Contributions after
  commit `0e3a4144` are additionally licensed under GPLv2. The additional
  terms in `LICENSE.IOS` also apply (App Store distribution waiver).
- **Source:** <https://github.com/openminis/ish-arm64>
- **License texts:** `LICENSE.md` and `LICENSE.IOS` in the iSH source tree.
- **Note:** Even when distributed as a sideloaded IPA, the GPL requires
  providing the corresponding source. This fork's branch above is the
  corresponding source for the iSH code as built here, including the
  dsh-go-specific changes (crash-handler park branch, `ISHKernel` /
  `ISHShellExecutor` / `RootfsManager` integration).

## Alpine Linux — guest root filesystem

- **What:** Alpine Linux 3.21.0 minirootfs, converted to the fakefs format
  iSH runs (`alpine-rootfs.zip`, deterministic build — see
  `third_party/ish/prepare-rootfs.sh`).
- **License:** Alpine is a collection of packages under their own licenses
  (MIT, BSD, GPL, Apache, and others). The full per-package license list is
  in the Alpine package database for 3.21.0.
- **Source:** <https://alpinelinux.org> and
  <https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/>.
- **AOT-recorded modules** (from this rootfs, recorded into `libish_aot.a`):
  musl (MIT), busybox (GPLv2), zlib (zlib license), OpenSSL libcrypto /
  libssl 3.3.2 (Apache License 2.0), pcre2 10.43 (BSD 3-Clause).

## NodeMobile / Node.js — DSH runtime

- **What:** NodeMobile 24.20.0, the iOS build of Node.js that runs the DSH
  engine the sandbox integrates with.
- **License:** MIT License.
- **Source:** <https://nodejs.org> and the NodeMobile distribution used by
  the DSH engine build.

## Flutter — app framework

- **What:** Flutter (stable 3.47.7 in the `ios-stage2-verify` build workflow),
  the framework the dsh-go app is built with.
- **License:** BSD 3-Clause License.
- **Source:** <https://github.com/flutter/flutter>

## Getting the source

For any GPL/AGPL component above, the complete corresponding source for this
exact build is the `feat/ish-linux-sandbox` branch of
<https://github.com/CN00K/dsh-go> (commit recorded in the build), plus the
pinned upstream sources listed above. If you received this IPA without
source access, the branch above is where to get it.
