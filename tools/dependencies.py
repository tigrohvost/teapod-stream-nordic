#!/usr/bin/env python3
"""The shared, hash-checked input gate for local builds and CI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'dependencies.lock.json'
STAGING = '.dependency-staging'  # Same filesystem as the targets, outside bundled assets.
BUNDLED = 'assets/binaries'
BUNDLED_GENERATED = {'manifest.json', 'build-info.json', '.gitkeep'}


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def select_asset(release, expected):
    if not isinstance(release, dict) or not isinstance(release.get('assets'), list):
        raise ValueError('Invalid GitHub release response')
    matches = [a for a in release['assets'] if a.get('name') == expected]
    if len(matches) != 1 or not matches[0].get('browser_download_url', '').startswith('https://'):
        raise ValueError(f'Expected exactly one asset named {expected}')
    return matches[0]


def check_lock(lock):
    if lock['schema'] != 1:
        raise ValueError('Unsupported dependency lock')
    for item in lock['dependencies'].values():
        if not re.fullmatch(r'[0-9a-f]{64}', item['sha256']) or '/latest/' in item['url']:
            raise ValueError('Dependencies must have an explicit version and digest')
    return lock


def load_lock():
    return check_lock(json.loads(LOCK.read_text()))


def write_lock(lock, path=None):
    check_lock(lock)
    Path(path or LOCK).write_text(json.dumps(lock, indent=2) + '\n')


def github_release(repository, tag=None):
    """A release from the GitHub API: the given tag, or the latest one."""
    url = f'https://api.github.com/repos/{repository}/releases/' + (f'tags/{tag}' if tag else 'latest')
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'Teapod-dependency-lock'}
    if token := os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN'):
        headers['Authorization'] = f'Bearer {token}'
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as response:
        return json.load(response)


def download_sha256(url, size):
    """Stream and hash an asset without storing it (when GitHub has no digest)."""
    request = urllib.request.Request(url, headers={'User-Agent': 'Teapod-dependency-lock'})
    sha, total = hashlib.sha256(), 0
    with urllib.request.urlopen(request, timeout=30) as response:
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > size:
                raise ValueError('Oversized dependency')
            sha.update(chunk)
    if total != size:
        raise ValueError('Truncated dependency download')
    return sha.hexdigest()


def apply_release(lock, keys, release, asset_name, hasher=download_sha256):
    """Point lock entries at a release, taking each asset's SHA-256 from GitHub
    when it publishes one and hashing the download otherwise."""
    tag = release['tag_name']
    for key in keys:
        item = lock['dependencies'][key]
        asset = select_asset(release, asset_name(item, tag))
        published = asset.get('digest') or ''
        sha256 = published[7:] if re.fullmatch(r'sha256:[0-9a-f]{64}', published) else \
            hasher(asset['browser_download_url'], asset['size'])
        item.update(version=tag, asset=asset['name'], url=asset['browser_download_url'],
                    size=asset['size'], sha256=sha256)
    return lock


def bump_geodata(lock, release, hasher=download_sha256):
    # Both files always come from one release so they stay a matching pair.
    return apply_release(lock, ['geoip', 'geosite'], release, lambda item, _: item['asset'], hasher)


def bump_core(lock, release, hasher=download_sha256):
    # The fat AAR only, not the per-ABI variants.
    return apply_release(lock, ['core'], release,
                         lambda _, tag: f'teapod-core-{tag.removeprefix("v")}.aar', hasher)


def verify(path, item):
    if not path.is_file() or path.stat().st_size != item['size'] or digest(path) != item['sha256']:
        raise ValueError(f'Dependency content mismatch: {item["asset"]}')


def fetch(item):
    path = ROOT / item['path']
    # Older versions staged downloads next to the target; in assets/binaries a
    # leftover would be bundled into the APK.
    for stale in path.parent.glob(f'{path.name}.*.part'):
        stale.unlink()
    if path.exists():
        try:
            verify(path, item)
            return
        except ValueError:
            # After a lock bump or damage the cached file is replaced by a
            # verified download; it is never used as is.
            print(f'Cached {item["asset"]} differs from dependencies.lock.json; downloading {item["version"]}')
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = ROOT / STAGING
    staging.mkdir(exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', suffix='.part', dir=staging)
    temporary = Path(temporary)
    try:
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'Teapod-dependency-lock'})
        with os.fdopen(fd, 'wb') as out, urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 200:
                raise ValueError(f'HTTP {response.status}')
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > item['size']:
                    raise ValueError('Oversized dependency')
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        verify(temporary, item)
        os.chmod(temporary, 0o644)  # mkstemp creates 0600.
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def check_bundled_directory(lock):
    """Everything in assets/binaries is packed into the APK."""
    directory = ROOT / BUNDLED
    allowed = {Path(item['path']).name for item in lock['dependencies'].values()
               if Path(item['path']).parent == Path(BUNDLED)} | BUNDLED_GENERATED
    extra = sorted(p.name for p in directory.iterdir() if p.name not in allowed) if directory.is_dir() else []
    if extra:
        raise ValueError(f'Unexpected files in {BUNDLED} would be bundled into the APK: {", ".join(extra)}')


def geo_manifest(lock):
    files = {}
    for key in ('geoip', 'geosite'):
        item = lock['dependencies'][key]
        files[item['asset']] = {'source': item['url'], 'version': item['version'],
                               'size': item['size'], 'sha256': item['sha256']}
    path = ROOT / 'assets/binaries/manifest.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({'schema': 1, 'files': files}, indent=2) + '\n')


def validate_toolchain_sources(lock):
    tc = lock['toolchain']
    app = (ROOT / 'android/app/build.gradle.kts').read_text()
    settings = (ROOT / 'android/settings.gradle.kts').read_text()
    wrapper = (ROOT / 'android/gradle/wrapper/gradle-wrapper.properties').read_text()
    expected = [
        (app, f'ndkVersion = "{tc["ndk"]}"'),
        (app, f'version = "{tc["cmake"]}"'),
        (settings, f'id("com.android.application") version "{tc["agp"]}"'),
        (settings, f'id("org.jetbrains.kotlin.android") version "{tc["kotlin"]}"'),
        (wrapper, f'gradle-{tc["gradle"]}-'),
    ]
    if any(value not in content for content, value in expected):
        raise ValueError('Gradle configuration differs from dependencies.lock.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['fetch', 'verify', 'toolchain', 'bump-geodata', 'bump-core'])
    parser.add_argument('--tag', help='release tag for bump-* (default: the latest release)')
    args = parser.parse_args()
    lock = load_lock()
    validate_toolchain_sources(lock)
    if args.action == 'toolchain':
        for key, value in lock['toolchain'].items():
            print(f'TSN_{key.upper()}_VERSION={value}')
        return
    if args.action.startswith('bump-'):
        key = 'geoip' if args.action == 'bump-geodata' else 'core'
        before = lock['dependencies'][key]['version']
        release = github_release(lock['dependencies'][key]['repository'], args.tag)
        (bump_geodata if key == 'geoip' else bump_core)(lock, release)
        write_lock(lock)
        print(f'{args.action}: {before} -> {release["tag_name"]} in dependencies.lock.json')
        print('Next: ./build.sh binaries, run the tests (and a device smoke for a core), then commit the lock.')
        return
    for item in lock['dependencies'].values():
        fetch(item) if args.action == 'fetch' else verify(ROOT / item['path'], item)
        print(f'Verified {item["asset"]} ({item["version"]})')
    check_bundled_directory(lock)
    geo_manifest(lock)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    (ROOT / 'assets/binaries/build-info.json').write_text(json.dumps({
        'source_sha': source, 'dirty': dirty, 'dependencies': lock}, indent=2) + '\n')


if __name__ == '__main__':
    main()
