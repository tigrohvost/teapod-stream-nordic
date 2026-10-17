import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import package_symbols
import publish_release


class PackageSymbolsTests(unittest.TestCase):
    def test_identical_symbols_give_identical_bytes_despite_new_mtimes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'symbols'
            source.mkdir()
            for abi in ('x64', 'arm', 'arm64'):  # Unsorted creation order.
                (source / f'app.android-{abi}.symbols').write_bytes(abi.encode() * 100)
            package_symbols.pack(source, root / 'first.zip')
            for path in source.iterdir():
                os.utime(path, (2_000_000_000, 2_000_000_000))
            package_symbols.pack(source, root / 'second.zip')
            self.assertEqual((root / 'first.zip').read_bytes(), (root / 'second.zip').read_bytes())
            publish_release.check_symbols(root / 'first.zip')

    def test_empty_symbols_directory_is_an_error(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(SystemExit):
                package_symbols.pack(Path(temp), Path(temp) / 'out.zip')


if __name__ == '__main__':
    unittest.main()
