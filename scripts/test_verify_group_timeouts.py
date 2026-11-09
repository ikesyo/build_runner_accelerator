"""Exercise per-group and batch deadlines through the real full-verification shell."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform.startswith('linux'), 'requires Linux process groups')
class VerifyGroupTimeoutTest(unittest.TestCase):
    def run_probe(self, root, case_timeout, suite_timeout, mode, *, relative_results=False):
        """Use cheap groups while retaining the production scheduling and cleanup code."""
        scripts = Path(__file__).resolve().parent
        stub = root / 'scripts'
        stub.mkdir()
        for name in ('verify.sh', 'verification_support.sh', 'verification_pool.sh', 'correctness_groups.py'):
            shutil.copy(scripts / name, stub / name)
        (stub / 'toolchain.sh').write_text(
            'resolve_toolchain_dart() { echo /bin/true; }\n'
            'resolve_toolchain_pub_cache() { echo /tmp; }\n')
        (stub / 'worker.sh').write_text('worker_ensure_frontend() { :; }\nworker_prepare() { :; }\n')
        (stub / 'sync_release_metadata.py').write_text('pass\n')
        (stub / 'correctness_output_policies.sh').write_text('exec python3 "$(dirname "$0")/probe.py"\n')
        (stub / 'probe.py').write_text('''import os
from pathlib import Path
import subprocess
import sys
import time
from correctness_groups import run_groups
root = Path(os.environ['TEST_ROOT'])
mode = os.environ['TEST_MODE']
(root / 'runner').write_text(str(os.getpid()))
def setup(temporary):
    with (root / 'setup').open('a') as log:
        log.write('once\\n')
def run(name, workspace):
    with (root / 'groups').open('a') as log:
        log.write(name + '\\n')
    (root / 'workspace').write_text(str(workspace))
    (workspace / 'graph').write_text('committed evidence')
    if mode == 'hang':
        command = "import os, subprocess, time; from pathlib import Path; p=subprocess.Popen(['sleep', '60'], start_new_session=True); Path(os.environ['TEST_ROOT'], 'grandchild').write_text(str(p.pid)); time.sleep(60)"
        proc = subprocess.Popen([sys.executable, '-c', command], start_new_session=True)
        (root / 'child').write_text(str(proc.pid))
        time.sleep(60)
    elif mode == 'anchored':
        # Hold until a fixed offset from the guard's own group-start record,
        # so the measured group duration does not depend on how long the
        # runner took to start the group. Six groups held for one second
        # each make the batch outlast the five-second case deadline only
        # when that deadline resets for every group, while each group ends
        # about three seconds before the earliest point at which the
        # second-granularity guard could fire.
        progress = Path(os.environ['VERIFY_GROUP_PROGRESS_FILE'])
        group_started = int(progress.read_text().split()[0])
        while time.time() < group_started + 1:
            time.sleep(0.05)
    elif mode == 'block':
        time.sleep(300)
    else:
        time.sleep(0.65)
run_groups('probe', 'OUTPUT_POLICY_CASE_GROUP',
           ('routing', 'modes', 'source', 'cache', 'failure', 'api'), run, setup=setup)
print('output-policies stock/native comparisons passed', flush=True)
''')
        env = dict(os.environ, VERIFY_LEVEL='full', VERIFY_FULL_SUITES='output-policies',
                   VERIFY_CASE_TIMEOUT_SECONDS=str(case_timeout),
                   VERIFY_SUITE_TIMEOUT_SECONDS=str(suite_timeout),
                   VERIFY_FULL_TIMEOUT_SECONDS='120', VERIFY_TIMEOUT_GRACE_SECONDS='1',
                   VERIFY_STREAM_LOGS='0', VERIFY_RESULTS_DIR=str(root / 'results'),
                   TEST_ROOT=str(root), TEST_MODE=mode, PYTHONDONTWRITEBYTECODE='1')
        caller = root / 'caller'
        caller.mkdir()
        if relative_results:
            env['VERIFY_RESULTS_DIR'] = 'relative/results'
        try:
            return subprocess.run(['bash', str(stub / 'verify.sh')], cwd=caller, env=env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        finally:
            if (root / 'workspace').exists():
                workspace = Path((root / 'workspace').read_text())
                self.addCleanup(shutil.rmtree, workspace.parent, ignore_errors=True)
            # Registered cleanups run after assertions, so they cannot hide a
            # failure to stop detached children in production timeout handling.
            for name in ('runner', 'child', 'grandchild'):
                if (root / name).exists():
                    self.addCleanup(self.stop_group, int((root / name).read_text()))

    @staticmethod
    def stop_group(pid):
        """Stop a failed test's detached process without masking cleanup assertions."""
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def test_case_deadline_resets_for_every_group_and_setup_runs_once(self):
        """A batch longer than the case budget passes when every group stays within it."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_probe(root, 5, 120, 'anchored')
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual((root / 'setup').read_text(), 'once\n')
            self.assertEqual((root / 'groups').read_text().splitlines(),
                             ['routing', 'modes', 'source', 'cache', 'failure', 'api'])

    def test_relative_results_work_when_the_probe_changes_directory(self):
        """The watchdog and group runner must share one absolute progress path."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_probe(root, 5, 120, 'anchored', relative_results=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual((root / 'groups').read_text().splitlines(),
                             ['routing', 'modes', 'source', 'cache', 'failure', 'api'])

    def test_group_timeout_preserves_evidence_and_stops_detached_descendants(self):
        """An expired group stops the batch, retaining state and killing other sessions."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_probe(root, 3, 12, 'hang')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('timeout label=case/output-policies/group/routing', result.stdout)
            self.assertEqual((root / 'groups').read_text(), 'routing\n')
            workspace = Path((root / 'workspace').read_text())
            try:
                self.assertEqual((workspace / 'graph').read_text(), 'committed evidence')
                for name in ('child', 'grandchild'):
                    pid = int((root / name).read_text())
                    stat = Path(f'/proc/{pid}/stat')
                    if stat.exists():
                        self.assertEqual(stat.read_text().split()[2], 'Z', f'{name} still running')
            finally:
                shutil.rmtree(workspace.parent)

    def test_suite_deadline_still_caps_the_entire_batch(self):
        """The batch stops at the suite budget while a group is within its case budget."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_probe(root, 60, 5, 'block')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            logs = result.stdout + ''.join(p.read_text() for p in (root / 'results').rglob('*.log'))
            self.assertIn('timeout label=', logs)
            self.assertNotIn('timeout label=case/output-policies/group/', logs)
            # The blocked first group can never release the batch, so no
            # later group may start before the suite deadline stops it.
            self.assertEqual((root / 'groups').read_text().splitlines(), ['routing'])
            workspace = Path((root / 'workspace').read_text())
            try:
                self.assertEqual((workspace / 'graph').read_text(), 'committed evidence')
            finally:
                shutil.rmtree(workspace.parent)

    def test_invalid_case_timeout_fails_before_the_probe_runs(self):
        """Validation reports its own error instead of tailing a log never created."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_probe(root, 'bogus', 12, 'success')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('invalid VERIFY_CASE_TIMEOUT_SECONDS', result.stdout)
            self.assertNotIn('No such file or directory', result.stdout)
            self.assertFalse((root / 'groups').exists())


if __name__ == '__main__':
    unittest.main()
