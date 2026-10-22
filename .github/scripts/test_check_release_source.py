import unittest
from check_release_source import successful_ci, validate_identity, validate_requested_source


class ReleaseSourceTest(unittest.TestCase):
    def test_requested_ref_cannot_change_workflow_source(self):
        validate_requested_source('a', 'a')
        with self.assertRaises(ValueError):
            validate_requested_source('a', 'b')

    def test_same_tag_source_and_caller(self):
        validate_identity('v1.0.0', 'a', 'a', 'refs/tags/v1.0.0', 'a')

    def test_rejects_divergent_source_or_publisher(self):
        for values in [('v1.0.0', 'b', 'a', 'refs/tags/v1.0.0', 'a'),
                       ('v1.0.0', 'a', 'a', 'refs/heads/main', 'a'),
                       ('v1.0.0', 'a', 'a', 'refs/tags/v1.0.0', 'b'),
                       ('../main', 'a', 'a', 'refs/tags/../main', 'a')]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                validate_identity(*values)

    def test_dry_run_requires_same_workflow_commit_without_tag(self):
        validate_identity('v1.0.0', 'a', None, 'refs/heads/test', 'a', dry_run=True)
        with self.assertRaises(ValueError):
            validate_identity('v1.0.0', 'b', None, 'refs/heads/test', 'a', dry_run=True)

    def test_exact_successful_non_pr_ci(self):
        valid = dict(head_sha='a', event='push', status='completed', conclusion='success')
        self.assertEqual(successful_ci([valid], 'a'), valid)
        for changes in [dict(head_sha='b'), dict(event='pull_request'),
                        dict(status='in_progress'), dict(conclusion='failure'),
                        dict(conclusion='cancelled'), dict(conclusion='skipped')]:
            self.assertIsNone(successful_ci([{**valid, **changes}], 'a'))
        self.assertIsNone(successful_ci([], 'a'))


class ReleaseGateIntegrationTest(unittest.TestCase):
    def gate(self, runs, *, dry_run=False, identity_only=False, requested_sha=None):
        import contextlib
        import io
        import json
        import os
        from pathlib import Path
        import tempfile
        from unittest.mock import patch
        import check_release_source
        sha = 'a' * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {'RELEASE_TAG': 'v1.0.0', 'GITHUB_REF': 'refs/heads/candidate' if dry_run else 'refs/tags/v1.0.0',
                   'RELEASE_DRY_RUN': str(dry_run).lower(), 'GITHUB_SHA': sha,
                   'GITHUB_REPOSITORY': 'owner/repo', 'GITHUB_OUTPUT': str(root / 'output'),
                   'GITHUB_STEP_SUMMARY': str(root / 'summary')}
            if requested_sha:
                env['SOURCE_REF'] = 'candidate'

            def output(command, **kwargs):
                if command[0] == 'git':
                    return sha + '\n'
                if '/commits/' in command[2]:
                    return requested_sha + '\n'
                return json.dumps([{'workflow_runs': runs}])

            previous = Path.cwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ, env, clear=True), \
                     patch('sys.argv', ['gate'] + (['--identity-only'] if identity_only else [])), \
                     patch.object(check_release_source.subprocess, 'check_output', side_effect=output), \
                     patch.object(check_release_source.subprocess, 'run') as fetch, \
                     contextlib.redirect_stdout(io.StringIO()):
                    check_release_source.main()
                self.assertEqual(fetch.call_count, 0 if dry_run else 1)
                self.assertIn(f'sha={sha}', (root / 'output').read_text())
                return json.loads((root / 'release-source.json').read_text())
            finally:
                os.chdir(previous)

    def test_publishing_gate_records_exact_success_evidence(self):
        run = dict(head_sha='a' * 40, event='push', status='completed', conclusion='success',
                   html_url='https://example.test/run/42', id=42)
        evidence = self.gate([run])
        self.assertEqual(evidence['correctness_run_id'], 42)
        self.assertFalse(evidence['dry_run'])

    def test_dry_run_has_same_correctness_requirement(self):
        for dry_run in (False, True):
            with self.subTest(dry_run=dry_run), self.assertRaises(ValueError):
                self.gate([], dry_run=dry_run)

    def test_identity_only_allows_correctness_to_overlap_builds(self):
        evidence = self.gate([], dry_run=True, identity_only=True)
        self.assertNotIn('correctness_run', evidence)

    def test_requested_source_mismatch_stops_before_build(self):
        with self.assertRaisesRegex(ValueError, 'immutable workflow commit'):
            self.gate([], dry_run=True, identity_only=True, requested_sha='b' * 40)
