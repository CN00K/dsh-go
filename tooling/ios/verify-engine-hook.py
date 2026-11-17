"""Verify the iSH engine hook inside a prepared Engine runtime.zip.

Usage: python3 tooling/ios/verify-engine-hook.py <path/to/runtime.zip>

Checks, all via python zipfile (no unzip binary involved):
  1. the five hook entries are present in the zip (files/ prefix),
  2. files/runtime/ohos/preload.mjs installs the iSH bridge.

Exit 0 when everything is present, 1 listing each missing entry.

Why python zipfile (build 39): `unzip -l runtime.zip <entry> | grep -q
<entry>` reported ish-bridge.mjs MISSING on the Codemagic builder,
although the byte-identical zip passes the same command locally and the
prepare-engine step's python zipfile listing (same file, same machine)
shows the entry present with matching size/sha256/entry count
(46115167 / c9db2f4d... / 12448 / ios-e66ee41c87a4e84fe0d1e526).
The unzip binary is not trustworthy for the verdict here, so the verdict
uses the same mechanism the prepare-engine diagnostics already use.
"""

import json
import sys
import zipfile

REQUIRED = [
    "files/runtime/ios/process/ish-bridge.mjs",
    "files/runtime/ios/process/browser-bridge.mjs",
    "files/runtime/ios/process/ish-adapter.mjs",
    "files/node_modules/@dsh-go/dsh-tool-browser/lib/index.js",
    "files/node_modules/@dsh-go/dsh-tool-browser/package.json",
]

PRELOAD = "files/runtime/ohos/preload.mjs"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path/to/runtime.zip>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as exc:
        print(f"cannot open runtime.zip: {exc}")
        return 1
    names = set(z.namelist())
    print("zip entries:", len(names))
    print("hook entries:", sorted(
        n for n in names
        if "ish-bridge" in n or "browser-bridge" in n
        or "ish-adapter" in n or "dsh-tool-browser" in n))
    try:
        print("runtimeVersion:",
              json.loads(z.read("manifest.json"))["runtimeVersion"])
    except (KeyError, ValueError) as exc:
        print(f"cannot read runtimeVersion: {exc}")
        return 1
    missing = [e for e in REQUIRED if e not in names]
    if missing:
        for e in missing:
            print(f"MISSING in runtime.zip: {e}")
        return 1
    try:
        preload = z.read(PRELOAD).decode("utf-8", errors="replace")
    except KeyError:
        print(f"MISSING in runtime.zip: {PRELOAD}")
        return 1
    if "installIshBridge" not in preload:
        print("preload.mjs does not install the iSH bridge")
        return 1
    print("Engine hook verified: bridges + adapter + tool-browser in runtime.zip")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
