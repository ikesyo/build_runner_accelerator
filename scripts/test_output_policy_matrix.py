import itertools
import unittest

from correctness_output_policies import lifecycle_matrix


class OutputPolicyMatrixTest(unittest.TestCase):
    def test_full_matrix_covers_every_policy_layout_filter_combination(self):
        full = lifecycle_matrix('full')
        self.assertEqual(set(full), set(itertools.product(
            (False, True), (False, True), ('verify', 'keep'))))
        self.assertEqual(len(full), 8)

    def test_pr_matrix_retains_all_two_axis_interactions(self):
        full = lifecycle_matrix('full')
        pr = lifecycle_matrix('pairwise')
        self.assertEqual(len(pr), 4)
        self.assertTrue(set(pr).issubset(full))
        for axes in itertools.combinations(range(3), 2):
            project = lambda rows: {tuple(row[axis] for axis in axes) for row in rows}
            self.assertEqual(project(pr), project(full), axes)

    def test_unknown_coverage_fails_instead_of_skipping_cases(self):
        with self.assertRaisesRegex(ValueError, 'unknown output-policy coverage'):
            lifecycle_matrix('typo')


if __name__ == '__main__':
    unittest.main()
