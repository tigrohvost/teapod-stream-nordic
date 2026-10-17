import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import publish_release

SHA = 'a' * 40
TAG = 'v1.2.3'


class PublishResumeTests(unittest.TestCase):
    """main() against a fake gh/git: the remote release lives in self.remote."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        apk_dir = root / 'build/app/outputs/flutter-apk'
        apk_dir.mkdir(parents=True)
        apks = []
        for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
            (apk_dir / f'teapod-stream-{abi}.apk').write_bytes(abi.encode())
            apks.append({'name': f'teapod-stream-{abi}.apk'})
        (apk_dir / 'release-manifest.json').write_text(json.dumps({'version': '1.2.3', 'apks': apks}))
        (apk_dir / 'SHA256SUMS').write_text('sums')
        with zipfile.ZipFile(root / 'build/app/outputs/teapod-stream-symbols-1.2.3.zip', 'w') as archive:
            for abi in ('arm', 'arm64', 'x64'):
                archive.writestr(f'app.android-{abi}.symbols', b'symbols')
        self.local = {p.name: p.read_bytes() for p in root.rglob('*') if p.is_file()}
        cwd = os.getcwd()
        os.chdir(root)
        self.addCleanup(os.chdir, cwd)
        self.remote = {}
        self.calls = []

    def fake_run(self, *args):
        self.calls.append(args)
        if args[:2] == ('git', 'rev-parse'):
            return SHA
        if args[:2] in (('git', 'status'), ('git', 'ls-remote')):
            return ''
        if args[:3] == ('gh', 'repo', 'view'):
            return 'owner/repo'
        if args[:3] == ('gh', 'release', 'download'):
            directory = Path(args[args.index('--dir') + 1])
            names = [args[args.index('--pattern') + 1]] if '--pattern' in args else list(self.remote)
            for name in names:
                (directory / name).write_bytes(self.remote[name])
            return ''
        if args[:3] == ('gh', 'release', 'upload'):
            for path in args[4:]:
                self.assertNotIn(Path(path).name, self.remote)  # never clobbers
                self.remote[Path(path).name] = Path(path).read_bytes()
            return ''
        if args[:3] == ('gh', 'release', 'delete-asset'):
            del self.remote[args[4]]
            return ''
        if args[:3] in (('gh', 'release', 'create'), ('gh', 'release', 'edit')):
            return ''
        raise AssertionError(f'unexpected command {args}')

    def publish(self, pages):
        with patch.object(sys, 'argv', ['publish_release.py', '--source-sha', SHA]), \
                patch.object(publish_release, 'run', self.fake_run), \
                patch.object(publish_release, 'api_json', return_value=pages), \
                patch.object(publish_release.subprocess, 'run'):
            publish_release.main()

    def commands(self, verb):
        return [c for c in self.calls if c[:3] == ('gh', 'release', verb)]

    def draft(self, assets, target=SHA):
        return {'tag_name': TAG, 'draft': True, 'target_commitish': target,
                'assets': [{'name': n, 'state': s} for n, s in assets]}

    def test_retry_resumes_the_existing_draft_instead_of_creating_another(self):
        self.remote['teapod-stream-arm64-v8a.apk'] = self.local['teapod-stream-arm64-v8a.apk']
        other = {'tag_name': 'v1.2.2', 'draft': False, 'assets': []}
        # The draft is on the second page of the paginated listing.
        self.publish([[other], [self.draft([('teapod-stream-arm64-v8a.apk', 'uploaded')])]])
        self.assertEqual(self.commands('create'), [])
        uploaded = [Path(p).name for c in self.commands('upload') for p in c[4:]]
        self.assertNotIn('teapod-stream-arm64-v8a.apk', uploaded)
        self.assertEqual(self.remote, self.local)
        self.assertEqual(self.commands('edit'), [('gh', 'release', 'edit', TAG, '--draft=false')])

    def test_new_release_is_created_as_a_draft_for_the_exact_commit(self):
        self.publish([[]])
        create, = self.commands('create')
        self.assertIn('--draft', create)
        self.assertEqual(create[create.index('--target') + 1], SHA)
        self.assertEqual(self.remote, self.local)

    def test_draft_for_another_commit_is_refused_before_any_change(self):
        with self.assertRaises(SystemExit):
            self.publish([[self.draft([], target='b' * 40)]])
        for verb in ('create', 'upload', 'edit', 'delete-asset'):
            self.assertEqual(self.commands(verb), [])

    def test_interrupted_upload_stub_is_replaced(self):
        self.remote['SHA256SUMS'] = b'partial'
        self.publish([[self.draft([('SHA256SUMS', 'starter')])]])
        self.assertEqual(self.commands('delete-asset'), [('gh', 'release', 'delete-asset', TAG, 'SHA256SUMS', '--yes')])
        self.assertEqual(self.remote, self.local)

    def test_duplicate_releases_for_one_tag_are_refused(self):
        with self.assertRaises(SystemExit):
            self.publish([[self.draft([])], [self.draft([])]])
        self.assertEqual(self.commands('upload'), [])

    def test_published_release_with_identical_assets_is_left_alone(self):
        self.remote = dict(self.local)
        release = {'tag_name': TAG, 'draft': False, 'target_commitish': 'master',
                   'assets': [{'name': n, 'state': 'uploaded'} for n in self.local]}
        self.publish([[release]])
        for verb in ('create', 'upload', 'edit'):
            self.assertEqual(self.commands(verb), [])


if __name__ == '__main__':
    unittest.main()
