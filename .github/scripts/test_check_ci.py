import unittest

from check_ci import check, check_composite_anchors, matrix_size


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


if __name__ == '__main__':
    unittest.main()
