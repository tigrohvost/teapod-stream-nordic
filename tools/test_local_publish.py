"""Local publishing guard tests: all git/gh/signature commands are mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LocalPublishTests(unittest.TestCase):
    def attempt(self, scenario):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            scripts = {
                'git': '''#!/bin/bash
case "$1" in
  status) [[ "$SCENARIO" == dirty ]] && echo ' M file'; exit 0;;
  ls-remote)
    [[ "$SCENARIO" == lookup_error ]] && exit 1
    [[ "$SCENARIO" == mismatch ]] && echo 'bbbb refs/tags/v1.6.11'
    exit 0;;
  fetch) exit 0;;
  rev-parse)
    if [[ "$2" == HEAD ]]; then printf '%040d\\n' 1; else printf '%040d\\n' 2; fi;;
  *) exit 9;;
esac
''',
                'python3': '#!/bin/bash\nexit 0\n',
                'gh': '''#!/bin/bash
if [[ "$1" == auth ]]; then exit 0; fi
if [[ "$2" == view ]]; then [[ "$SCENARIO" == existing ]]; exit $?; fi
printf '%s\\n' "$*" >> "$CALLS"
''',
            }
            for name, text in scripts.items():
                file = bin_dir / name
                file.write_text(text)
                file.chmod(0o755)
            directory = root / 'build/app/outputs/flutter-apk'
            directory.mkdir(parents=True)
            for abi in ('arm64-v8a', 'x86_64'):
                (directory / f'teapod-stream-{abi}.apk').write_bytes(b'fake')
            text = (ROOT / 'build.sh').read_text()
            function = text[text.index('push_release() {'):text.index('\ncase "${1:-help}"')]
            script = '''set -euo pipefail
VERSION=1.6.11
ALL_ABIS=(arm64-v8a x86_64)
log() { :; }
ok() { :; }
err() { echo "$*" >&2; exit 1; }
''' + function + '\npush_release false\n'
            calls = root / 'calls'
            result = subprocess.run(['bash', '-c', script], cwd=root,
                                    env={**os.environ, 'PATH': str(bin_dir)+':'+os.environ['PATH'],
                                         'SCENARIO': scenario, 'CALLS': str(calls)},
                                    text=True, capture_output=True)
            return result, calls.read_text() if calls.exists() else ''

    def test_mismatched_tag_does_not_publish(self):
        result, calls = self.attempt('mismatch')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_failed_tag_lookup_does_not_publish(self):
        result, calls = self.attempt('lookup_error')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_existing_release_does_not_overwrite(self):
        result, calls = self.attempt('existing')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_dirty_source_does_not_publish(self):
        result, calls = self.attempt('dirty')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_new_release_targets_exact_source(self):
        result, calls = self.attempt('new')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--target ' + '0' * 39 + '1', calls)
        self.assertNotIn('--clobber', calls)
        self.assertNotIn('armeabi-v7a', calls)


if __name__ == '__main__':
    unittest.main()
