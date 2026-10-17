import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import dependencies
import publish_release


class Response(io.BytesIO):
    status = 200


def files(root):
    return sorted(p for p in Path(root).rglob('*') if p.is_file())


class ReleaseInputTests(unittest.TestCase):
    def test_symbols_require_every_architecture_and_nonempty_content(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'symbols.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('app.android-arm.symbols', b'test')
            with self.assertRaises(ValueError): publish_release.check_symbols(path)
            with zipfile.ZipFile(path, 'w') as archive:
                for abi in ['arm', 'arm64', 'x64']:
                    archive.writestr(f'app.android-{abi}.symbols', b'test')
            publish_release.check_symbols(path)

    def test_exact_asset_from_multiline_github_json(self):
        release = json.loads('''{
          "assets": [
            {"name": "core-arm64.aar", "browser_download_url": "https://example.test/arm64"},
            {"name": "core.aar", "browser_download_url": "https://example.test/core"}
          ]
        }''')
        self.assertEqual(dependencies.select_asset(release, 'core.aar')['browser_download_url'], 'https://example.test/core')
        for invalid in [[], {'assets': []}, {'assets': release['assets'] * 2}, {'assets': [{'name': 'core.aar', 'browser_download_url': 'http://untrusted'}]}]:
            with self.assertRaises(ValueError): dependencies.select_asset(invalid, 'core.aar')

    GOOD = {'path': 'libs/core', 'asset': 'core.aar', 'version': 'v2', 'size': 4,
            'sha256': hashlib.sha256(b'good').hexdigest(), 'url': 'https://example.test/core'}

    def test_stale_cached_dependency_is_replaced_by_a_verified_download(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'libs').mkdir()
            (root / 'libs/core').write_bytes(b'from an older lock')
            with patch.object(dependencies, 'ROOT', root), patch.object(dependencies.urllib.request, 'urlopen', return_value=Response(b'good')):
                dependencies.fetch(self.GOOD)
            self.assertEqual((root / 'libs/core').read_bytes(), b'good')
            self.assertEqual((root / 'libs/core').stat().st_mode & 0o777, 0o644)
            self.assertEqual(files(root), [root / 'libs/core'])

    def test_bad_download_never_replaces_the_cached_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'libs').mkdir()
            (root / 'libs/core').write_bytes(b'tampered')
            with patch.object(dependencies, 'ROOT', root), patch.object(dependencies.urllib.request, 'urlopen', return_value=Response(b'evil')):
                with self.assertRaises(ValueError): dependencies.fetch(self.GOOD)
            self.assertEqual((root / 'libs/core').read_bytes(), b'tampered')
            self.assertEqual(files(root), [root / 'libs/core'])

    def test_failed_download_leaves_no_committed_or_partial_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(dependencies, 'ROOT', root), patch.object(dependencies.urllib.request, 'urlopen', side_effect=TimeoutError):
                with self.assertRaises(TimeoutError): dependencies.fetch(self.GOOD)
            self.assertEqual(files(root), [])

    def test_leftover_part_files_are_removed_and_unknown_bundled_files_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binaries = root / 'assets/binaries'
            binaries.mkdir(parents=True)
            (binaries / 'geoip.dat').write_bytes(b'good')
            (binaries / 'geoip.dat.x1y2.part').write_bytes(b'half')  # interrupted older run
            item = dict(self.GOOD, path='assets/binaries/geoip.dat', asset='geoip.dat')
            lock = {'dependencies': {'geoip': item}}
            with patch.object(dependencies, 'ROOT', root):
                dependencies.fetch(item)
                dependencies.check_bundled_directory(lock)
                (binaries / 'notes.txt').write_text('would ship in the APK')
                with self.assertRaises(ValueError): dependencies.check_bundled_directory(lock)
            self.assertFalse((binaries / 'geoip.dat.x1y2.part').exists())

    def test_locked_gradle_toolchain_is_consistent(self):
        lock = dependencies.load_lock()
        dependencies.validate_toolchain_sources(lock)
        lock['toolchain']['ndk'] = '0.0.0'
        with self.assertRaises(ValueError): dependencies.validate_toolchain_sources(lock)

    def test_resume_allows_identical_subset_but_never_clobbers(self):
        expected = {'arm64.apk': 'a', 'x86.apk': 'b'}
        publish_release.check_assets(expected, {'arm64.apk': 'a'})
        publish_release.check_assets(expected, expected)
        with self.assertRaises(ValueError): publish_release.check_assets(expected, {'arm64.apk': 'changed'})
        with self.assertRaises(ValueError): publish_release.check_assets(expected, {'unreviewed.apk': 'a'})

    def test_publication_rejects_dirty_or_wrong_sha_before_external_commands(self):
        for head, dirty in [('b' * 40, ''), ('a' * 40, ' M source.dart')]:
            calls = []
            def run(*args):
                calls.append(args)
                return head if args[1] == 'rev-parse' else dirty
            with patch.object(sys, 'argv', ['publish_release.py', '--source-sha', 'a' * 40]), patch.object(publish_release, 'run', run), patch.object(publish_release.subprocess, 'run') as writes:
                with self.assertRaises(SystemExit): publish_release.main()
                writes.assert_not_called()
                self.assertTrue(all(c[0] == 'git' for c in calls))

if __name__ == '__main__': unittest.main()
