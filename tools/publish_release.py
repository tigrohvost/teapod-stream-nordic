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


def api_json(*args):
    """gh api output as JSON; stderr stays separate so warnings can't corrupt it."""
    result = subprocess.run(['gh', 'api', *args], text=True, capture_output=True)
    if result.returncode:
        raise SystemExit(f'GitHub API request failed: {result.stderr.strip()}')
    return json.loads(result.stdout)


def find_release(repo, tag):
    """The release for tag, draft or published, or None.

    GET /releases/tags/{tag} never returns drafts, so a retried run would not
    see its own half-uploaded draft and would create a second one.
    """
    pages = api_json('--paginate', '--slurp', f'repos/{repo}/releases?per_page=100')
    matches = [r for page in pages for r in page if r.get('tag_name') == tag]
    if len(matches) > 1:
        raise SystemExit(f'Several releases use {tag}; delete the stale drafts before retrying')
    return matches[0] if matches else None


def check_draft_source(release, source_sha):
    # A draft has no git tag yet, so the ls-remote check can't cover it.
    if release['draft'] and release.get('target_commitish') != source_sha:
        raise SystemExit(f'Draft {release["tag_name"]} targets {release.get("target_commitish")}, '
                         f'not {source_sha}; delete it or publish from that commit')


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
                    '--require-release-signature', '--require-clean-source'], check=True)
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
    release = find_release(repo, tag)
    present = {}
    if release:
        check_draft_source(release, args.source_sha)
        with tempfile.TemporaryDirectory(prefix='teapod-release-') as temp:
            for asset in release['assets']:
                name = asset['name']
                if name not in expected:
                    raise SystemExit(f'Unexpected remote asset: {name}')
                if release['draft'] and asset.get('state', 'uploaded') != 'uploaded':
                    # An interrupted upload leaves a stub that blocks re-uploading the name.
                    run('gh', 'release', 'delete-asset', tag, name, '--yes')
                    continue
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
