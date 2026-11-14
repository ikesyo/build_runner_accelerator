"""Comparison labels must not corrupt summary metadata or initialize a run."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('benchmark_workspace_scheduler.py')


class ComparisonNameTest(unittest.TestCase):
    def test_reserved_labels_are_rejected_before_workspace_setup(self):
        for name in ['profile', 'case', 'baseline_over_candidate', 'stock', 'baseline', 'candidate']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                results = Path(directory) / 'results'
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), '--baseline-bin', str(SCRIPT),
                     '--candidate-bin', str(SCRIPT), '--comparison-bin', name, str(SCRIPT),
                     '--results', str(results)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn('reserved or duplicate variant name', result.stderr)
                self.assertIn(repr(name), result.stderr)
                self.assertFalse(results.exists())

    def test_duplicate_comparison_labels_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory) / 'results'
            result = subprocess.run(
                [sys.executable, str(SCRIPT), '--baseline-bin', str(SCRIPT),
                 '--candidate-bin', str(SCRIPT), '--comparison-bin', 'extra', str(SCRIPT),
                 '--comparison-bin', 'extra', str(SCRIPT), '--results', str(results)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("variant name: 'extra'", result.stderr)
            self.assertFalse(results.exists())


if __name__ == '__main__':
    unittest.main()
