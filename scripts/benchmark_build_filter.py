#!/usr/bin/env python3
"""Paired release-binary benchmark for the filtered demand scheduler.

Use the before checkout (cfc6ebc by default) and the candidate checkout, each
with an already-built Rust release binary. Override the baseline revision when
comparing against another pre-scheduler serial revision. This harness never
builds either binary.
It stages the tracked build-filter fixture once, adds forty independent text
inputs, and alternates both binaries through that same workspace, SDK, pub
cache, and accelerator cache. Every repeat measures a cold clean build, one
warm no-op, one changed input, and a broad edit of all text inputs; the default
three repeats produce at least three observations for every case.
`--delay-ms 0 50` selects both the short builder workload and a workload with
50 ms injected into every executed fixture builder action.
Every timed build has runtime diagnostics disabled and is checked against the
other lane for output bytes and actual builder history. No-op must execute no
builders; one-file and broad must execute the expected real actions.

Select `--scenario external-source` to add one external package asset that the
selected finish actions test with canRead and read as they build. Set its exact
size with `--external-bytes` (1 through 1,048,576; default 65,536); the fixture
uses deterministic ASCII text. The clean sample clears the per-build
accelerator cache, so each invocation includes a first read of the shared
asset, while later actions in that build may reuse worker-side data. The OS
page cache is not cleared. Stock build_runner's successful canRead also
populates its content cache, so this case compares end-to-end behavior and
bytes, not a claim that only the native lane reads the filesystem. The asset
is shared by all selected finish actions, so the maximum fixture content read
volume is bounded by the asset size times the number of such actions.

The worker mode is explicit and independent: --worker-mode jit, aot, or both.
In AOT mode the clean sample includes compiling a missing worker artifact into
the reset accelerator cache; its following warm samples reuse that artifact.
Dependency resolution, Dart/pub cache warming, release-binary acquisition,
and fixture setup are outside the measured interval. The OS page cache is not
flushed. The default scenario measures the filtered build command and its
selected builder work on the small synthetic fixture. The external-source
scenario measures that same workload plus a cold first read of one external
package asset shared by selected actions; it does not model Resolver/Analyzer,
glob-scan, or resident watch-cycle performance. Resolver work needs generated
Dart inputs and a fresh Analyzer store, glob work needs a controlled number of
matching members plus membership-only edits, and watch work needs startup and
resident edit-cycle timings reported separately.

Example after preparing the two worktrees, fixture dependencies, and release
binaries:

  python3 scripts/benchmark_build_filter.py \\
    --before-package /tmp/build-filter-perf-before \\
    --after-package "$PWD" \\
    --before-bin /tmp/build-filter-perf-before/rust/target/release/build_runner_accelerator \\
    --after-bin "$PWD/rust/target/release/build_runner_accelerator" \\
    --results /tmp/build-filter-release-results
"""

from collections import Counter
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import tempfile
import threading
import time

import correctness_build_filter as fixture
from correctness_cli import descendants


REPO = Path(__file__).resolve().parents[1]
EXPECTED_BASELINE = "cfc6ebc"
FILTER = "--build-filter=lib/*.final"
OUTPUT_SUFFIXES = {".mid", ".side", ".final", ".ignored", ".post"}
CASES = ("clean", "no-op", "one-file", "broad")


def available_cpu_count():
    """Use the selected Dart SDK's Platform processor count for `jobs=available`."""
    with tempfile.TemporaryDirectory(prefix="build-filter-cpu-count-") as temporary:
        script = Path(temporary) / "processors.dart"
        script.write_text("import 'dart:io';\nvoid main() => print(Platform.numberOfProcessors);\n")
        output = subprocess.check_output([fixture.DART, str(script)], text=True, timeout=30)
    count = int(output.strip())
    if count < 1:
        raise ValueError(f"Dart reported an invalid processor count: {count}")
    return count


def git_revision(package):
    return subprocess.check_output(
        ["git", "-C", str(package), "rev-parse", "HEAD"], text=True
    ).strip()


def tool_output(command):
    return subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=30).stdout.strip()


