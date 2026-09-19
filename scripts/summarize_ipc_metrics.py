#!/usr/bin/env python3
"""Summarize opt-in Rust/Dart IPC metrics emitted by a benchmark run."""

from __future__ import annotations

import json
import pathlib
import sys
from collections import defaultdict


def parse_kv_line(line: str, prefix: str) -> dict[str, str] | None:
    if not line.startswith(prefix):
        return None
    values: dict[str, str] = {}
    for token in line[len(prefix) :].split():
        key, separator, value = token.partition("=")
        if separator:
            values[key] = value
    return values


def parse_dart_line(line: str) -> dict[str, object] | None:
    prefix = "Dart metrics: "
    if not line.startswith(prefix):
        return None
    return json.loads(line[len(prefix) :])


def add_numeric(target: dict[str, int], values: dict[str, object], key: str) -> None:
    value = values.get(key)
    if isinstance(value, int):
        target[key] += value


def summarize(paths: list[pathlib.Path]) -> dict[str, object]:
    rust: dict[str, str] = {}
    dart: dict[str, int] = defaultdict(int)
    dart_profiles = 0
    for path in paths:
        with path.open(encoding="utf-8") as stream:
            for raw_line in stream:
                line = raw_line.rstrip("\n")
                parsed_rust = parse_kv_line(line, "Rust metrics: ")
                if parsed_rust is not None:
                    rust = parsed_rust
                    continue
                parsed_dart = parse_dart_line(line)
                if parsed_dart is None:
                    continue
                dart_profiles += 1
                for key in (
                    "total_us",
                    "asset_rpc_us",
                    "asset_rpc_send_us",
                    "asset_rpc_wait_us",
                    "asset_rpc_read_us",
                    "asset_rpc_read_send_us",
                    "asset_rpc_read_wait_us",
                    "asset_rpc_calls",
                    "asset_rpc_read_calls",
                    "asset_rpc_can_read_calls",
                    "asset_rpc_find_assets_calls",
                ):
                    add_numeric(dart, parsed_dart, key)

    result: dict[str, object] = {
        "file": paths[0].name,
        "dart_profiles": dart_profiles,
    }
    for key in (
        "build_us",
        "asset_rpc_us",
        "read_rpc_us",
        "can_read_rpc_us",
        "find_assets_rpc_us",
        "ipc_write_us",
        "ipc_read_us",
        "ipc_frames_sent",
        "ipc_frames_received",
        "ipc_bytes_sent",
        "ipc_bytes_received",
        "read_requests",
        "read_bytes",
        "binary_read_responses",
        "shared_memory_read_responses",
    ):
        value = rust.get(key)
        if value is not None:
            result[f"rust_{key}"] = int(value)
    for key, value in dart.items():
        result[f"dart_{key}"] = value
    rust_asset_rpc = result.get("rust_asset_rpc_us")
    dart_asset_rpc = result.get("dart_asset_rpc_us")
    if isinstance(rust_asset_rpc, int) and isinstance(dart_asset_rpc, int):
        result["asset_rpc_overhead_estimate_us"] = dart_asset_rpc - rust_asset_rpc
    rust_read_rpc = result.get("rust_read_rpc_us")
    dart_read_rpc = result.get("dart_asset_rpc_read_us")
    if isinstance(rust_read_rpc, int) and isinstance(dart_read_rpc, int):
        result["asset_read_rpc_overhead_estimate_us"] = dart_read_rpc - rust_read_rpc
    return result


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} RESULTS_DIR", file=sys.stderr)
        return 2
    results_dir = pathlib.Path(sys.argv[1])
    if not results_dir.is_dir():
        print(f"results directory does not exist: {results_dir}", file=sys.stderr)
        return 2

    records = []
    for stderr_path in sorted(results_dir.glob("*.stderr")):
        worker_log_path = stderr_path.with_name(
            f"{stderr_path.name.removesuffix('.stderr')}.worker.log"
        )
        paths = [stderr_path]
        if worker_log_path.is_file():
            paths.append(worker_log_path)
        records.append(summarize(paths))
    if not records:
        print(f"no stderr files found in {results_dir}", file=sys.stderr)
        return 1
    print("benchmark-ipc: per-case summaries")
    for record in records:
        print(json.dumps(record, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
