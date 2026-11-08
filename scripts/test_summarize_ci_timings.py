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

    def test_rerun_delay_uses_attempt_start(self):
        jobs = [{"name": "unit", "status": "completed",
                 "started_at": "2026-01-01T00:01:20Z", "completed_at": "2026-01-01T00:01:30Z",
                 "steps": []}]
        run = {"head_sha": "abc123", "created_at": "2026-01-01T00:00:00Z",
               "run_started_at": "2026-01-01T00:01:00Z", "run_attempt": 2}
        result = summarize(jobs, run)
        self.assertIn("Run attempt: 2", result)
        self.assertIn("Attempt started: 2026-01-01T00:01:00Z", result)
        self.assertIn("Start delay from attempt start: 20s", result)

    def test_rejects_unexpected_json_shape(self):
        with self.assertRaises(ValueError):
            summarize({"workflow": "CI"})
        for payload in ([None], {"jobs": [None]}, {"jobs": None}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                summarize(payload)
        for run in ([], [{"created_at": "2026-01-01T00:00:00Z"}], None):
            if run is None:
                continue
            with self.subTest(run=run), self.assertRaises(ValueError):
                summarize([], run)

    def test_naive_timestamp_is_rejected_and_cli_returns_input_error(self):
        jobs = [{"name": "job", "started_at": "2026-01-01T00:00:00",
                 "completed_at": "2026-01-01T00:01:00", "steps": []}]
        with self.assertRaisesRegex(ValueError, "timezone offset"):
            summarize(jobs)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jobs.json"
            path.write_text(json.dumps({"jobs": jobs}))
            command = [sys.executable, "-B", str(Path(__file__).with_name(
                "summarize_ci_timings.py")), str(path)]
            completed = subprocess.run(command, text=True, capture_output=True)
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertIn("timezone offset", completed.stderr)

    def test_cli_reports_malformed_json_and_jobs_shape_with_exit_two(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "jobs.json"
            command = [sys.executable, "-B", str(Path(__file__).with_name(
                "summarize_ci_timings.py")), str(path)]
            for content, message in (("{broken", "error:"),
                                     ('{"jobs": [null]}', "every item")):
                with self.subTest(content=content):
                    path.write_text(content)
                    completed = subprocess.run(command, text=True, capture_output=True)
                    self.assertEqual(completed.returncode, 2)
                    self.assertEqual(completed.stdout, "")
                    self.assertIn(message, completed.stderr)

            path.write_text('{"jobs": []}')
            run_path = Path(directory) / "run.json"
            run_path.write_text('[{"created_at":"2026-01-01T00:00:00Z"}]')
            completed = subprocess.run(command + ["--run-json", str(run_path)],
                                       text=True, capture_output=True)
            self.assertEqual(completed.returncode, 2)
            self.assertEqual(completed.stdout, "")
            self.assertIn("run JSON must be an object", completed.stderr)

    def test_cli_rejects_invalid_nested_run_attempt_and_step_name(self):
        with tempfile.TemporaryDirectory() as directory:
            jobs_path = Path(directory) / "jobs.json"
            run_path = Path(directory) / "run.json"
            command = [sys.executable, "-B", str(Path(__file__).with_name(
                "summarize_ci_timings.py")), str(jobs_path)]
            jobs_path.write_text('{"jobs": []}')
            for attempt in (None, "2"):
                with self.subTest(run_attempt=attempt):
                    run_path.write_text(json.dumps({"run_attempt": attempt}))
                    completed = subprocess.run(command + ["--run-json", str(run_path)],
                                               text=True, capture_output=True)
                    self.assertEqual(completed.returncode, 2)
                    self.assertEqual(completed.stdout, "")
                    self.assertIn("run_attempt must be a positive integer", completed.stderr)

            for steps in ({}, 0, "invalid"):
                with self.subTest(steps=steps):
                    jobs_path.write_text(json.dumps({"jobs": [{"steps": steps}]}))
                    completed = subprocess.run(command, text=True, capture_output=True)
                    self.assertEqual(completed.returncode, 2)
                    self.assertEqual(completed.stdout, "")
                    self.assertIn("must be an array", completed.stderr)

            for name in (None, 7):
                with self.subTest(step_name=name):
                    jobs_path.write_text(json.dumps({"jobs": [{"steps": [{"name": name}]}]}))
                    completed = subprocess.run(command, text=True, capture_output=True)
                    self.assertEqual(completed.returncode, 2)
                    self.assertEqual(completed.stdout, "")
                    self.assertIn("step names for job", completed.stderr)

    def test_serial_steps_show_longest_completed_without_guessing_setup(self):
        jobs = [{"name": "serial job", "status": "completed",
                 "started_at": "2026-01-01T00:00:00Z",
                 "completed_at": "2026-01-01T00:03:00Z",
                 "steps": [step("Setup", "2026-01-01T00:00:05Z", "2026-01-01T00:01:00Z"),
                           step("Test suite", "2026-01-01T00:01:00Z", "2026-01-01T00:02:30Z"),
                           step("Post cleanup", "2026-01-01T00:02:30Z", "2026-01-01T00:03:00Z")]}]
        result = summarize(jobs)
        self.assertIn("Setup steps: incomplete/unknown", result)
        self.assertIn("Longest completed step: Test suite — 1m 30s", result)
        self.assertNotIn("Longest completed step/lane", result)

    def test_skipped_matrix_step_sentinel_is_not_a_timing(self):
        jobs = [{"name": "Native build (windows)", "status": "completed",
                 "started_at": "2026-01-01T00:00:00Z", "completed_at": "2026-01-01T00:02:00Z",
                 "steps": [step("Build", "2026-01-01T00:00:05Z", "2026-01-01T00:00:25Z"),
                           step("Skipped conditional lane", "0001-01-01T00:00:00Z",
                                "2026-01-01T00:00:00Z"),
                           step("Other lane", "2026-01-01T00:00:25Z",
                                "2026-01-01T00:01:00Z"),
                           step("Verify package", "2026-01-01T00:00:25Z",
                                "2026-01-01T00:01:30Z")] }]
        result = summarize(jobs)
        self.assertIn("Longest completed step/lane: Verify package — 1m 05s", result)
        self.assertNotIn("106549", result)


if __name__ == "__main__":
    unittest.main()
