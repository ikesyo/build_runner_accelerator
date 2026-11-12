from pathlib import Path
import tempfile
import unittest

from check_ci import (check, check_composite_anchors, check_group_coverage,
                      matrix_size, registry_names)


class CheckCiTest(unittest.TestCase):
    def test_composite_rejects_anchors_and_accepts_literal_ampersands(self):
        with self.assertRaisesRegex(ValueError, 'do not support YAML anchors'):
            check_composite_anchors('value: &cached item\ncopy: *cached\n', 'action.yml')
        check_composite_anchors('run: |\n  echo "a && b"\n', 'action.yml')

    def test_expands_each_event_instead_of_assuming_pr_has_fewer_jobs(self):
        matrix = {'include': "${{ fromJSON(github.event_name == 'pull_request' && "
                            "'[{}, {}, {}]' || '[{}]') }}"}
        self.assertEqual(matrix_size(matrix, 'pull_request'), 3)
        self.assertEqual(matrix_size(matrix, 'push'), 1)

    def test_rejects_growth_beyond_reserved_runner_budget(self):
        with self.assertRaisesRegex(ValueError, '17 CI jobs'):
            check({'jobs': {str(i): {'steps': []} for i in range(17)}})

    def test_rejects_unbounded_matrix_expression(self):
        with self.assertRaisesRegex(ValueError, 'unrecognized matrix'):
            matrix_size({'include': '${{ fromJSON(needs.plan.outputs.matrix) }}'},
                        'pull_request')

    def test_rejects_excessive_in_runner_parallelism(self):
        with self.assertRaisesRegex(ValueError, 'four lanes'):
            check({'jobs': {'integration': {'steps': [{'parallel': [{}] * 5}]}}})

    def test_classifier_is_excluded_from_the_budget_but_must_stay_a_leaf(self):
        workflow = {'jobs': {
            'changes': {'steps': []},
            'dart-package': {'steps': []}}}
        check(workflow)
        workflow['jobs']['changes']['needs'] = 'dart-package'
        with self.assertRaisesRegex(ValueError, 'must not depend'):
            check(workflow)

    def test_package_jobs_must_not_be_gated_by_classification(self):
        workflow = {'jobs': {
            'changes': {'steps': []},
            'dart-package': {'steps': [], 'needs': 'changes',
                             'if': 'needs.changes.outputs.jobs'}}}
        with self.assertRaisesRegex(ValueError, 'must not be gated'):
            check(workflow)

    def test_gated_jobs_must_test_their_token_in_the_job_scope(self):
        workflow = {'jobs': {
            'changes': {'steps': [
                {'run': "jobs=',integration,'\n"}]},
            'integration': {'steps': [], 'needs': 'changes',
                            'if': 'always()'}}}
        with self.assertRaisesRegex(ValueError, 'must test'):
            check(workflow)
        workflow['jobs']['integration']['if'] = (
            "always() && contains(needs.changes.outputs.jobs, "
            "',integration,')")
        check(workflow)

    def test_classifier_default_must_list_every_gated_job(self):
        workflow = {'jobs': {
            'changes': {'steps': [
                {'run': "jobs=',integration,'\n"}]},
            'integration': {'steps': [], 'needs': 'changes',
                            'if': "contains(needs.changes.outputs.jobs, "
                                  "',integration,')"},
            'native-build': {'steps': [], 'needs': 'changes',
                             'if': "contains(needs.changes.outputs.jobs, "
                                   "',native-build,')"}}}
        with self.assertRaisesRegex(ValueError, 'default jobs value'):
            check(workflow)


COVERAGE_SUITES = {
    'correctness_build_filter.py': "GROUPS = {'alpha': None, 'beta': None}\n",
    'correctness_settings.py': (
        "CASE_GROUPS = {'values': None}\n"
        "WATCH_CONFIGS = {'watch-default': None}\n"
        "GROUPS = (*CASE_GROUPS, 'files', *WATCH_CONFIGS)\n"),
    'correctness_output_policies.py': (
        "def run():\n"
        "    groups = {'source': None, 'api': None}\n"),
    'correctness_nested_packages.py': (
        "def case_groups(tmp):\n"
        "    return {'default-on': (), 'recovery-actions': ()}\n"
        "\n"
        "def recovery_cases(tmp, selected='all'):\n"
        "    cases = {'failure-cancel': None, 'builder-transition': None}\n"),
    'correctness_dependency_window.py': (
        "CASES = (('2.15.3', '13.3.0', '2.15.3'),\n"
        "         ('2.16.1', '14.5.0', '2.16.2'))\n"),
    'correctness_json_serializable.sh': (
        "known_case_names=(\n  alpha\n  beta\n)\n"
        "if [[ \"$case_filter\" == shared-baseline ]]; then\n  :\nfi\n"),
    'correctness_drift_analyzer.sh': (
        "case \"$case_filter\" in\n  all | core | failure) ;;\nesac\n"),
}

