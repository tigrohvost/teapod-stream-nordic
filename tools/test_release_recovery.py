import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def git(cwd, *args):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / 'remote.git'
        self.repo = self.root / 'work'
        git(self.root, 'init', '--bare', str(self.remote))
        git(self.root, 'clone', str(self.remote), str(self.repo))
        git(self.repo, 'checkout', '-b', 'master')
        git(self.repo, 'config', 'user.name', 'Test')
        git(self.repo, 'config', 'user.email', 'test@example.invalid')
        (self.repo / '.github').mkdir()
        (self.repo / 'pubspec.yaml').write_text('version: 1.6.11+10611\n')
        (self.repo / '.github/teapod-core-version.txt').write_text('v1.7.7\n')
        git(self.repo, 'add', '.')
        git(self.repo, 'commit', '-m', 'baseline')
        git(self.repo, 'tag', 'v1.6.11')
        git(self.repo, 'push', 'origin', 'master', '--tags')
        self.base = git(self.repo, 'rev-parse', 'HEAD')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        gh = self.bin / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if os.environ.get('API_FAIL'): sys.exit(1)
if sys.argv[1:3] == ['release','view']: print('v1.7.7')
elif sys.argv[1:3] == ['release','download']:
    dest = pathlib.Path(sys.argv[sys.argv.index('--dir')+1])
    (dest/'release-manifest.json').write_text(json.dumps({'teapod_core': os.environ.get('PUBLISHED', 'v1.1.15')}))
else: sys.exit(2)
''')
        gh.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin)+':'+os.environ['PATH'], 'GITHUB_OUTPUT': str(self.root/'output')}

    def check(self, **env):
        workflow = (ROOT/'.github/workflows/watch-core.yml').read_text()
        block = workflow.split('        run: |\n', 1)[1].split('\n  #', 1)[0]
        script = '\n'.join(line[10:] if line.startswith('          ') else line for line in block.splitlines())
        return subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script], cwd=self.repo, env={**self.env, **env}, capture_output=True, text=True)

    def rollback(self, candidate):
        return subprocess.run(['bash', str(ROOT/'tools/rollback_release.sh')], cwd=self.repo, env={**self.env,'CANDIDATE':candidate,'VERSION':'1.6.12'}, capture_output=True, text=True)

    def test_same_pinned_but_unpublished_core_retries_without_tag(self):
        r = self.check()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.repo/'pubspec.yaml').read_text(), 'version: 1.6.12+10612\n')
        self.assertEqual(git(self.repo,'tag','--list'), 'v1.6.11')
        self.assertEqual(git(self.repo,'rev-parse','v1.6.11'), self.base)
        self.assertIn('bumped=true', (self.root/'output').read_text())

    def test_published_core_skips(self):
        r = self.check(PUBLISHED='v1.7.7')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(git(self.repo,'rev-parse','HEAD'), self.base)
        self.assertIn('bumped=false', (self.root/'output').read_text())

    def test_api_error_does_not_bump(self):
        self.assertNotEqual(self.check(API_FAIL='1').returncode, 0)
        self.assertEqual(git(self.repo,'rev-parse','HEAD'), self.base)

    def test_existing_next_tag_never_moved(self):
        git(self.repo,'tag','v1.6.12')
        git(self.repo,'push','origin','v1.6.12')
        self.assertNotEqual(self.check().returncode, 0)
        self.assertEqual(git(self.repo,'ls-remote','origin','refs/heads/master').split()[0], self.base)
        self.assertEqual(git(self.repo,'ls-remote','origin','refs/tags/v1.6.12').split()[0], self.base)

    def test_unpublished_tip_reverted(self):
        self.assertEqual(self.check().returncode, 0)
        candidate = git(self.repo,'rev-parse','HEAD')
        r = self.rollback(candidate)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.repo/'pubspec.yaml').read_text(), 'version: 1.6.11+10611\n')
        self.assertEqual(git(self.repo,'rev-parse','v1.6.11'), self.base)
        # Retry after rollback again chooses 1.6.12 and no tag collision.
        self.assertEqual(self.check().returncode, 0)

    def test_tag_present_preserves_candidate(self):
        self.assertEqual(self.check().returncode, 0)
        candidate = git(self.repo,'rev-parse','HEAD')
        git(self.repo,'tag','v1.6.12')
        git(self.repo,'push','origin','v1.6.12')
        r = self.rollback(candidate)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(git(self.repo,'rev-parse','HEAD'), candidate)

    def test_tag_lookup_failure_stops_check_and_rollback(self):
        self.assertEqual(self.check().returncode, 0)
        candidate = git(self.repo, 'rev-parse', 'HEAD')
        wrapper = self.bin / 'git'
        import shutil
        real_git = shutil.which('git')
        wrapper.write_text(f'#!/bin/sh\nif [ "$1" = ls-remote ]; then exit 1; fi\nexec "{real_git}" "$@"\n')
        wrapper.chmod(0o755)
        self.assertNotEqual(self.rollback(candidate).returncode, 0)
        self.assertEqual(git(self.repo, 'rev-parse', 'HEAD'), candidate)
        self.assertNotEqual(self.check().returncode, 0)
        self.assertEqual(git(self.repo, 'ls-remote', 'origin', 'refs/heads/master').split()[0], candidate)

    def test_changed_master_preserved(self):
        self.assertEqual(self.check().returncode, 0)
        candidate = git(self.repo,'rev-parse','HEAD')
        (self.repo/'other.txt').write_text('another change')
        git(self.repo,'add','.')
        git(self.repo,'commit','-m','another change')
        git(self.repo,'push','origin','master')
        tip = git(self.repo,'rev-parse','HEAD')
        r = self.rollback(candidate)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(git(self.repo,'rev-parse','HEAD'), tip)

if __name__ == '__main__': unittest.main()
