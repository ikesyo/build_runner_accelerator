"""Check the paired benchmark's preflight before any source mutation."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'paired_warm', REPOSITORY / 'docs/benchmarks/simd-cpu-2026-11/paired_warm.py')
BENCHMARK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCHMARK)


class PairedWarmPreflightTest(unittest.TestCase):
    def invoke(self, workspace, results):
        """Invoke the real CLI preflight with inert executable arguments."""
        arguments = ['paired_warm.py', '--workspace', str(workspace),
                     '--results', str(results), '--repository', str(REPOSITORY)]
        for name in ['baseline', 'native', 'proposal', 'cache', 'dart', 'pub-cache']:
            arguments += ['--' + name, str(workspace / name)]
        with patch.object(sys, 'argv', arguments):
            BENCHMARK.main()

    def test_git_repositories_and_worktrees_are_rejected_before_writes(self):
        for worktree in [False, True]:
            for nested in [False, True]:
                with self.subTest(worktree=worktree, nested=nested), \
                        tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    if worktree:
                        (root / '.git').write_text('gitdir: /unused/worktree\n')
                    else:
                        (root / '.git').mkdir()
                        (root / '.git/HEAD').write_text('ref: refs/heads/main\n')
                    workspace = root / 'nested/app' if nested else root
                    workspace.mkdir(parents=True, exist_ok=True)
                    source = workspace / 'sentinel.dart'
                    source.write_text('unchanged\n')
                    results = root / 'results'
                    with patch.object(BENCHMARK, 'marker') as marker, \
                            patch.object(BENCHMARK.subprocess, 'run') as run:
                        with self.assertRaisesRegex(SystemExit, 'outside a Git checkout'):
                            self.invoke(workspace, results)
                    marker.assert_not_called()
                    run.assert_not_called()
                    self.assertFalse(results.exists())
                    self.assertEqual(source.read_text(), 'unchanged\n')

    def test_prepared_fixture_with_non_repository_control_directory_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.git').mkdir()  # Managed control directory, without HEAD.
            workspace = root / 'fixture'
            for index in range(500):
                model = workspace / f'lib/features/{index}/model.dart'
                model.parent.mkdir(parents=True)
                model.write_text('// generated fixture\n')
            (workspace / 'lib/shared.dart').write_text('enum Lifecycle { draft }\n')
            (workspace / 'pubspec.yaml').write_text('publish_to: none\n')
            aot = workspace / '.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker'
            aot.parent.mkdir(parents=True)
            aot.touch()

            class ReachedRestore(Exception):
                pass

            with patch.object(BENCHMARK, 'marker', side_effect=ReachedRestore) as marker:
                with self.assertRaises(ReachedRestore):
                    self.invoke(workspace, root / 'results')
            marker.assert_called_once_with(workspace.resolve(), 'base')


if __name__ == '__main__':
    unittest.main()
