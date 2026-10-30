import unittest

from check_ci import check, matrix_size


class CheckCiTest(unittest.TestCase):
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
