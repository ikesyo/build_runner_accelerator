#!/usr/bin/env python3
"""Capture runner and CPU metadata for a benchmark job."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any

CPU_STAT_FIELDS = (
    "user",
    "nice",
    "system",
    "idle",
    "iowait",
    "irq",
    "softirq",
    "steal",
)


COMMAND_TIMEOUT_SECONDS = 5.0


def run_command(*args: str) -> dict[str, Any]:
    try:
        result = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode(encoding="utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(encoding="utf-8", errors="replace")
        timeout_message = (
            f"command timed out after {COMMAND_TIMEOUT_SECONDS:g} seconds"
        )
        return {
            "argv": list(args),
            "exit_code": None,
            "stdout": stdout.strip(),
            "stderr": f"{stderr.strip()}\n{timeout_message}".strip(),
            "timed_out": True,
        }

    return {
        "argv": list(args),
        "exit_code": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
        "timed_out": False,
    }


def parse_lscpu(output: str) -> dict[str, str]:
    try:
        payload = json.loads(output)
    except json.JSONDecodeError:
        payload = None

    if isinstance(payload, dict):
        values: dict[str, str] = {}
        for item in payload.get("lscpu", []):
            if not isinstance(item, dict):
                continue
            field = str(item.get("field", "")).rstrip(":")
            data = item.get("data")
            if field and data is not None:
                values[field] = str(data).strip()
        if values:
            return values

    values = {}
    for line in output.splitlines():
        if ":" not in line:
            continue
        field, value = line.split(":", 1)
        values[field.strip()] = value.strip()
    return values


def read_proc_stat_cpu() -> dict[str, int]:
    try:
        lines = Path("/proc/stat").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}

    for line in lines:
        if not line.startswith("cpu "):
            continue
        values = line.split()[1:]
        if len(values) < len(CPU_STAT_FIELDS):
            return {}
        return {
            field: int(value)
            for field, value in zip(CPU_STAT_FIELDS, values)
        }
    return {}


def first_value(values: dict[str, str], *names: str) -> str | None:
    for name in names:
        value = values.get(name)
        if value:
            return value
    return None


def normalize_component(value: str | None) -> str:
    if not value:
        return "unknown"
    return re.sub(r"\s+", " ", value.strip()).replace(":", "_")


def integer_or_none(value: str | None) -> int | None:
    if not value:
        return None
    match = re.search(r"\d+", value)
    return int(match.group()) if match else None


def cpu_group(
    architecture: str | None,
    vendor: str | None,
    family: str | None,
    model: str | None,
    stepping: str | None,
    model_name: str | None,
) -> str:
    components = [architecture, vendor, family, model, stepping]
    if all(components):
        return ":".join(normalize_component(value) for value in components)
    return ":".join(
        (
            normalize_component(architecture),
            "name",
            normalize_component(model_name),
        )
    )


def steal_delta(
    before: dict[str, int],
    after: dict[str, int],
) -> dict[str, Any] | None:
    if not before or not after:
        return None

    deltas = {
        field: max(after.get(field, 0) - before.get(field, 0), 0)
        for field in CPU_STAT_FIELDS
    }
    total = sum(deltas.values())
    if total == 0:
        return {
            "jiffies": deltas["steal"],
            "total_jiffies": 0,
            "percent": None,
        }
    return {
        "jiffies": deltas["steal"],
        "total_jiffies": total,
        "percent": round(deltas["steal"] / total * 100, 3),
    }


def capture(phase: str, output: Path, previous: Path | None) -> None:
    lscpu_command = run_command("lscpu", "--json")
    nproc_command = run_command("nproc")
    nproc_all_command = run_command("nproc", "--all")
    uname_command = run_command("uname", "-a")
    lscpu = parse_lscpu(lscpu_command["stdout"])

    architecture = first_value(lscpu, "Architecture")
    vendor = first_value(lscpu, "Vendor ID", "Vendor")
    family = first_value(lscpu, "CPU family")
    model = first_value(lscpu, "Model")
    stepping = first_value(lscpu, "Stepping")
    model_name = first_value(lscpu, "Model name")

    nproc = integer_or_none(nproc_command["stdout"])
    nproc_all = integer_or_none(nproc_all_command["stdout"])
    data: dict[str, Any] = {
        "schema_version": 1,
        "phase": phase,
        "captured_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "benchmark": {
            "id": os.environ.get("BENCHMARK_ID"),
            "lane": os.environ.get("BENCHMARK_LANE"),
            "parallelism": os.environ.get("BENCHMARK_PARALLELISM"),
            "sha": os.environ.get("GITHUB_SHA"),
            "run_id": os.environ.get("GITHUB_RUN_ID"),
            "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
            "workflow": os.environ.get("GITHUB_WORKFLOW"),
            "job": os.environ.get("GITHUB_JOB"),
        },
        "runner": {
            "os": os.environ.get("RUNNER_OS"),
            "arch": os.environ.get("RUNNER_ARCH"),
            "image_os": os.environ.get("ImageOS"),
            "image_version": os.environ.get("ImageVersion"),
        },
        "cpu_group": cpu_group(
            architecture,
            vendor,
            family,
            model,
            stepping,
            model_name,
        ),
        "cpu": {
            "architecture": architecture,
            "vendor": vendor,
            "family": family,
            "model": model,
            "stepping": stepping,
            "model_name": model_name,
            "nproc": nproc,
            "nproc_all": nproc_all,
            "lscpu": lscpu,
        },
        "commands": {
            "lscpu": lscpu_command,
            "nproc": nproc_command,
            "nproc_all": nproc_all_command,
            "uname": uname_command,
        },
        "proc_stat_cpu": read_proc_stat_cpu(),
    }

    if previous is not None and previous.is_file():
        try:
            previous_data = json.loads(previous.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            previous_data = {}
        steal = steal_delta(
            previous_data.get("proc_stat_cpu", {}),
            data["proc_stat_cpu"],
        )
        if steal is not None:
            data["cpu_steal"] = steal

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("before", "after"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--previous", type=Path)
    args = parser.parse_args()
    capture(args.phase, args.output, args.previous)


if __name__ == "__main__":
    main()
