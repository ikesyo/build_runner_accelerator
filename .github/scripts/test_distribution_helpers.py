import io
import json
import tarfile
import zipfile
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'


class ManifestTest(unittest.TestCase):
    def manifest(self, targets):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for target, suffix in targets:
                path = root / f'build_runner_accelerator-{target}.{suffix}'
                members = {'VERSION': b'1.0.0', 'SOURCE_COMMIT': b'a' * 40,
                           'build_runner_accelerator' + ('.exe' if target.startswith('windows-') else ''): b'binary'}
                if suffix == 'zip':
                    with zipfile.ZipFile(path, 'w') as archive:
                        for name, content in members.items():
                            archive.writestr(f'{target}/{name}', content)
                else:
                    with tarfile.open(path, 'w:gz') as archive:
                        for name, content in members.items():
                            member = tarfile.TarInfo(f'{target}/{name}')
                            member.size = len(content)
                            archive.addfile(member, io.BytesIO(content))
            result = subprocess.run([sys.executable, str(SCRIPTS / 'create_release_manifest.py'),
                                     '--version', '1.0.0', '--source-commit', 'a' * 40,
                                     '--artifacts-dir', str(root), '--output', str(root / 'manifest.json')],
                                    capture_output=True, text=True)
            manifest = json.loads((root / 'manifest.json').read_text()) if result.returncode == 0 else None
            return result, manifest

    targets = [('macos-arm64', 'tar.gz'), ('linux-x64', 'tar.gz'),
               ('linux-arm64', 'tar.gz'), ('windows-x64', 'zip'), ('windows-arm64', 'zip')]

    def test_rejects_archive_from_another_commit(self):
        sys.path.insert(0, str(SCRIPTS))
        from create_release_manifest import validate_archive
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'archive.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('windows-x64/VERSION', '1.0.0')
                archive.writestr('windows-x64/SOURCE_COMMIT', 'b' * 40)
                archive.writestr('windows-x64/build_runner_accelerator.exe', b'binary')
            with self.assertRaisesRegex(ValueError, 'SOURCE_COMMIT mismatch'):
                validate_archive(path, 'windows-x64', '1.0.0', 'a' * 40)

    def test_exact_matrix_and_source(self):
        result, manifest = self.manifest(self.targets)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(manifest['source_commit'], 'a' * 40)
        self.assertEqual(len(manifest['artifacts']), 5)
        self.assertTrue(all(len(item['sha256']) == 64 for item in manifest['artifacts']))

    def test_missing_unexpected_duplicate_and_wrong_archive(self):
        for targets in [self.targets[:-1], self.targets + [('linux-riscv64', 'tar.gz')],
                        self.targets + [('linux-x64', 'zip')],
                        [(target, 'zip') for target, _ in self.targets]]:
            with self.subTest(targets=targets):
                result, _ = self.manifest(targets)
                self.assertNotEqual(result.returncode, 0)
