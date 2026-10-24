import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import verify_release_attestations as gate


class AttestationGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.dist, self.download, self.results = (root / name for name in ('dist', 'download', 'results'))
        self.dist.mkdir()
        self.download.mkdir()
        for name in gate.SUBJECTS:
            (self.dist / name).write_bytes(name.encode())
            (self.download / name).write_bytes(name.encode())

    def run_gate(self, *, failure=None, version='2.80.0', ref='refs/tags/v1.0.0'):
        self.commands = []

        def run(command, **kwargs):
            self.commands.append(command)
            self.assertTrue(kwargs['check'])
            self.assertEqual(kwargs['timeout'], 180)
            kwargs['stderr'].write('policy/network diagnostic\n')
            if failure:
                raise failure
            kwargs['stdout'].write('[{"verified": true}]\n')

        with patch.object(gate.subprocess, 'check_output', return_value=f'gh version {version}\n'), \
             patch.object(gate.subprocess, 'run', side_effect=run), \
             contextlib.redirect_stdout(io.StringIO()):
            gate.verify(self.download, 'owner/repo', 'a' * 40, ref,
                        self.results, self.dist)

    def evidence(self):
        return json.loads((self.results / 'evidence.json').read_text())

    def test_success_requires_all_six_subjects_and_exact_provenance_policy(self):
        self.run_gate()
        self.assertEqual(self.evidence()['result'], 'passed')
        self.assertEqual(len(self.commands), 6)
        for name, command in zip(gate.SUBJECTS, self.commands):
            self.assertEqual(command[:4], ['gh', 'attestation', 'verify', str(self.download / name)])
            for flag, value in {
                '--repo': 'owner/repo',
                '--cert-identity': 'https://github.com/owner/repo/.github/workflows/release.yml@refs/tags/v1.0.0',
                '--source-digest': 'a' * 40, '--signer-digest': 'a' * 40,
                '--source-ref': 'refs/tags/v1.0.0',
                '--cert-oidc-issuer': 'https://token.actions.githubusercontent.com',
                '--predicate-type': 'https://slsa.dev/provenance/v1',
            }.items():
                self.assertEqual(command[command.index(flag) + 1], value)
            self.assertIn('--deny-self-hosted-runners', command)

    def test_changed_download_blocks_success_even_if_cli_would_succeed(self):
        (self.download / gate.SUBJECTS[-1]).write_bytes(b'changed manifest')
        with self.assertRaisesRegex(ValueError, 'downloaded SHA-256'):
            self.run_gate()
        self.assertEqual(len(self.commands), 5)
        self.assertEqual(self.evidence()['result'], 'failed')

    def test_cli_policy_or_command_failure_blocks_success_and_retains_logs(self):
        # gh reports signature/repository/commit/workflow mismatch and API errors
        # through nonzero status; none may be converted into success.
        for code in (1, 2, 4):
            with self.subTest(code=code), self.assertRaises(subprocess.CalledProcessError):
                self.run_gate(failure=subprocess.CalledProcessError(code, 'gh attestation verify'))
            self.assertEqual(self.evidence()['result'], 'failed')
            self.assertEqual(self.evidence()['subjects'][0]['result'], 'failed')
            self.assertIn('diagnostic', (self.results / f'{gate.SUBJECTS[0]}.log').read_text())

    def test_timeout_and_missing_cli_fail_closed(self):
        for error in (subprocess.TimeoutExpired('gh', 180), FileNotFoundError('gh')):
            with self.subTest(error=error), self.assertRaises(type(error)):
                self.run_gate(failure=error)
            self.assertEqual(self.evidence()['result'], 'failed')

    def test_missing_subject_and_old_cli_fail_closed(self):
        with self.assertRaisesRegex(ValueError, 'CLI >=2.80.0'):
            self.run_gate(version='2.65.0')
        self.assertEqual(self.evidence()['result'], 'failed')
        (self.download / gate.SUBJECTS[0]).unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_gate()
        self.assertEqual(self.evidence()['result'], 'failed')

    def test_dry_run_uses_actual_branch_identity(self):
        self.run_gate(ref='refs/heads/candidate')
        command = self.commands[0]
        self.assertEqual(command[command.index('--source-ref') + 1], 'refs/heads/candidate')
        self.assertTrue(command[command.index('--cert-identity') + 1].endswith('@refs/heads/candidate'))


if __name__ == '__main__':
    unittest.main()
