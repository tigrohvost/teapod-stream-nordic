import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import core_candidate
import dependencies

TAG = '202611010000'
BASE = f'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/{TAG}'


def asset(name, size, digest=None):
    entry = {'name': name, 'size': size, 'browser_download_url': f'{BASE}/{name}'}
    if digest:
        entry['digest'] = digest
    return entry


class Response(io.BytesIO):
    status = 200


class LockUpdateTests(unittest.TestCase):
    def setUp(self):
        self.lock = dependencies.load_lock()
        self.original = copy.deepcopy(self.lock)

    def test_bump_geodata_rewrites_both_files_from_one_release(self):
        release = {'tag_name': TAG, 'assets': [
            asset('geoip.dat', 100, 'sha256:' + '1' * 64),
            asset('geoip.dat.sha256sum', 80),
            asset('geosite.dat', 200),  # No published digest: hashed from the download.
        ]}
        hashed = []
        def hasher(url, size):
            hashed.append(url)
            return '2' * 64
        dependencies.bump_geodata(self.lock, release, hasher)
        geoip, geosite = self.lock['dependencies']['geoip'], self.lock['dependencies']['geosite']
        self.assertEqual((geoip['version'], geoip['size'], geoip['sha256'], geoip['url']),
                         (TAG, 100, '1' * 64, f'{BASE}/geoip.dat'))
        self.assertEqual((geosite['version'], geosite['size'], geosite['sha256']), (TAG, 200, '2' * 64))
        self.assertEqual(hashed, [f'{BASE}/geosite.dat'])
        self.assertEqual(self.lock['dependencies']['core'], self.original['dependencies']['core'])
        self.assertEqual(geoip['path'], self.original['dependencies']['geoip']['path'])
        with tempfile.TemporaryDirectory() as temp:
            dependencies.write_lock(self.lock, Path(temp) / 'lock.json')
            self.assertEqual(json.loads((Path(temp) / 'lock.json').read_text()), self.lock)

    def test_release_without_both_files_is_rejected(self):
        release = {'tag_name': TAG, 'assets': [asset('geoip.dat', 100, 'sha256:' + '1' * 64)]}
        with self.assertRaises(ValueError):
            dependencies.bump_geodata(self.lock, release, lambda *_: '2' * 64)

    def test_written_lock_must_stay_pinned(self):
        self.lock['dependencies']['geoip']['url'] = 'https://github.com/x/y/releases/latest/download/geoip.dat'
        with tempfile.TemporaryDirectory() as temp, self.assertRaises(ValueError):
            dependencies.write_lock(self.lock, Path(temp) / 'lock.json')

    def test_streamed_hash_rejects_truncated_and_oversized_downloads(self):
        with patch.object(dependencies.urllib.request, 'urlopen', return_value=Response(b'abcd')):
            self.assertEqual(dependencies.download_sha256('https://example.test/a', 4),
                             '88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589')
        for size in (3, 5):
            with patch.object(dependencies.urllib.request, 'urlopen', return_value=Response(b'abcd')):
                with self.assertRaises(ValueError):
                    dependencies.download_sha256('https://example.test/a', size)


class CoreCandidateTests(unittest.TestCase):
    def run_candidate(self, release):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'release.json').write_text(json.dumps(release))
            cwd = os.getcwd()
            os.chdir(root)
            try:
                with patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(root / 'summary.md')}):
                    core_candidate.main(root / 'release.json')
            finally:
                os.chdir(cwd)
            candidate = root / 'candidate-dependencies.lock.json'
            return (json.loads(candidate.read_text()) if candidate.exists() else None,
                    (root / 'summary.md').read_text())

    def test_new_core_becomes_a_visible_candidate(self):
        name = 'teapod-core-1.1.16.aar'
        release = {'tag_name': 'v1.1.16', 'assets': [
            {'name': name, 'size': 5, 'digest': 'sha256:' + '3' * 64,
             'browser_download_url': f'https://github.com/Wendor/teapod-core/releases/download/v1.1.16/{name}'},
            {'name': 'teapod-core-arm64-v8a-1.1.16.aar', 'size': 4, 'digest': 'sha256:' + '4' * 64,
             'browser_download_url': 'https://github.com/Wendor/teapod-core/releases/download/v1.1.16/arm64.aar'},
        ]}
        candidate, summary = self.run_candidate(release)
        core = candidate['dependencies']['core']
        self.assertEqual((core['version'], core['asset'], core['sha256']), ('v1.1.16', name, '3' * 64))
        self.assertIn('v1.1.16', summary)

    def test_current_core_writes_no_candidate(self):
        current = dependencies.load_lock()['dependencies']['core']['version']
        candidate, summary = self.run_candidate({'tag_name': current, 'assets': []})
        self.assertIsNone(candidate)
        self.assertIn('latest', summary)

    def test_candidate_without_published_digest_is_refused(self):
        name = 'teapod-core-1.1.16.aar'
        release = {'tag_name': 'v1.1.16', 'assets': [
            {'name': name, 'size': 5, 'browser_download_url': f'https://example.test/{name}'}]}
        with self.assertRaises(SystemExit):
            self.run_candidate(release)


if __name__ == '__main__':
    unittest.main()
