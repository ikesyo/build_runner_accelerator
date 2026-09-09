#!/usr/bin/env python3
"""Measure one process and persist machine-readable timing/resource data."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import resource
import shutil
import subprocess
import sys
import time
from pathlib import Path


def _usage() -> resource.struct_rusage:
    return resource.getrusage(resource.RUSAGE_CHILDREN)


def _metadata(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        key, separator, item = value.partition("=")
        if not separator or not key:
            raise ValueError(f"metadata must be KEY=VALUE: {value!r}")
        result[key] = item
    return result


def _trace_stats(path: Path) -> dict[str, int]:
    read_bytes = 0
    read_calls = 0
    open_calls = 0
    read_pattern = re.compile(r"\b(?:read|pread64)\(.*\)\s+=\s+(-?\d+)")
    open_pattern = re.compile(r"\b(?:open|openat)\(.*\)\s+=\s+(-?\d+)")
    try:
        with path.open("r", encoding="utf-8", errors="replace") as trace:
            for line in trace:
                read_match = read_pattern.search(line)
                if read_match:
                    count = int(read_match.group(1))
                    if count > 0:
                        read_calls += 1
                        read_bytes += count
                open_match = open_pattern.search(line)
                if open_match and int(open_match.group(1)) >= 0:
                    open_calls += 1
    except FileNotFoundError:
        return {}
    return {
        "trace_read_calls": read_calls,
        "trace_read_bytes": read_bytes,
        "trace_open_calls": open_calls,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metrics", required=True, type=Path)
    parser.add_argument("--stdout", required=True, type=Path)
    parser.add_argument("--stderr", required=True, type=Path)
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("--label", default="")
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--metadata", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required after --")

    metadata = _metadata(args.metadata)
    for path in (args.metrics, args.stdout, args.stderr):
        path.parent.mkdir(parents=True, exist_ok=True)
    if args.trace:
        args.trace.parent.mkdir(parents=True, exist_ok=True)

    measured_command = command
    trace_enabled = args.trace is not None
    if trace_enabled:
        strace = shutil.which("strace")
        if strace is None:
            raise SystemExit("--trace requires strace on PATH")
        measured_command = [
            strace,
            "-f",
            "-qq",
            "-e",
            "trace=read,pread64,open,openat",
            "-o",
            os.fspath(args.trace),
            "--",
            *command,
        ]

    before = _usage()
    started = dt.datetime.now(dt.timezone.utc)
    start_clock = time.monotonic()
    with args.stdout.open("wb") as stdout, args.stderr.open("wb") as stderr:
        process = subprocess.Popen(
            measured_command,
            cwd=os.fspath(args.cwd) if args.cwd else None,
            stdout=stdout,
            stderr=stderr,
        )
        try:
            return_code = process.wait()
        except BaseException:
            process.terminate()
            process.wait()
            raise
    wall_ms = (time.monotonic() - start_clock) * 1000.0
    after = _usage()

    # RUSAGE_CHILDREN is empty when this helper starts, so ru_maxrss is the
    # peak for this measured command and its descendants. Linux reports KB;
    # keep the unit explicit for portability.
    result: dict[str, object] = {
        **metadata,
        "label": args.label,
        "started_at_utc": started.isoformat(),
        "cwd": os.fspath(args.cwd) if args.cwd else os.getcwd(),
        "command": command,
        "trace_enabled": trace_enabled,
        "exit_code": return_code,
        "wall_ms": round(wall_ms, 3),
        "user_ms": round((after.ru_utime - before.ru_utime) * 1000.0, 3),
        "sys_ms": round((after.ru_stime - before.ru_stime) * 1000.0, 3),
        "maxrss": after.ru_maxrss,
        "maxrss_unit": "kb" if sys.platform.startswith("linux") else "platform",
    }
    if args.trace:
        result["trace_file"] = os.fspath(args.trace)
        result.update(_trace_stats(args.trace))

    args.metrics.write_text(
        json.dumps(result, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return return_code


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        raise SystemExit(str(error)) from error
