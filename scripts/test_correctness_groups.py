import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urljoin

from correctness_groups import PreparedFixture, run_groups, select_groups


class CorrectnessGroupsTest(unittest.TestCase):
    def test_selection_is_ordered_and_invalid_batches_fail_before_setup(self):
        """Reject malformed selections before setup or any selected group can run."""
        groups = {'first': None, 'second': None}
        self.assertEqual(select_groups('second,first', groups), ('second', 'first'))
        self.assertEqual(select_groups('all', groups), ('first', 'second'))
        for selection in ('', 'first,', ',first', 'first,first', 'first,typo', 'all,first'):
            with self.subTest(selection=selection), patch.dict(os.environ, CASE_GROUP=selection):
                with self.assertRaises(ValueError):
                    run_groups('test', 'CASE_GROUP', groups,
                               lambda *_: self.fail('ran invalid batch'),
                               setup=lambda _: self.fail('prepared invalid batch'))

    def test_groups_get_separate_workspaces_and_clean_up_after_success(self):
        """Set up once before ordered groups, isolating and cleaning their workspaces."""
        roots = []
        setup_roots = []
        def run(name, root):
            self.assertEqual(setup_roots, [root.parent])
            self.assertFalse((root / 'graph').exists())
            (root / 'graph').write_text(name)
            roots.append(root)
        with patch.dict(os.environ, CASE_GROUP='second,first'), contextlib.redirect_stdout(io.StringIO()) as output:
            run_groups('test', 'CASE_GROUP', ('first', 'second'), run, setup=setup_roots.append)
        self.assertEqual(setup_roots, [roots[0].parent])
        self.assertEqual([root.name for root in roots], ['second', 'first'])
        self.assertFalse(roots[0].parent.exists())
        self.assertIn('PASS group=second elapsed=', output.getvalue())

    def test_group_progress_is_published_and_cleared_on_failure(self):
        """The shell guard sees the active group, with no stale deadline afterward."""
        with tempfile.TemporaryDirectory() as directory:
            progress = Path(directory) / 'progress'
            roots = []
            def run(name, root):
                roots.append(root)
                timestamp, active = progress.read_text().split()
                self.assertGreater(int(timestamp), 0)
                self.assertEqual(active, name)
                if name == 'second':
                    raise RuntimeError('requested failure')
            with patch.dict(os.environ, CASE_GROUP='first,second',
                            VERIFY_GROUP_PROGRESS_FILE=str(progress)), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, 'requested failure'):
                    run_groups('test', 'CASE_GROUP', ('first', 'second'), run)
            try:
                self.assertEqual(progress.read_text(), '')
                self.assertFalse(progress.with_name('progress.tmp').exists())
            finally:
                shutil.rmtree(roots[0].parent)

    def test_failure_retains_evidence_and_stops_batch_with_rerun_hint(self):
        """Preserve failed-group evidence and skip subsequent selected groups."""
        roots = []
        def run(name, root):
            roots.append(root)
            (root / 'recovery').write_text('evidence')
            raise RuntimeError('requested failure')
        with patch.dict(os.environ, CASE_GROUP='first,second'), contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(RuntimeError, 'requested failure'):
                run_groups('test', 'CASE_GROUP', ('first', 'second'), run)
        try:
            self.assertEqual(len(roots), 1)
            self.assertEqual((roots[0] / 'recovery').read_text(), 'evidence')
            self.assertIn('rerun: CASE_GROUP=first', output.getvalue())
        finally:
            shutil.rmtree(roots[0].parent)

    def test_historical_all_sequence_can_keep_inter_case_transitions(self):
        """Dispatch the historical all sequence as one stateful group."""
        names = []
        with patch.dict(os.environ, CASE_GROUP='all'), contextlib.redirect_stdout(io.StringIO()):
            run_groups('test', 'CASE_GROUP', ('first', 'second'),
                       lambda name, _: names.append(name), preserve_all=True)
        self.assertEqual(names, ['all'])

    def test_explicit_batch_preserves_selection_when_preserve_all_is_enabled(self):
        """Preserving the historical all sequence must not expand an explicit batch."""
        names = []
        with patch.dict(os.environ, CASE_GROUP='second,first'), contextlib.redirect_stdout(io.StringIO()):
            run_groups('test', 'CASE_GROUP', ('first', 'second', 'third'),
                       lambda name, _: names.append(name), preserve_all=True)
        self.assertEqual(names, ['second', 'first'])

    def test_prepared_fixture_resolves_once_rebases_paths_and_isolates_state(self):
        """Reuse safe setup while relocating packages and separating mutable state."""
        with tempfile.TemporaryDirectory(prefix='fixture paths # ') as directory:
            tmp = Path(directory)
            warmed = []
            def warm(root):
                warmed.append(root)
                for package in ('build_runner', 'other'):
                    path = root / '.dart_tool/pub/bin' / package / 'cli.snapshot'
                    path.parent.mkdir(parents=True)
                    path.write_bytes(b'compiled CLI')
                (root / '.dart_tool/pub/other-state').write_text('mutable')
            prepared = PreparedFixture(tmp / 'template', warm=warm)
            calls = []
            def prepare(root):
                calls.append(root)
                (root / '.dart_tool').mkdir(parents=True)
                (root / 'source').write_text('pristine')
                (root / '.dart_tool/graph-v3.bin').write_bytes(b'graph')
                (root / '.dart_tool/build').mkdir()
                (root / '.dart_tool/build/entrypoint').write_text('compiled paths')
                (root / 'sdk-link').symlink_to(tmp / 'sdk')
                (root / '.dart_tool/package_config.json').write_text(json.dumps({
                    'configVersion': 2,
                    'packages': [
                        {'name': 'fixture', 'rootUri': '../', 'packageUri': 'lib/'},
                        {'name': 'relative', 'rootUri': '../../dependency/'},
                        {'name': 'absolute', 'rootUri': 'file:///sdk/lib/'},
                        {'name': 'nested', 'rootUri': '../gen/'},
                    ],
                }))
            first, second = tmp / 'first', tmp / 'second'
            prepared.copy(first, prepare)
            stamp = (first / 'source').stat().st_mtime_ns
            (first / 'source').write_text('changed')
            (first / '.dart_tool/graph').write_text('mutable state')
            prepared.copy(second, prepare)
            self.assertEqual(len(calls), 1)
            self.assertEqual(len(warmed), 1)
            self.assertEqual((second / '.dart_tool/pub/bin/build_runner/cli.snapshot').read_bytes(),
                             b'compiled CLI')
            self.assertFalse((second / '.dart_tool/pub/bin/other').exists())
            self.assertFalse((second / '.dart_tool/pub/other-state').exists())
            self.assertEqual((second / 'source').read_text(), 'pristine')
            self.assertEqual((second / 'source').stat().st_mtime_ns, stamp)
            self.assertFalse((second / '.dart_tool/graph').exists())
            self.assertFalse((second / '.dart_tool/graph-v3.bin').exists())
            self.assertFalse((second / '.dart_tool/build').exists())
            self.assertTrue((second / 'sdk-link').is_symlink())
            config = second / '.dart_tool/package_config.json'
            packages = json.loads(config.read_text())['packages']
            self.assertEqual(urljoin(config.as_uri(), packages[0]['rootUri']), second.as_uri() + '/')
            self.assertEqual(packages[1]['rootUri'], (tmp / 'dependency').as_uri() + '/')
            self.assertEqual(packages[2]['rootUri'], 'file:///sdk/lib/')
            self.assertEqual(urljoin(config.as_uri(), packages[3]['rootUri']),
                             (second / 'gen').as_uri() + '/')


if __name__ == '__main__':
    unittest.main()