def binary_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def select_jobs(values, available):
    result = []
    for value in values:
        try:
            jobs = available if value == "available" else int(value)
        except ValueError:
            raise ValueError(f"invalid jobs value: {value!r}; use a positive integer or 'available'")
        if jobs < 1 or jobs > available:
            raise ValueError(f"jobs={jobs} is outside the available CPU range 1..{available}")
        if jobs not in result:
            result.append(jobs)
    return result


def configure_package(root, package):
    """Point the disposable fixture at one package checkout and resolve offline."""
    pubspec = root / "pubspec.yaml"
    contents = pubspec.read_text()
    before, count = re.subn(
        r"(?m)^  build_runner_accelerator:\n    path: .*?$",
        lambda _: f"  build_runner_accelerator:\n    path: {json.dumps(str(package))}",
        contents,
    )
    assert count == 1, (pubspec, count)
    pubspec.write_text(before)
    code, log = fixture.execute([fixture.DART, "pub", "get", "--offline"], root)
    assert code == 0, (package, log)
    return normalized_lock(root / "pubspec.lock")


def normalized_lock(path):
    """Keep lockfile versions exact while normalizing this local path package."""
    lines = path.read_text().splitlines()
    in_package = False
    for index, line in enumerate(lines):
        package_header = re.match(r"^  [^ ]", line)
        if package_header:
            in_package = line == "  build_runner_accelerator:"
        elif in_package and re.match(r"^      path:", line):
            lines[index] = "      path: <local accelerator checkout>"
    return "\n".join(lines) + "\n"


def reset_build_state(root, cache, sources):
    """Restore source bytes and remove generated graph, outputs, and worker cache."""
    for path, content in sources.items():
        path.write_bytes(content)
    for path in (root / "lib").rglob("*"):
        if path.is_file() and path.suffix in OUTPUT_SUFFIXES:
            path.unlink()
    for path in (root / ".dart_tool/build_runner_accelerator",
                 root / ".dart_tool/build", cache):
        shutil.rmtree(path, ignore_errors=True)
    fixture.history_path(root).unlink(missing_ok=True)


def expected_history(case, sources):
    if case == "no-op":
        return Counter()
    if case == "one-file":
        return Counter({"lib/item00.txt": 1, "lib/item00.mid": 1})
    names = [str(path.relative_to(path.parents[1])) for path in sources]
    if case == "clean":
        result = Counter(names)
        result.update(name[:-4] + ".mid" for name, source in zip(names, sources.values())
                      if source.strip() != b"empty")
        return result
    if case == "broad":
        result = Counter(names)
        result.update(name[:-4] + ".mid" for name in names)
        return result
    raise AssertionError(case)


def output_digest(outputs):
    digest = hashlib.sha256()
    for name, content in sorted(outputs.items()):
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(content)
        digest.update(b"\0")
    return digest.hexdigest()


