import signal
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import distribution_e2e


class DistributionProcessTest(unittest.TestCase):
    def test_windows_stop_escalates_without_posix_process_groups(self):
        process = Mock(pid=42)
        process.wait.side_effect = [subprocess.TimeoutExpired('watch', 20), 0]
        with patch.object(distribution_e2e.os, 'name', 'nt'), \
             patch.object(distribution_e2e.subprocess, 'run') as taskkill, \
             patch.object(distribution_e2e.os, 'killpg', create=True) as killpg:
            distribution_e2e.stop(process)
        taskkill.assert_called_once()
        self.assertEqual(taskkill.call_args.args[0], ['taskkill', '/PID', '42', '/T', '/F'])
        process.kill.assert_called_once_with()
        killpg.assert_not_called()
        self.assertEqual(process.wait.call_args_list[-1].kwargs, {'timeout': 10})

    @unittest.skipUnless(hasattr(signal, 'SIGKILL'), 'POSIX signals required')
    def test_posix_stop_tolerates_exit_during_escalation(self):
        process = Mock(pid=42)
        process.wait.side_effect = [subprocess.TimeoutExpired('watch', 20), 0]
        with patch.object(distribution_e2e.os, 'name', 'posix'), \
             patch.object(distribution_e2e.os, 'killpg', create=True,
                          side_effect=[None, ProcessLookupError()]) as killpg:
            distribution_e2e.stop(process)
        self.assertEqual(killpg.call_args_list[-1].args, (42, signal.SIGKILL))
        process.kill.assert_not_called()
        self.assertEqual(process.wait.call_args_list[-1].kwargs, {'timeout': 10})
