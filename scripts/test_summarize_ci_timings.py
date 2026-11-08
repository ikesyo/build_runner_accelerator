import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from summarize_ci_timings import summarize


def step(name, start, end):
    return {"name": name, "started_at": start, "completed_at": end}


class CiTimingSummaryTest(unittest.TestCase):
    def test_parallel_lanes_report_longest_without_summing_or_overhead(self):
        jobs = [{"name": "Integration: example", "status": "completed",
                 "started_at": "2026-01-01T00:00:00Z",
                 "completed_at": "2026-01-01T00:10:00Z",
                 "steps": [step("Set up Dart worker", "2026-01-01T00:00:10Z",
                                 "2026-01-01T00:02:10Z"),
                           step("Resolve fixture dependencies once before parallel checks",
                                "2026-01-01T00:02:10Z", "2026-01-01T00:03:10Z"),
                           step("Setup prewarm", "2026-01-01T00:03:10Z", "2026-01-01T00:08:10Z"),
                           step("Shared parts or dependency window and generic watch",
                                "2026-01-01T00:03:10Z", "2026-01-01T00:07:10Z"),
                           step("Post Run setup-worker", "2026-01-01T00:08:10Z",
                                "2026-01-01T00:10:00Z")]}]
        result = summarize({"jobs": jobs})
        self.assertIn("Job: 10m 00s", result)
        self.assertIn("Setup steps: 3m 00s", result)
        self.assertIn("Longest completed step/lane: Setup prewarm — 5m 00s", result)
        self.assertNotIn("Post Run setup-worker", result)
        self.assertNotIn("9m", result)

    def test_empty_and_incomplete_jobs(self):
        self.assertEqual(summarize({"jobs": []}), "No jobs found.")
        result = summarize([{"name": "still running", "status": "in_progress",
                             "started_at": "2026-01-01T00:00:00Z", "steps": [
                                 step("Set up Dart worker", "2026-01-01T00:00:05Z", None),
                                 step("Lane", "2026-01-01T00:00:10Z", None)]}])
        self.assertIn("Job: incomplete", result)
        self.assertIn("Setup steps: incomplete/unknown", result)
        self.assertIn("Longest completed step/lane: unavailable", result)

    def test_optional_run_context_and_cli(self):
        jobs = [{"name": "unit", "status": "completed", "started_at": "2026-01-01T00:00:20Z",
                 "completed_at": "2026-01-01T00:00:30Z", "steps": []}]
        run = {"head_sha": "abc123", "created_at": "2026-01-01T00:00:00Z"}
        result = summarize(jobs, run)
        self.assertIn("Source SHA: abc123", result)
        self.assertIn("Start delay from run creation: 20s", result)
        with tempfile.TemporaryDirectory() as directory:
            jobs_path = Path(directory) / "jobs.json"
            run_path = Path(directory) / "run.json"
            jobs_path.write_text(json.dumps({"jobs": jobs}))
            run_path.write_text(json.dumps(run))
            command = [sys.executable, "-B", str(Path(__file__).with_name(
                "summarize_ci_timings.py")), str(jobs_path), "--run-json", str(run_path)]
            completed = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("Start delay from run creation: 20s", completed.stdout)

    def test_rejects_unexpected_json_shape(self):
        with self.assertRaises(ValueError):
            summarize({"workflow": "CI"})


if __name__ == "__main__":
    unittest.main()