def kill_process_tree(process):
    """Kill the launcher's group and any native/worker groups it created."""
    child_pids = descendants(process.pid)
    child_groups = set()
    for pid in child_pids:
        try:
            child_groups.add(os.getpgid(pid))
        except ProcessLookupError:
            pass
    for group in child_groups:
        if group == process.pid:
            continue
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for pid in child_pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run_timed(command, root, environment, log_path, timeout):
    command = list(map(str, command))
    started = time.perf_counter()
    with log_path.open("w") as log:
        process = subprocess.Popen(command, cwd=root, env=environment,
                                   stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        expired = threading.Event()

        def kill_group():
            if process.poll() is not None:
                return
            expired.set()
            kill_process_tree(process)

        watchdog = threading.Timer(timeout, kill_group)
        watchdog.daemon = True
        watchdog.start()
        try:
            return_code = process.wait()
        except BaseException:
            kill_process_tree(process)
            process.wait()
            raise
        finally:
            watchdog.cancel()
            watchdog.join()
        if expired.is_set():
            raise subprocess.TimeoutExpired(command, timeout)
    elapsed = time.perf_counter() - started
    if return_code:
        raise subprocess.CalledProcessError(return_code, command,
                                            output=log_path.read_text())
    return elapsed, log_path.read_text()


def invoke_case(args, package, binary, root, cache, sources, mode, jobs,
                repeat, lane, case, log_dir, external_source, delay_ms):
    environment = fixture.fixture_env(root)
    environment.update({
        "BUILD_RUNNER_ACCELERATOR_BIN": str(binary),
        "BUILD_RUNNER_ACCELERATOR_CACHE": str(cache),
        "BUILD_RUNNER_ACCELERATOR_METRICS": "0",
        "BUILD_RUNNER_ACCELERATOR_WORKER_AOT": "0",
    })
    environment.pop("BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH", None)
    environment.pop("BUILD_RUNNER_ACCELERATOR_WALL_TRACE", None)
    environment.pop("BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE", None)
    environment.pop("BUILD_RUNNER_ACCELERATOR_ANALYSIS_SINGLE_FLIGHT", None)
    if external_source:
        environment["BUILD_FILTER_EXTERNAL_READ"] = "1"
    else:
        environment.pop("BUILD_FILTER_EXTERNAL_READ", None)
    if delay_ms:
        environment["BUILD_FILTER_DELAY_MS"] = str(delay_ms)
    else:
        environment.pop("BUILD_FILTER_DELAY_MS", None)
    command = [
        fixture.DART,
        f"--packages={root / '.dart_tool/package_config.json'}",
        str(package / "bin/build_runner_accelerator.dart"),
        "build", "--mode=rust", "--dart", fixture.DART,
        "--root", str(root), f"--jobs={jobs}", f"--force-{mode}", FILTER,
    ]
    fixture.history_path(root).unlink(missing_ok=True)
    log_path = log_dir / f"{mode}-delay{delay_ms}ms-jobs{jobs}-repeat{repeat}-{lane}-{case}.log"
    elapsed, text = run_timed(command, root, environment, log_path, args.timeout)
    assert "(Rust frontend)" in text, (log_path, text)
    outputs = fixture.outputs(root)
    history = fixture.history(root)
    assert history == expected_history(case, sources), (lane, case, history, expected_history(case, sources), log_path)
    if case == "no-op":
        assert outputs == args.clean_outputs, (lane, case, "output changed on no-op", log_path)
    if case in ("one-file", "broad"):
        assert outputs != args.clean_outputs, (lane, case, "edit produced unchanged outputs", log_path)
    return {
        "lane": lane, "worker_mode": mode, "builder_delay_ms": delay_ms,
        "jobs": jobs, "repeat": repeat,
        "case": case, "elapsed_s": elapsed, "executions": sum(history.values()),
        "history": dict(sorted(history.items())), "outputs": len(outputs),
        "output_sha256": output_digest(outputs),
        "output_sha256_by_path": {key: hashlib.sha256(value).hexdigest()
                                   for key, value in sorted(outputs.items())},
        "command": command, "log": str(log_path),
    }, outputs, history


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-package", type=Path, default=Path("/tmp/build-filter-perf-before"))
    parser.add_argument("--after-package", type=Path, default=REPO)
    parser.add_argument("--before-bin", type=Path, required=True)
    parser.add_argument("--after-bin", type=Path, required=True)
    parser.add_argument("--expected-before-revision", default=EXPECTED_BASELINE,
                        help="Required revision prefix for the before checkout (default: cfc6ebc).")
    parser.add_argument("--scenario", choices=("filtered", "external-source"), default="filtered",
                        help="Use the standard filter fixture or add one shared external package asset.")
    parser.add_argument("--external-bytes", type=int, default=65_536,
                        help="External asset size in ASCII bytes, 1..1048576 (default: 65536).")
    parser.add_argument("--jobs", nargs="+", default=["1", "available"],
                        help="Positive worker counts, or 'available' for the CPU limit (default: 1 available).")
    parser.add_argument("--worker-mode", choices=("jit", "aot", "both"), default="both")
    parser.add_argument("--delay-ms", nargs="+", type=int, choices=(0, 50), default=[0, 50],
                        help="Per-action fixture delay values to measure (default: 0 50).")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--results", type=Path, required=True)
    args = parser.parse_args()
    args.before_package = args.before_package.resolve()
    args.after_package = args.after_package.resolve()
    args.before_bin = args.before_bin.resolve()
    args.after_bin = args.after_bin.resolve()
    args.results = args.results.resolve()
    if args.repeats < 3:
        parser.error("--repeats must be at least 3 so every case has three observations")
    if not 1 <= args.external_bytes <= 1_048_576:
        parser.error("--external-bytes must be between 1 and 1048576")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be positive and finite")
    if os.name != "posix" or not Path("/proc").is_dir():
        parser.error("benchmark timeout cleanup requires Linux /proc and process groups")
    if args.results.exists() and any(args.results.iterdir()):
        parser.error(f"results directory is not empty: {args.results}")
    for name, package, binary in (
        ("before", args.before_package, args.before_bin),
        ("after", args.after_package, args.after_bin),
    ):
        if not (package / "bin/build_runner_accelerator.dart").is_file():
            parser.error(f"{name} package has no launcher: {package}")
        if not (package / ".dart_tool/package_config.json").is_file():
            parser.error(f"{name} package dependencies are unresolved: {package}")
        if not binary.is_file() or not os.access(binary, os.X_OK):
            parser.error(f"{name} native binary is missing or not executable: {binary}")
        if binary.parent.name != "release" or binary.parent.parent.name != "target":
            parser.error(f"{name} binary must be an already-built target/release executable: {binary}")
        dirty = subprocess.check_output(
            ["git", "-C", str(package), "status", "--porcelain", "--untracked-files=all"],
            text=True,
        )
        if dirty:
            parser.error(f"{name} checkout must be clean so its release binary matches HEAD:\n{dirty}")
    args.before_revision = git_revision(args.before_package)
    args.after_revision = git_revision(args.after_package)
    if not args.before_revision.startswith(args.expected_before_revision):
        parser.error(f"before checkout is {args.before_revision}, expected {args.expected_before_revision}")
    args.available_cpus = available_cpu_count()
    try:
        args.jobs = select_jobs(args.jobs, args.available_cpus)
    except ValueError as error:
        parser.error(str(error))
    args.worker_modes = ("jit", "aot") if args.worker_mode == "both" else (args.worker_mode,)
    args.delay_ms = list(dict.fromkeys(args.delay_ms))
    return args


def main():
    args = parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    packages = {"before": args.before_package, "after": args.after_package}
    binaries = {"before": args.before_bin, "after": args.after_bin}
    metadata = {
        "before_revision": args.before_revision,
        "after_revision": args.after_revision,
        "before_binary_sha256": binary_digest(args.before_bin),
        "after_binary_sha256": binary_digest(args.after_bin),
        "before_binary_version": tool_output([str(args.before_bin), "--version"]),
        "after_binary_version": tool_output([str(args.after_bin), "--version"]),
        "dart": fixture.DART,
        "dart_version": tool_output([fixture.DART, "--version"]),
        "pub_cache": fixture.ENV.get("PUB_CACHE"),
        "available_cpus": args.available_cpus,
        "available_cpu_source": "Dart Platform.numberOfProcessors",
        "jobs": args.jobs,
        "worker_modes": args.worker_modes,
        "builder_delay_ms": args.delay_ms,
        "builder_delay_scope": "fixture delay runs once per executed builder action",
        "repeats": args.repeats,
        "cases": CASES,
        "scenario": args.scenario,
        "external_asset_bytes": args.external_bytes if args.scenario == "external-source" else None,
        "runtime_metrics": False,
        "os_page_cache_flushed": False,
        "stock_output_comparison": False,
        "expected_before_revision": args.expected_before_revision,
        "fixture_inputs": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in sorted((REPO / "fixtures/build_filter_app/lib").glob("*.txt"))},
    }
    (args.results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    rows = []
    with tempfile.TemporaryDirectory(prefix="build-filter-release-bench-") as temporary:
        base = Path(temporary)
        root = base / "fixture"
        cache = base / "accelerator-cache"
        fixture.prepare(root)
        for index in range(40):
            (root / f"lib/item{index:02}.txt").write_text(f"item {index}\n")
        external_source = None
        if args.scenario == "external-source":
            pattern = "external source benchmark fixture\n"
            external_contents = (pattern * ((args.external_bytes + len(pattern) - 1) // len(pattern)))[:args.external_bytes]
            external_source = fixture.add_external_fixture_package(root, external_contents)
            metadata["external_asset_id"] = "build_filter_external|lib/shared.asset"
            metadata["external_source_sha256"] = hashlib.sha256(
                (external_source / "lib/shared.asset").read_bytes()).hexdigest()
            (args.results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        sources = {path: path.read_bytes() for path in sorted((root / "lib").glob("*.txt"))}
        assert any(path.name == "item00.txt" for path in sources)
        metadata["input_count"] = len(sources)
        metadata["initial_input_sha256"] = {
            str(path.relative_to(root)): hashlib.sha256(content).hexdigest()
            for path, content in sources.items()
        }
        (args.results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        normalized_locks = {}
        for lane, package in packages.items():
            normalized_locks[lane] = configure_package(root, package)
            assert normalized_locks[lane] == normalized_locks.get("before", normalized_locks[lane]), (
                "baseline/candidate resolved different locked dependencies")
        metadata["normalized_pubspec_lock_sha256"] = hashlib.sha256(
            normalized_locks["before"].encode()).hexdigest()
        (args.results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

        for delay_ms in args.delay_ms:
            for mode in args.worker_modes:
                for jobs in args.jobs:
                    for repeat in range(args.repeats):
                        order = ("before", "after") if repeat % 2 == 0 else ("after", "before")
                        repeat_outputs = {}
                        repeat_histories = {}
                        for lane in order:
                            normalized = configure_package(root, packages[lane])
                            assert normalized == normalized_locks["before"], (lane, "dependency lock changed")
                            reset_build_state(root, cache, sources)
                            lane_outputs = {}
                            lane_histories = {}
                            for case in CASES:
                                if case == "one-file":
                                    target = root / "lib/item00.txt"
                                    target.write_text(f"one-file sample {repeat}\n")
                                elif case == "broad":
                                    for path in sources:
                                        path.write_text(f"broad sample {repeat} {path.name}\n")
                                args.clean_outputs = lane_outputs.get("clean")
                                row, output_bytes, history = invoke_case(
                                    args, packages[lane], binaries[lane], root, cache,
                                    sources, mode, jobs, repeat, lane, case, args.results,
                                    external_source is not None, delay_ms,
                                )
                                if case == "clean":
                                    args.clean_outputs = output_bytes
                                else:
                                    assert args.clean_outputs is not None
                                lane_outputs[case] = output_bytes
                                lane_histories[case] = history
                                rows.append(row)
                                (args.results / "builds.json").write_text(json.dumps(rows, indent=2) + "\n")
                                print(f"{mode} delay={delay_ms}ms jobs={jobs} "
                                      f"repeat={repeat + 1}/{args.repeats} {lane} {case} "
                                      f"{row['elapsed_s']:.3f}s", flush=True)
                            repeat_outputs[lane] = lane_outputs
                            repeat_histories[lane] = lane_histories
                        for case in CASES:
                            assert repeat_outputs["before"][case] == repeat_outputs["after"][case], (
                                mode, delay_ms, jobs, repeat, case, "before/after output bytes differ")
                            assert repeat_histories["before"][case] == repeat_histories["after"][case], (
                                mode, delay_ms, jobs, repeat, case, "before/after builder history differs")

    summaries = []
    for mode in args.worker_modes:
        for delay_ms in args.delay_ms:
            for jobs in args.jobs:
                for case in CASES:
                    for lane in ("before", "after"):
                        samples = [row["elapsed_s"] for row in rows
                                   if (row["worker_mode"], row["builder_delay_ms"], row["jobs"],
                                       row["case"], row["lane"])
                                   == (mode, delay_ms, jobs, case, lane)]
                        summaries.append({
                            "lane": lane, "worker_mode": mode, "builder_delay_ms": delay_ms,
                            "jobs": jobs, "case": case,
                            "samples": len(samples), "median_s": statistics.median(samples),
                            "min_s": min(samples), "max_s": max(samples),
                        })
    (args.results / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()
