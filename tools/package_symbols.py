#!/usr/bin/env python3
"""Pack split-debug-info symbols into a byte-reproducible zip.

`zip -r` stores file timestamps, so every rebuild of identical symbols got a
different archive hash and a re-run publish could never match the release.
"""
import argparse
from pathlib import Path
import zipfile

EPOCH = (1980, 1, 1, 0, 0, 0)  # The earliest timestamp zip can store.


def pack(source, target):
    files = sorted(p for p in Path(source).rglob('*') if p.is_file())
    if not files:
        raise SystemExit(f'No symbols in {source}')
    with zipfile.ZipFile(target, 'w') as archive:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), date_time=EPOCH)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes(), compresslevel=9)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    args = parser.parse_args()
    pack(args.source, args.target)


if __name__ == '__main__':
    main()
