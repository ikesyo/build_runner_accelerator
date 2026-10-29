from pathlib import Path
import unittest

from correctness_nested_packages import recovery_cases


class NestedRecoverySelectionTest(unittest.TestCase):
    def test_split_lanes_cover_the_full_sequence_once(self):
        root = Path('/unused-test-root')
        full = recovery_cases(root)
        split = (recovery_cases(root, 'failure-cancel')
                 + recovery_cases(root, 'builder-transition'))
        identity = lambda cases: [(case.func, case.args, case.keywords) for case in cases]
        self.assertEqual(identity(full), identity(split))
        self.assertEqual(len({case.func for case in split}), 2)

    def test_each_lane_receives_its_own_workspace(self):
        for selected in ('all', 'failure-cancel', 'builder-transition'):
            root = Path('/isolated-lane') / selected
            self.assertTrue(all(case.args == (root,) for case in recovery_cases(root, selected)))

    def test_unknown_case_cannot_silently_skip_recovery(self):
        with self.assertRaisesRegex(ValueError, 'unknown NESTED_PACKAGE_RECOVERY_CASE'):
            recovery_cases(Path('/unused-test-root'), 'typo')


if __name__ == '__main__':
    unittest.main()
