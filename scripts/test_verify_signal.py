#!/usr/bin/env python3
"""Tests for interruption of the full-verification timeout wrapper."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(sys.platform.startswith('linux'), 'requires Linux /proc')
class VerifySignalTest(unittest.TestCase):
    def test_full_wrapper_term_stops_command_tree_and_log_tail(self):
        """TERM returns 143 and stops the wrapper's command tree and log tail."""
        scripts = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stub = root / 'scripts'
            stub.mkdir()
            for name in ('verify.sh', 'verification_support.sh', 'verification_pool.sh'):
                shutil.copy(scripts / name, stub / name)
            (stub / 'toolchain.sh').write_text(
                'resolve_toolchain_dart() { echo /bin/true; }\n'
                'resolve_toolchain_pub_cache() { echo /tmp; }\n'
            )
            (stub / 'worker.sh').write_text('''worker_ensure_frontend() {
  setsid bash -c 'echo "$$" > "$TEST_TREE_PID"; sleep 60 & echo "$!" > "$TEST_CHILD_PID"; wait' &
  wait "$!"
}
''')
            (stub / 'sync_release_metadata.py').write_text('pass\n')
            env = dict(os.environ, VERIFY_LEVEL='full', VERIFY_STREAM_LOGS='1',
                       VERIFY_RESULTS_DIR=str(root / 'results'),
                       TEST_TREE_PID=str(root / 'tree'), TEST_CHILD_PID=str(root / 'child'))
            proc = subprocess.Popen(['bash', str(stub / 'verify.sh')], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            try:
                deadline = time.monotonic() + 10
                tails = []
                children = ''
                while time.monotonic() < deadline:
                    self.assertIsNone(proc.poll(), 'wrapper exited before stub started')
                    children = subprocess.run(
                        ['ps', '-o', 'pid=,args=', '--ppid', str(proc.pid)],
                        text=True, stdout=subprocess.PIPE, check=False).stdout
                    tails = [int(row.split()[0]) for row in children.splitlines()
                             if 'tail -n +1 -F' in row]
                    if (root / 'child').exists() and tails:
                        break
                    time.sleep(.05)
                self.assertTrue((root / 'child').exists(), 'stub did not start')
                self.assertTrue(tails, children)
                tree_pid = int((root / 'tree').read_text())
                child_pid = int((root / 'child').read_text())
                proc.send_signal(signal.SIGTERM)
                self.assertEqual(proc.wait(timeout=10), 143)
                for pid in [tree_pid, child_pid, *tails]:
                    try:
                        state = Path(f'/proc/{pid}/stat').read_text().split()[2]
                    except FileNotFoundError:
                        continue
                    self.assertEqual(state, 'Z', f'process {pid} is still running ({state})')
            finally:
                # Find the wrapper's descendants before killing any parent:
                # verification_run_command and the stub each start a session.
                rows = subprocess.check_output(
                    ['ps', '-eo', 'pid=,ppid=,pgid='], text=True).splitlines()
                processes = [tuple(map(int, row.split())) for row in rows]
                descendants = {proc.pid}
                while True:
                    found = {pid for pid, parent, _ in processes if parent in descendants}
                    if found <= descendants:
                        break
                    descendants.update(found)
                groups = {group for pid, _, group in processes if pid in descendants}
                groups.add(proc.pid)
                if (root / 'tree').exists():
                    groups.add(int((root / 'tree').read_text()))
                groups.discard(os.getpgrp())
                for group in groups:
                    try:
                        os.killpg(group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if proc.poll() is None:
                    proc.wait()



if __name__ == '__main__':
    unittest.main()
