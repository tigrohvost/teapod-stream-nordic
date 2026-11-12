"""Synthetic archives exercise validation without Android SDK/signing keys."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import verify_release_apks as verify


class ReleaseValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def archive(self, name, contents):
        path = self.root / name
        with zipfile.ZipFile(path, 'w') as archive:
            for member, data in contents.items():
                archive.writestr(member, data)
        return path

    def aar_contents(self):
        return {f'jni/{abi}/libgojni.so': b'core' for abi in verify.ABI_OFFSETS}

    def apk_contents(self, abi):
        contents = {f'lib/{abi}/{lib}.so': b'library'
                    for lib in ('libapp', 'libflutter', 'libgojni')}
        contents.update({f'assets/flutter_assets/assets/{name}': b'asset'
                         for name in ('binaries/geoip.dat', 'binaries/geosite.dat',
                                      'brave_opossum.png')})
        contents.update({f'assets/flutter_assets/assets/fonts/{family}-{weight}.ttf': b'font'
                         for family in ('InterTight', 'JetBrainsMono')
                         for weight in ('Regular', 'Medium', 'SemiBold', 'Bold')})
        return contents

    def test_64_bit_aar(self):
        verify.validate_aar(self.archive('core.aar', self.aar_contents()))

    def test_missing_or_empty_core_fails(self):
        for abi in verify.ABI_OFFSETS:
            for empty in (False, True):
                contents = self.aar_contents()
                key = f'jni/{abi}/libgojni.so'
                if empty:
                    contents[key] = b''
                else:
                    del contents[key]
                with self.subTest(abi=abi, empty=empty), self.assertRaises(SystemExit):
                    verify.validate_aar(self.archive('core.aar', contents))

    def test_expected_apk_set(self):
        for abi in verify.ABI_OFFSETS:
            (self.root / f'teapod-stream-{abi}.apk').touch()
        verify.validate_apk_set(self.root)

    def test_missing_apk_fails(self):
        with self.assertRaises(SystemExit):
            verify.validate_apk_set(self.root)

    def test_stale_or_universal_apk_fails(self):
        for abi in verify.ABI_OFFSETS:
            (self.root / f'teapod-stream-{abi}.apk').touch()
        for extra in ('armeabi-v7a', 'universal', 'x86'):
            path = self.root / f'teapod-stream-{extra}.apk'
            path.touch()
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                verify.validate_apk_set(self.root)
            path.unlink()

    def test_runtime_assets(self):
        for abi in verify.ABI_OFFSETS:
            verify.validate_runtime_assets(self.archive('app.apk', self.apk_contents(abi)), abi)

    def test_missing_or_empty_asset_fails(self):
        for key in self.apk_contents('arm64-v8a'):
            for empty in (False, True):
                contents = self.apk_contents('arm64-v8a')
                if empty:
                    contents[key] = b''
                else:
                    del contents[key]
                with self.subTest(key=key, empty=empty), self.assertRaises(SystemExit):
                    verify.validate_runtime_assets(self.archive('app.apk', contents), 'arm64-v8a')

    def test_mixed_architecture_fails(self):
        contents = self.apk_contents('arm64-v8a')
        contents['lib/armeabi-v7a/libgojni.so'] = b'old'
        with self.assertRaises(SystemExit):
            verify.validate_runtime_assets(self.archive('app.apk', contents), 'arm64-v8a')

    def prepare_main(self):
        self.archive('core.aar', self.aar_contents())
        for abi in verify.ABI_OFFSETS:
            self.archive(f'teapod-stream-{abi}.apk', self.apk_contents(abi))
        (self.root / 'pubspec.yaml').write_text('version: 1.6.12+10612\n')
        (self.root / '.github').mkdir()
        (self.root / '.github/teapod-core-version.txt').write_text('v1.7.7\n')
        build_tools = self.root / 'build-tools/37.0.0'
        build_tools.mkdir(parents=True)
        for tool in ('apksigner', 'aapt'):
            (build_tools / tool).touch()

    def invoke_main(self, cert=None, code_delta=0):
        def run(*args):
            if Path(args[0]).name == 'apksigner':
                return f'Signer #1 certificate SHA-256 digest: {cert or verify.RELEASE_CERT}'
            abi = Path(args[-1]).name.removeprefix('teapod-stream-').removesuffix('.apk')
            code = 10612 + verify.ABI_OFFSETS[abi] + code_delta
            return f"package: name='com.teapodstream.teapodstream' versionCode='{code}' versionName='1.6.12'"
        with contextlib.chdir(self.root), patch.dict(os.environ, {'ANDROID_HOME': str(self.root)}), \
             patch('sys.argv', ['verify', '--apk-dir', str(self.root), '--aar', 'core.aar',
                               '--source-sha', 'a' * 40, '--require-release-signature']), \
             patch.object(verify, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            verify.main()

    def test_manifest_has_only_64_bit_apks_and_existing_offsets(self):
        self.prepare_main()
        self.invoke_main()
        manifest = json.loads((self.root / 'release-manifest.json').read_text())
        self.assertEqual([a['abi'] for a in manifest['apks']], ['arm64-v8a', 'x86_64'])
        self.assertEqual([a['version_code'] for a in manifest['apks']], [12612, 14612])
        self.assertEqual(manifest['signer_sha256'], verify.RELEASE_CERT)
        self.assertEqual(len((self.root / 'SHA256SUMS').read_text().splitlines()), 2)

    def test_wrong_signature_still_fails(self):
        self.prepare_main()
        with self.assertRaisesRegex(SystemExit, 'certificate mismatch'):
            self.invoke_main(cert='b' * 64)

    def test_wrong_version_still_fails(self):
        self.prepare_main()
        with self.assertRaisesRegex(SystemExit, 'Wrong package/version'):
            self.invoke_main(code_delta=1)


if __name__ == '__main__':
    unittest.main()
