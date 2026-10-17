#!/usr/bin/env python3
"""Propose a separate lock change; adoption requires tests and device smoke."""
import json
import os
from pathlib import Path
import sys
from dependencies import bump_core, load_lock, write_lock

CANDIDATE = Path('candidate-dependencies.lock.json')


def no_digest(url, size):
    raise SystemExit('Candidate has no usable SHA-256')


def summary(text):
    # Shown on the workflow run page, so a new core isn't missed.
    if path := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(path, 'a') as out:
            out.write(text + '\n')
    print(text)


def main(release_json):
    release = json.loads(Path(release_json).read_text())
    lock = load_lock()
    current, tag = lock['dependencies']['core']['version'], release['tag_name']
    if tag == current:
        summary(f'teapod-core {current} is the latest release.')
        return
    write_lock(bump_core(lock, release, hasher=no_digest), CANDIDATE)
    summary(f'### New teapod-core candidate: {tag} (locked: {current})\n\n'
            f'Adopt with `python3 tools/dependencies.py bump-core --tag {tag}` (or the `core-candidate` '
            'artifact) only after the tests, the core config validator and a device smoke test pass.')


if __name__ == '__main__':
    main(sys.argv[1])
