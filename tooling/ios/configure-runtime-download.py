#!/usr/bin/env python3
"""Export the iOS JS payload and pin its download identity into the app build."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from urllib.parse import urlsplit
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def configure(archive, url, output, export_dir, allow_local_debug=False):
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if url.endswith('/'):
        url += f'runtime-{digest}.zip'
    parsed = urlsplit(url)
    name = Path(parsed.path).name
    if not name or not name.endswith('.zip'):
        raise ValueError('The download URL must end in .zip or /.')
    local_debug = allow_local_debug and parsed.scheme == 'http' and parsed.hostname in (
        'localhost', '127.0.0.1', '::1')
    if (parsed.scheme != 'https' and not local_debug) or not parsed.hostname or parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise ValueError('Use an HTTPS URL; --allow-local-debug permits HTTP loopback for Simulator testing only.')
    with zipfile.ZipFile(archive) as package:
        manifest = json.loads(package.read('manifest.json'))
    if manifest['schema'] != 1 or manifest['nodeVersion'] != '24.22.1':
        raise ValueError('The prepared runtime is incompatible; rerun prepare-engine.sh.')
    descriptor = {
        'schema': 1, 'url': url, 'sha256': digest, 'bytes': archive.stat().st_size,
        **{key: manifest[key] for key in ('runtimeVersion', 'dshVersion', 'nodeVersion')},
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(descriptor, indent=2) + '\n')
    if export_dir:
        export_dir.mkdir(parents=True, exist_ok=True)
        # Use the exact URL basename, so a static server can serve this directory.
        shutil.copyfile(archive, export_dir / name)
    return descriptor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True, help='HTTPS ZIP URL, or a directory URL ending with /')
    parser.add_argument('--archive', type=Path, default=ROOT / 'app/ios/Engine/runtime.zip')
    parser.add_argument('--out', type=Path, default=ROOT / 'app/ios/runtime-download.json')
    parser.add_argument('--export-dir', type=Path, default=ROOT / 'dist/ios-runtime')
    parser.add_argument('--allow-local-debug', action='store_true')
    args = parser.parse_args()
    descriptor = configure(args.archive, args.url, args.out, args.export_dir, args.allow_local_debug)
    print(json.dumps({'configuration': str(args.out), 'export': str(args.export_dir), **descriptor}, indent=2))


if __name__ == '__main__':
    main()
