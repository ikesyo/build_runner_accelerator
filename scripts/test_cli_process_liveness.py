"""Cover processes disappearing while the CLI cancellation probe reads procfs."""
import unittest
from unittest.mock import patch

from correctness_cli import live


class ProcessLivenessTest(unittest.TestCase):
    def test_running_process_with_spaces_in_name_is_live(self):
        with patch('correctness_cli.Path.read_text', return_value='123 (worker name) S 1 2'):
            self.assertTrue(live(123))

    def test_zombie_is_not_live(self):
        with patch('correctness_cli.Path.read_text', return_value='123 (worker) Z 1 2'):
            self.assertFalse(live(123))

    def test_process_disappearing_before_or_during_read_is_not_live(self):
        for error in (FileNotFoundError(), ProcessLookupError()):
            with self.subTest(error=type(error).__name__):
                with patch('correctness_cli.Path.read_text', side_effect=error):
                    self.assertFalse(live(123))

    def test_unexpected_read_errors_still_fail_the_probe(self):
        with patch('correctness_cli.Path.read_text', side_effect=PermissionError()):
            with self.assertRaises(PermissionError):
                live(123)


if __name__ == '__main__':
    unittest.main()
