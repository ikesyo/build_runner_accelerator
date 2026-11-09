from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import correctness_settings as settings


class SettingsCompileCacheTest(unittest.TestCase):
    def test_compile_sequence_uses_fresh_cache_and_restores_shared_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / 'shared'
            shared.mkdir()
            (shared / 'existing-worker').write_text('warm')
            caches = []

            def compile_sequence(temporary, reference):
                cache = Path(settings.ENV['BUILD_RUNNER_ACCELERATOR_CACHE'])
                self.assertEqual(cache.parent, temporary)
                self.assertNotEqual(cache, shared)
                self.assertEqual(list(cache.iterdir()), [])
                (cache / 'compiled-worker').write_text('compiled')
                caches.append(cache)

            with patch.dict(settings.ENV, {'BUILD_RUNNER_ACCELERATOR_CACHE': str(shared)}):
                with patch.object(settings, '_configuration_compile', side_effect=compile_sequence):
                    settings.configuration_compile(root, root / 'stock')
                    settings.configuration_compile(root, root / 'stock')
                self.assertEqual(settings.ENV['BUILD_RUNNER_ACCELERATOR_CACHE'], str(shared))
            self.assertEqual(len(set(caches)), 2)
            self.assertTrue(all(cache.is_dir() for cache in caches))
            self.assertEqual((shared / 'existing-worker').read_text(), 'warm')


if __name__ == '__main__':
    unittest.main()