COVERAGE_LANES = [
    'BUILD_FILTER_CASE_GROUP=alpha bash scripts/correctness_build_filter.sh',
    'BUILD_FILTER_CASE_GROUP=beta bash scripts/correctness_build_filter.sh',
    'SETTINGS_CASE_GROUP=values,files,watch-default '
    'bash scripts/correctness_settings.sh',
    'OUTPUT_POLICY_CASE_GROUP=source,api '
    'bash scripts/correctness_output_policies.sh',
    'NESTED_PACKAGE_CASE_GROUP=default-on '
    'bash scripts/correctness_nested_packages.sh',
    'NESTED_PACKAGE_CASE_GROUP=recovery-actions '
    'NESTED_PACKAGE_RECOVERY_CASE=failure-cancel '
    'bash scripts/correctness_nested_packages.sh',
    'NESTED_PACKAGE_CASE_GROUP=recovery-actions '
    'NESTED_PACKAGE_RECOVERY_CASE=builder-transition '
    'bash scripts/correctness_nested_packages.sh',
    'python3 scripts/correctness_dependency_window.py '
    '--runner 2.15.3 --analyzer 13.3.0',
    'python3 scripts/correctness_dependency_window.py '
    '--runner 2.16.1 --analyzer 14.5.0',
    'CASE_FILTER=shared-baseline bash scripts/correctness_json_serializable.sh',
    'CASE_FILTER=core bash scripts/correctness_drift_analyzer.sh',
]


def coverage_workflow(lanes):
    return {'jobs': {'job': {'steps': [
        {'parallel': [{'run': lane} for lane in lanes]}]}}}


class CheckCiCoverageTest(unittest.TestCase):
    def repo(self, root):
        scripts = Path(root) / 'scripts'
        scripts.mkdir(parents=True)
        for name, source in COVERAGE_SUITES.items():
            (scripts / name).write_text(source)
        return Path(root)

    def test_complete_assignment_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            check_group_coverage(coverage_workflow(COVERAGE_LANES),
                                 self.repo(directory))

    def test_unassigned_group_fails(self):
        lanes = [lane for lane in COVERAGE_LANES if 'beta' not in lane]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'build-filter'):
                check_group_coverage(coverage_workflow(lanes),
                                     self.repo(directory))

    def test_duplicated_group_fails(self):
        lanes = COVERAGE_LANES + [
            'BUILD_FILTER_CASE_GROUP=alpha '
            'bash scripts/correctness_build_filter.sh']
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'build-filter'):
                check_group_coverage(coverage_workflow(lanes),
                                     self.repo(directory))

    def test_unknown_group_fails(self):
        lanes = COVERAGE_LANES + [
            'SETTINGS_CASE_GROUP=typo bash scripts/correctness_settings.sh']
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'settings'):
                check_group_coverage(coverage_workflow(lanes),
                                     self.repo(directory))

    def test_missing_dependency_window_case_fails(self):
        lanes = [lane for lane in COVERAGE_LANES if '2.16.1' not in lane]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'dependency-window'):
                check_group_coverage(coverage_workflow(lanes),
                                     self.repo(directory))

    def test_missing_recovery_sub_case_fails(self):
        lanes = [lane for lane in COVERAGE_LANES
                 if 'builder-transition' not in lane]
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'nested-packages'):
                check_group_coverage(coverage_workflow(lanes),
                                     self.repo(directory))

    def test_unrecognized_case_filter_fails(self):
        lanes = COVERAGE_LANES + [
            'CASE_FILTER=typo bash scripts/correctness_drift_analyzer.sh']
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'CASE_FILTER'):
                check_group_coverage(coverage_workflow(lanes),
                                     self.repo(directory))

    def test_registry_composition_and_function_dicts(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = self.repo(directory)
            self.assertEqual(
                registry_names(repo / 'scripts/correctness_settings.py',
                               'module', 'GROUPS'),
                {'values', 'files', 'watch-default'})
            self.assertEqual(
                registry_names(repo / 'scripts/correctness_nested_packages.py',
                               'function', 'case_groups'),
                {'default-on', 'recovery-actions'})


if __name__ == '__main__':
    unittest.main()
