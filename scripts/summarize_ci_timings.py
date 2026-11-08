#!/usr/bin/env python3
"""Print a human-readable timing summary for GitHub Actions jobs JSON.

Fetch input with: gh api repos/OWNER/REPO/actions/runs/RUN/jobs?per_page=100 > jobs.json
This reports observed job and step wall times; parallel lanes are never added.
"""

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys


def parse_time(value):
    """Parse an ISO timestamp; reject naive times instead of guessing a zone."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"timestamp must be a string or null: {value!r}")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        # Actions uses year 0001 as a placeholder for matrix steps skipped by
        # an `if:` condition; it is not an observed timestamp.
        if parsed.year == 1:
            return None
        if parsed.utcoffset() is None:
            raise ValueError(f"timestamp must include a timezone offset: {value!r}")
        return parsed
    except AttributeError:
        return None


def seconds(start, end):
    """Return a valid nonnegative interval length, or None if incomplete."""
    left, right = parse_time(start), parse_time(end)
    if left is None or right is None or right < left:
        return None
    return (right - left).total_seconds()


def duration(value):
    if value is None:
        return "incomplete"
    whole = int(value)
    minutes, secs = divmod(whole, 60)
    return f"{minutes}m {secs:02d}s" if minutes else f"{secs}s"


def is_overhead_step(name):
    lower = name.lower()
    return (lower == "parallel" or lower.startswith("parallel group") or
            lower.startswith("group: ") or lower.startswith("post ") or
            lower in ("set up job", "complete job") or "upload-artifact" in lower or
            "download-artifact" in lower or "upload artifact" in lower or
            "download artifact" in lower)


def interval_union_seconds(spans):
    """Return elapsed wall time covered by possibly overlapping intervals."""
    spans = sorted((start, end) for start, end in spans if start and end and end >= start)
    if not spans:
        return 0
    total = 0
    left, right = spans[0]
    for start, end in spans[1:]:
        if start <= right:
            right = max(right, end)
        else:
            total += (right - left).total_seconds()
            left, right = start, end
    return total + (right - left).total_seconds()


def summarize(payload, run=None):
    """Summarize GitHub job data, keeping setup, job, and parallel time distinct."""
    if isinstance(payload, list):
        jobs = payload
    elif isinstance(payload, dict) and isinstance(payload.get("jobs"), list):
        jobs = payload["jobs"]
    else:
        raise ValueError("jobs JSON must be an array or contain a jobs array")
    if any(not isinstance(job, dict) for job in jobs):
        raise ValueError("every item in the jobs array must be an object")
    if run is not None and not isinstance(run, dict):
        raise ValueError("run JSON must be an object")
    attempt = run.get("run_attempt", 1) if run is not None else 1
    if type(attempt) is not int or attempt < 1:
        raise ValueError("run_attempt must be a positive integer")
    lines = []
    if run:
        sha = run.get("head_sha")
        created = run.get("created_at")
        if sha:
            lines.append(f"Source SHA: {sha}")
        if created:
            lines.append(f"Run attempt: {attempt}")
            reference = run.get("run_started_at") if attempt > 1 else created
            reference_label = "Attempt started" if attempt > 1 and reference else "Run created"
            lines.append(f"{reference_label}: {reference or created}")
    if not jobs:
        lines.append("No jobs found.")
        return "\n".join(lines)

    lines.append("GitHub Actions job timings (observed wall time; parallel lanes overlap):")
    for job in jobs:
        name = job.get("name") or f"job {job.get('id', '?')}"
        job_time = seconds(job.get("started_at"), job.get("completed_at"))
        steps = job.get("steps")
        if steps is None:
            steps = []
        if not isinstance(steps, list):
            raise ValueError(f"steps for job {name!r} must be an array")
        if any("name" in step and not isinstance(step["name"], str)
               for step in steps if isinstance(step, dict)):
            raise ValueError(f"step names for job {name!r} must be strings")
        valid_steps = [(step, seconds(step.get("started_at"), step.get("completed_at")))
                       for step in steps if isinstance(step, dict)]
        ordinary = [(step, elapsed) for step, elapsed in valid_steps
                    if not is_overhead_step(step.get("name", ""))]
        # In this repo's CI, lane steps are emitted by the `parallel` step
        # group and therefore overlap in the Actions API. This also keeps
        # serial pre-lane setup (including fixture resolution) out of lanes.
        concurrent = set()
        for index, (step, elapsed) in enumerate(ordinary):
            start = parse_time(step.get("started_at"))
            end = parse_time(step.get("completed_at"))
            if start is None or end is None:
                continue
            for other_index, (other, _) in enumerate(ordinary):
                if index == other_index:
                    continue
                other_start = parse_time(other.get("started_at"))
                other_end = parse_time(other.get("completed_at"))
                if other_start and other_end and start < other_end and other_start < end:
                    concurrent.add(index)
                    break
        lanes = [(ordinary[index][0].get("name", "unnamed step"), ordinary[index][1])
                 for index in sorted(concurrent) if ordinary[index][1] is not None]
        lane_start = min((parse_time(ordinary[index][0].get("started_at"))
                          for index in concurrent), default=None)
        setup_steps = [(step, elapsed) for step, elapsed in ordinary
                       if lane_start is not None and parse_time(step.get("started_at"))
                       and parse_time(step.get("started_at")) < lane_start]
        setup_time = interval_union_seconds(
            [(parse_time(step.get("started_at")), parse_time(step.get("completed_at")))
             for step, _ in setup_steps])
        setup_complete = bool(setup_steps) and all(elapsed is not None for _, elapsed in setup_steps)
        # Some Actions jobs are serial and have no parallel group. Still show
        # their slowest completed step, while leaving setup unknown.
        completed_steps = [(step.get("name", "unnamed step"), elapsed)
                           for step, elapsed in ordinary if elapsed is not None]
        candidates = lanes if concurrent else completed_steps
        longest = max(candidates, key=lambda item: item[1]) if candidates else None
        lines.append(f"\n- {name} [{job.get('conclusion') or job.get('status') or 'unknown'}]")
        lines.append(f"  Job: {duration(job_time)}")
        lines.append(f"  Setup steps: {duration(setup_time) if setup_complete else 'incomplete/unknown'}")
        if longest and concurrent:
            lines.append(f"  Longest completed step/lane: {longest[0]} — {duration(longest[1])}")
        elif longest:
            lines.append(f"  Longest completed step: {longest[0]} — {duration(longest[1])}")
        else:
            lines.append("  Longest completed step/lane: unavailable")
        if run and run.get("created_at") and job.get("started_at"):
            reference = run.get("run_started_at") if run.get("run_attempt", 1) > 1 else run["created_at"]
            if reference:
                delay = seconds(reference, job["started_at"])
                lines.append(f"  Start delay from {('attempt start' if run.get('run_attempt', 1) > 1 else 'run creation')}: {duration(delay)}")
    return "\n".join(lines)


def main(argv=None):
    """Read JSON files and report malformed input as a concise CLI error."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jobs_json", type=Path, help="gh api jobs response JSON")
    parser.add_argument("--run-json", type=Path, help="optional workflow run JSON")
    args = parser.parse_args(argv)
    try:
        payload = json.loads(args.jobs_json.read_text())
        run = json.loads(args.run_json.read_text()) if args.run_json else None
        print(summarize(payload, run))
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
