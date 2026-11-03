"""Regression coverage for the depfile counting error found in the probe."""

from pathlib import Path
import tempfile
import unittest

from probe_worker_dependencies import source_stats


class DepfileTest(unittest.TestCase):
    def test_counts_complete_source_paths_and_decodes_ninja_escapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.dart_tool').mkdir()
            (root / '.dart_tool/package_config.json').write_text('{}')
            (root / 'first.dart').write_text('one')
            (root / 'with space.dart').write_text('two')
            depfile = root / 'worker.d'
            depfile.write_text('worker: .dart_tool/package_config.json first.dart '
                               '\\\n with\\ space.dart first.dart\n')
            self.assertEqual(source_stats(depfile, root), {'files': 2, 'bytes': 6})


if __name__ == '__main__':
    unittest.main()
