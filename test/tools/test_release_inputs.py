import hashlib
import importlib.util
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

    def test_corrupt_cached_dependency_fails_without_network_or_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'core').write_bytes(b'tampered')
            expected = {'path': 'core', 'asset': 'core.aar', 'size': 4, 'sha256': hashlib.sha256(b'good').hexdigest()}
            with patch.object(dependencies, 'ROOT', root), patch.object(dependencies.urllib.request, 'urlopen') as download:
                with self.assertRaises(ValueError): dependencies.fetch(expected)
                download.assert_not_called()
                self.assertEqual((root / 'core').read_bytes(), b'tampered')

    def test_failed_download_leaves_no_committed_or_partial_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            item = {'path': 'core', 'asset': 'core.aar', 'size': 4, 'sha256': 'a' * 64, 'url': 'https://example.test/core'}
            with patch.object(dependencies, 'ROOT', root), patch.object(dependencies.urllib.request, 'urlopen', side_effect=TimeoutError):
                with self.assertRaises(TimeoutError): dependencies.fetch(item)
                self.assertEqual(list(root.iterdir()), [])

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
