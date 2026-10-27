import errno
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from benchmark_shared_byte_store import (clear_graph, prepare_stock_workspace,
                                         sync_stock_sources, wait_for_process)


class BenchmarkLifecycleTest(unittest.TestCase):
    def test_stock_workspace_shares_inputs_but_never_generated_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repo = base / 'repo'
            root = repo / 'fixtures/app'
            (repo / 'lib').mkdir(parents=True)
            (repo / 'pubspec.yaml').write_text('name: accelerator\n')
            (repo / 'lib/worker.dart').write_text('// worker\n')
            (root / 'lib').mkdir(parents=True)
            (root / 'pubspec.yaml').write_text('path: ../..\n')
            (root / 'pubspec.lock').write_text('locked\n')
            (root / 'lib/model.dart').write_text('source\n')
            (root / 'lib/model.g.dart').write_text('native output\n')
            native_part = root / '.dart_tool/build_runner_accelerator/cache/model.g.part'
            native_part.parent.mkdir(parents=True)
            native_part.write_text('native part\n')

            workspace = base / 'stock-workspace'
            stock = prepare_stock_workspace(repo, root, workspace)
            self.assertEqual(stock.parent.parent, workspace)
            self.assertEqual((stock / 'pubspec.lock').read_text(), 'locked\n')
            self.assertEqual((stock / 'lib/model.dart').read_text(), 'source\n')
            self.assertFalse((stock / 'lib/model.g.dart').exists())
            self.assertFalse((stock / '.dart_tool').exists())

            (stock / 'lib/model.g.dart').write_text('stock output\n')
            (root / 'lib/model.dart').write_text('edited source\n')
            sync_stock_sources(root, stock)
            self.assertEqual((stock / 'lib/model.dart').read_text(), 'edited source\n')
            self.assertEqual((stock / 'lib/model.g.dart').read_text(), 'stock output\n')
            self.assertEqual((root / 'lib/model.g.dart').read_text(), 'native output\n')
            self.assertEqual(native_part.read_text(), 'native part\n')

    def test_stock_workspace_cannot_be_nested_in_native_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'outside the native workspace'):
                prepare_stock_workspace(root, root, root / 'lib/stock')

    def test_completion_preserves_status_and_resources(self):
        process = subprocess.Popen(
            [sys.executable, '-c', 'sum(i * i for i in range(100000)); exit(7)'],
            start_new_session=True,
        )
        usage = wait_for_process(process, 5)
        self.assertEqual(process.returncode, 7)
        self.assertGreater(usage.ru_utime + usage.ru_stime, 0)
        self.assertGreater(usage.ru_maxrss, 0)
        with self.assertRaises(ChildProcessError):
            os.waitpid(process.pid, os.WNOHANG)

    def test_deadline_kills_workers_and_reaps_frontend(self):
        self._check_deadline()

    def _check_deadline(self):
        # A forked worker inherits the isolated process group. Killing only the
        # frontend would leave this worker able to mutate benchmark files.
        code = ('import os, time\n'
                'if os.fork() == 0:\n'
                ' print(os.getpid(), flush=True)\n'
                'time.sleep(60)\n')
        with subprocess.Popen(
            [sys.executable, '-c', code], stdout=subprocess.PIPE, text=True,
            start_new_session=True,
        ) as process:
            worker = int(process.stdout.readline())
            start = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                wait_for_process(process, 0.1)
            self.assertLess(time.monotonic() - start, 5)
            self.assertEqual(process.returncode, -signal.SIGKILL)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
            # An orphan may briefly remain as a zombie awaiting init's reap.
            state = Path(f'/proc/{worker}/stat')
            for _ in range(100):
                try:
                    if state.read_text().split(') ')[1].split()[0] == 'Z':
                        break
                except (FileNotFoundError, ProcessLookupError):
                    break
                time.sleep(0.01)
            else:
                self.fail('worker survived the frontend timeout')

    def test_deadline_handles_proc_entry_disappearing_during_read(self):
        # procfs can return ESRCH after open succeeds if init reaps the worker
        # before read. Exercise the full timeout/reaping check with that race.
        with patch.object(Path, 'read_text',
                          side_effect=ProcessLookupError(errno.ESRCH, 'No such process')) as read:
            self._check_deadline()
        read.assert_called_once()

    def test_clean_removes_nested_native_outputs_without_clearing_byte_store(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            removed = ['lib/model.g.dart',
                       '.dart_tool/build_runner_accelerator/graph-v3.bin',
                       '.dart_tool/build_runner_accelerator/cache/nested/model.g.part']
            kept = ['lib/model.dart',
                    '.dart_tool/build_runner_accelerator/cache/nested/other.bin',
                    '.dart_tool/build_runner_accelerator/byte_store/store.v2.bin']
            for name in removed + kept:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture')
            clear_graph(root)
            clear_graph(root)
            for name in removed:
                self.assertFalse((root / name).exists(), name)
            for name in kept:
                self.assertEqual((root / name).read_bytes(), b'fixture', name)


if __name__ == '__main__':
    unittest.main()
