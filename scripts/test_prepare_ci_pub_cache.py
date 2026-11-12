from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from correctness_dependency_window import CASES
from prepare_ci_pub_cache import prepare, tracked_specs


class PrepareCiPubCacheTest(unittest.TestCase):
    def test_sdk_only_latest_resolutions_do_not_change_offline_integration_choices(self):
        """Keep higher SDK-job-only versions out of the shared integration solution."""
        files = b'\0'.join(name.encode() for name in (
            'fixtures/sdk_compat_app/pubspec.yaml',
            'fixtures/shared_parts_app/pubspec.yaml',
            'fixtures/workspace_json_app/a/pubspec.yaml',
            'fixtures/workspace_json_app/pubspec.yaml',
        )) + b'\0'
        with patch('prepare_ci_pub_cache.subprocess.check_output', return_value=files):
            self.assertEqual(tracked_specs(Path('/repo')), [
                Path('fixtures/workspace_json_app/pubspec.yaml'),
                Path('fixtures/workspace_json_app/a/pubspec.yaml')])

    def fixture(self, root):
        """Create two tracked fixture resolutions, including a nested package."""
        root.mkdir()
        (root / 'pubspec.yaml').write_text('name: accelerator\n')
        (root / 'pubspec.lock').write_text('root lock\n')
        specs = [Path('fixtures/json_serializable_app/pubspec.yaml'),
                 Path('fixtures/nested/member/pubspec.yaml')]
        for spec in specs:
            path = root / spec
            path.parent.mkdir(parents=True)
            path.write_text('name: fixture\ndev_dependencies:\n  build_runner: 2.16.2\n  accelerator:\n    path: ../..\n')
        (root / specs[0].parent / 'pubspec.lock').write_text('fixture lock\n')
        return specs

    def test_success_prepares_nested_and_both_native_and_stock_resolutions(self):
        """Only publish completeness after all actual resolution families ran."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, cache = root / 'repo', root / 'pub'
            specs = self.fixture(repo)
            original = (repo / specs[0]).read_bytes()
            calls = []
            def resolve(command, *, cwd, **kwargs):
                calls.append((command, cwd.name, (cwd / 'pubspec.yaml').read_text()))
            with patch('prepare_ci_pub_cache.tracked_specs', return_value=specs), \
                    patch('prepare_ci_pub_cache.subprocess.run', side_effect=resolve):
                prepare(repo, 'dart', cache, offline=True)
            expected = {(runner, analyzer) for native, analyzer, stock in CASES
                        for runner in (native, stock)}
            self.assertEqual(len(calls), 1 + len(specs) + len(expected))
            self.assertTrue(all('--offline' in command for command, _, _ in calls))
            # Resolutions run in parallel, so key lockfile assertions by package.
            by_cwd = {name: command for command, name, _ in calls}
            root_command = next(command for command, _, spec in calls
                                if spec == 'name: accelerator\n')
            self.assertIn('--enforce-lockfile', root_command)
            self.assertIn('--enforce-lockfile', by_cwd['json_serializable_app'])
            self.assertNotIn('--enforce-lockfile', by_cwd['member'])
            for runner, analyzer in expected:
                self.assertTrue(any(f'build_runner: {runner}\n' in spec and
                                    f'analyzer: {analyzer}\n' in spec and
                                    'source_helper: 1.3.13\n' in spec
                                    for _, _, spec in calls))
            self.assertTrue((cache / 'ci-integration-prepared.json').is_file())
            self.assertEqual((repo / specs[0]).read_bytes(), original)
            self.assertFalse((repo / '.dart_tool').exists())

    def test_failure_removes_old_completeness_receipt(self):
        """A partial preparation must never advertise a shareable complete set."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, cache = root / 'repo', root / 'pub'
            specs = self.fixture(repo)
            cache.mkdir()
            receipt = cache / 'ci-integration-prepared.json'
            receipt.write_text('old receipt')
            def fail_member(command, *, cwd, **kwargs):
                if cwd.name == 'member':
                    raise subprocess.CalledProcessError(1, command)
            with patch('prepare_ci_pub_cache.tracked_specs', return_value=specs), \
                    patch('prepare_ci_pub_cache.subprocess.run', side_effect=fail_member):
                with self.assertRaises(subprocess.CalledProcessError):
                    prepare(repo, 'dart', cache)
            self.assertFalse(receipt.exists())


if __name__ == '__main__':
    unittest.main()
