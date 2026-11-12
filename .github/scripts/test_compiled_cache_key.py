import os
from pathlib import Path
import tempfile
import unittest

from compiled_cache_key import COMPILER_INPUTS, fingerprint


class CompiledCacheKeyTest(unittest.TestCase):
    def test_content_and_locations_invalidate_without_relying_on_mtime(self):
        """A restored timestamp cannot hide an SDK edit; relocation stays separate."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'sdk'
            for name in (*COMPILER_INPUTS, 'lib/core/core.dart'):
                path = sdk / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'original')
            workspace, pub_cache = root / 'checkout', root / 'pub'
            initial = fingerprint(sdk, workspace, pub_cache)
            source = sdk / 'lib/core/core.dart'
            original = source.stat()
            os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns + 1000000))
            self.assertEqual(initial, fingerprint(sdk, workspace, pub_cache))
            source.write_bytes(b'modified')
            os.utime(source, ns=(original.st_atime_ns, original.st_mtime_ns))
            self.assertNotEqual(initial, fingerprint(sdk, workspace, pub_cache))
            source.write_bytes(b'original')
            self.assertEqual(initial, fingerprint(sdk, workspace, pub_cache))
            self.assertNotEqual(initial, fingerprint(sdk, root / 'elsewhere', pub_cache))
            self.assertNotEqual(initial, fingerprint(sdk, workspace, root / 'other-pub'))
            (sdk / 'bin/utils/gen_snapshot').write_bytes(b'replaced')
            self.assertNotEqual(initial, fingerprint(sdk, workspace, pub_cache))
            (sdk / 'bin/utils/gen_snapshot').write_bytes(b'original')
            (sdk / 'revision').write_bytes(b'replaced')
            self.assertNotEqual(initial, fingerprint(sdk, workspace, pub_cache))


if __name__ == '__main__':
    unittest.main()
