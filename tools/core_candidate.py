#!/usr/bin/env python3
"""Propose a separate lock change; adoption requires tests and device smoke."""
import json
from pathlib import Path
import sys
from dependencies import load_lock, select_asset

release = json.loads(Path(sys.argv[1]).read_text())
lock = load_lock()
tag = release['tag_name']
if tag != lock['dependencies']['core']['version']:
    asset = select_asset(release, f'teapod-core-{tag.removeprefix("v")}.aar')
    digest = asset.get('digest', '')
    if not digest.startswith('sha256:') or len(digest) != 71:
        raise SystemExit('Candidate has no usable SHA-256')
    lock['dependencies']['core'].update(version=tag, asset=asset['name'], url=asset['browser_download_url'],
                                        size=asset['size'], sha256=digest[7:])
    Path('candidate-dependencies.lock.json').write_text(json.dumps(lock, indent=2) + '\n')
    print('Candidate recorded. Validate the isolated core validator, lifecycle, and device smoke before adoption.')
