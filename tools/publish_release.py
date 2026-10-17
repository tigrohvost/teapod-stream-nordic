#!/usr/bin/env python3
"""Verify locally, then resume a draft without replacing any remote asset."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def check_assets(expected, actual):
    for name, digest in actual.items():
        if name not in expected or expected[name] != digest:
            raise ValueError(f'Release content conflict: {name}')


def check_symbols(path):
    required = {'app.android-arm.symbols', 'app.android-arm64.symbols', 'app.android-x64.symbols'}
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None or not required.issubset(archive.namelist()):
            raise ValueError('Missing or corrupt debug symbols')
        if any(archive.getinfo(name).file_size == 0 for name in required):
            raise ValueError('Empty debug symbols')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--prerelease', action='store_true')
    args = parser.parse_args()
    if run('git', 'rev-parse', 'HEAD') != args.source_sha or run('git', 'status', '--porcelain'):
        raise SystemExit('Publication requires the exact clean source commit')
    subprocess.run(['python3', 'tools/verify_release_apks.py', '--source-sha', args.source_sha,
                    '--require-release-signature'], check=True)
    directory = Path('build/app/outputs/flutter-apk')
    manifest = json.loads((directory / 'release-manifest.json').read_text())
    version = manifest['version']
    tag = 'v' + version
    symbols = Path(f'build/app/outputs/teapod-stream-symbols-{version}.zip')
    if not symbols.is_file() or not symbols.stat().st_size:
        raise SystemExit('Debug symbols archive is required')
    check_symbols(symbols)
    files = [directory / a['name'] for a in manifest['apks']]
    files += [directory / 'release-manifest.json', directory / 'SHA256SUMS', symbols]
    expected = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    refs = run('git', 'ls-remote', 'origin', f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}').splitlines()
    ref_shas = {line.split()[1]: line.split()[0] for line in refs}
    remote_sha = ref_shas.get(f'refs/tags/{tag}^{{}}') or ref_shas.get(f'refs/tags/{tag}')
    if remote_sha and remote_sha != args.source_sha:
        raise SystemExit('Release tag points at another source commit')
    repo = run('gh', 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner')
    response = subprocess.run(['gh', 'api', f'repos/{repo}/releases/tags/{tag}'], text=True, capture_output=True)
    if response.returncode:
        if '404' not in response.stderr:
            raise SystemExit('Could not determine remote release state')
        release = None
    else:
        release = json.loads(response.stdout)
    present = {}
    if release:
        with tempfile.TemporaryDirectory(prefix='teapod-release-') as temp:
            for asset in release['assets']:
                name = asset['name']
                if name not in expected:
                    raise SystemExit(f'Unexpected remote asset: {name}')
                run('gh', 'release', 'download', tag, '--pattern', name, '--dir', temp)
                present[name] = hashlib.sha256((Path(temp) / name).read_bytes()).hexdigest()
        check_assets(expected, present)
        if not release['draft']:
            if present != expected:
                raise SystemExit('Published release is incomplete; refusing to change it')
            print('Release already contains the identical verified artifacts')
            return
    else:
        command = ['gh', 'release', 'create', tag, '--draft', '--target', args.source_sha,
                   '--title', f'TeapodStream Nordic {version}', '--generate-notes']
        if args.prerelease:
            command.append('--prerelease')
        run(*command)
    missing = [str(p) for p in files if p.name not in present]
    if missing:
        run('gh', 'release', 'upload', tag, *missing)  # No --clobber, including retries.
    # Verify the complete uploaded set before making the draft visible.
    with tempfile.TemporaryDirectory(prefix='teapod-published-') as temp:
        run('gh', 'release', 'download', tag, '--dir', temp)
        actual = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(temp).iterdir()}
        check_assets(expected, actual)
        if actual != expected:
            raise SystemExit('Incomplete upload; draft retained for retry')
    run('gh', 'release', 'edit', tag, '--draft=false')


if __name__ == '__main__':
    main()
