import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from benchmark_shared_byte_store import clear_graph, wait_for_process


class BenchmarkLifecycleTest(unittest.TestCase):
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
                except FileNotFoundError:
                    break
                time.sleep(0.01)
            else:
                self.fail('worker survived the frontend timeout')

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
