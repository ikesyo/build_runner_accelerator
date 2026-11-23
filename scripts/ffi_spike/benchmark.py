#!/usr/bin/env python3
"""Compare BRA's pipe worker and the same worker running inside an AOT host."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
GENERATED = (".g.dart", ".freezed.dart", ".g.part")
CASES = ("clean", "no-op", "one-file", "broad")


def sample_session(session):
    pids = []
    rss = 0
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            if int(fields[3]) != session or fields[0] == "Z":
                continue
            rss += int(fields[21]) * os.sysconf("SC_PAGE_SIZE") // 1024
            pids.append(entry)
        except (OSError, IndexError, ValueError):
            continue
    pss = 0
    for entry in pids:
        try:
            rollup = (entry / "smaps_rollup").read_text().splitlines()
            pss += next(int(line.split()[1]) for line in rollup if line.startswith("Pss:"))
        except (OSError, StopIteration):
            return len(pids), rss, None
    return len(pids), rss, pss if pids else None


def sample_memory(process):
    peak_rss = 0
    peak_pss = None
    peak_processes = 0
    complete_pss_samples = 0
    deadline = time.monotonic() + 240
    while process.poll() is None:
        count, rss, pss = sample_session(process.pid)
        peak_rss = max(peak_rss, rss)
        peak_processes = max(peak_processes, count)
        if pss is not None:
            peak_pss = max(peak_pss or 0, pss)
            complete_pss_samples += 1
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(process.args, 240)
        time.sleep(0.01)
    return {
        "peak_session_rss_kib": peak_rss,
        "peak_session_pss_kib": peak_pss,
        "peak_processes": peak_processes,
        "complete_pss_samples": complete_pss_samples,
    }


def run(command, cwd, env, log, *, expected_status=0, memory=False):
    samples = None
    with log.with_suffix(".stdout").open("wb") as stdout, log.with_suffix(
        ".stderr"
    ).open("wb") as stderr:
        process = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=stdout, stderr=stderr,
            start_new_session=True,
        )
        try:
            if memory:
                samples = sample_memory(process)
            status = process.wait(timeout=240)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise
    if status != expected_status:
        raise SystemExit(
            f"Exit {status}, expected {expected_status}: {command!r}. "
            f"See {log.with_suffix('.stderr')}"
        )
    return samples


def source_files(root):
    return sorted(
        p for p in (root / "lib").rglob("*.dart")
        if not p.name.endswith(GENERATED)
    )


def prepare(fixture, root):
    root.mkdir()
    for name in ("pubspec.yaml", "pubspec.lock", "build.yaml"):
        shutil.copyfile(fixture / name, root / name)
    pubspec = root / "pubspec.yaml"
    pubspec.write_text(pubspec.read_text().replace("path: ../..", f'path: "{REPO}"'))
    for path in source_files(fixture):
        destination = root / path.relative_to(fixture)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)


def inventory(root, package, stock=False):
    cache = "build/generated" if stock else "build_runner_accelerator/cache"
    result = {}
    for label, directory in (
        ("source", root / "lib"),
        ("cache", root / ".dart_tool" / cache / package),
    ):
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.name.endswith(GENERATED):
                result[f"{label}/{path.relative_to(directory)}"] = (
                    hashlib.sha256(path.read_bytes()).hexdigest()
                )
    if not result:
        raise SystemExit(f"No generated outputs in {root}")
    return result


def edit(root, case):
    inputs = source_files(root)
    if (root / "lib/shared.dart").exists():
        models = sorted((root / "lib/features").glob("*/model.dart"))
        for path in models[:1] if case == "one-file" else models:
            source = path.read_text()
            edited = source.replace("'title_base'", "'title_spike'")
            if source == edited:
                raise SystemExit(f"Missing edit anchor in {path}")
            path.write_text(edited)
        if case == "broad":
            shared = root / "lib/shared.dart"
            shared.write_text(shared.read_text().replace("active, archived }", "active, archived, paused }"))
        return
    for path in inputs[:1] if case == "one-file" else inputs:
        source = path.read_text()
        if path.name == "model.dart":
            edited = source.replace("int answer(", "int spikeAnswer(")
        elif path.name == "secondary.dart":
            edited = source.replace("String greeting(", "String spikeGreeting(")
        else:
            edited = source.replace(
                "  final String value;", "  @JsonKey(name: 'spike_value')\n  final String value;"
            )
        if source == edited:
            raise SystemExit(f"Missing edit anchor in {path}")
        path.write_text(edited)


def restore(root, fixture):
    for path in source_files(fixture):
        target = root / path.relative_to(fixture)
        if target.read_bytes() != path.read_bytes():
            shutil.copyfile(path, target)


def clear_native_outputs(root, *, keep_worker=False):
    for path in (root / "lib").rglob("*"):
        if path.is_file() and path.name.endswith(GENERATED):
            path.unlink()
    tool = root / ".dart_tool/build_runner_accelerator"
    if not keep_worker:
        shutil.rmtree(tool)
        return
    (tool / "graph-v3.bin").unlink(missing_ok=True)
    cache = tool / "cache"
    if cache.is_dir():
        shutil.rmtree(cache)


def assert_inventory(actual, expected, label):
    differences = sorted(
        path for path in actual.keys() | expected.keys()
        if actual.get(path) != expected.get(path)
    )
    if differences:
        raise SystemExit(f"{label} output mismatch: {differences[:12]}")


def executors(log, *, clean, no_op):
    diagnostics = log.read_text()
    result = {}
    for stage, prefix in (
        ("triggers", "Dart manifest triggers"),
        ("factory_probe", "Dart manifest probe"),
        ("worker", "Rust pipe worker|Dart FFI worker"),
    ):
        selected = sorted(set(re.findall(rf"^(?:{prefix}): executor=([\w-]+)", diagnostics, re.M)))
        if selected and selected != ["worker-aot"]:
            raise SystemExit(f"{stage}: unexpected executor {selected} in {log}")
        result[stage] = selected
    if (clean and not result["triggers"]) or (not no_op and not result["worker"]):
        raise SystemExit(f"Missing executor evidence in {log}: {result}")
    if "Rust worker AOT compile:" in diagnostics:
        raise SystemExit(f"Unexpected cold AOT compile in {log}")
    return result


def digest_metrics(log):
    totals = dict.fromkeys(
        ("resolver_reads_digest_computations", "resolver_reads_digest_reuses", "resolver_reads_digest_us"),
        0,
    )
    for line in log.read_text().splitlines():
        if line.startswith("Dart action metrics: "):
            try:
                metrics = json.loads(line.removeprefix("Dart action metrics: "))
            except json.JSONDecodeError as error:
                raise SystemExit(f"Invalid action metrics in {log}: {error}") from error
            for key in totals:
                totals[key] += metrics[key]
    scan = re.findall(r"Rust external asset digests: files=(\d+) bytes=(\d+) elapsed_us=(\d+)", log.read_text())
    if scan:
        (files, size, elapsed), = scan
        totals.update(frontend_digest_files=int(files), frontend_digest_bytes=int(size),
                      frontend_digest_us=int(elapsed))
    return totals


def check_worker_boundary(package, fixture, pipe, ffi, commands, mode_env, logs, expected, jobs):
    graph = ffi / ".dart_tool/build_runner_accelerator/graph-v3.bin"
    old_graph = graph.read_bytes()
    missing = list(commands[ffi])
    missing[2] = missing[2].with_name("missing.aot")

    run(missing, ffi, mode_env(ffi), logs / f"{package}-ffi-missing-no-op")
    restore(ffi, fixture)
    failed = logs / f"{package}-ffi-missing-dirty"
    run(missing, ffi, mode_env(ffi), failed, expected_status=1)
    if "Could not start Dart worker isolate" not in failed.with_suffix(".stderr").read_text():
        raise SystemExit(f"{package}: expected an isolate startup failure")
    if graph.read_bytes() != old_graph:
        raise SystemExit(f"{package}: isolate startup failure changed the graph")
    assert_inventory(inventory(ffi, package), expected["broad"], f"{package} failed build")

    for root in (pipe, ffi):
        restore(root, fixture)
        log = logs / f"{package}-{root.name}-pid"
        run(
            commands[root], root, dict(
                mode_env(root), BUILD_RUNNER_ACCELERATOR_WALL_TRACE="1",
                BUILD_RUNNER_ACCELERATOR_FFI_RESET_PROBE="1" if root == ffi else "0",
            ), log,
        )
        events = [
            json.loads(line.removeprefix("Rust wall trace: "))
            for line in log.with_suffix(".stderr").read_text().splitlines()
            if line.startswith("Rust wall trace: ")
        ]
        (scheduler,) = [event["pid"] for event in events if event["stage"] == "native_build"]
        workers = {event["worker_pid"] for event in events if "worker_pid" in event}
        connections = {event["worker_connection"] for event in events if "worker_connection" in event}
        count = len(connections) if root == ffi else len(workers)
        if (not 1 <= count <= jobs or
            (root == ffi and workers != {scheduler}) or
            (root == pipe and scheduler in workers)):
            raise SystemExit(f"{package}: unexpected workers {workers}, connections {connections}")
        reset_workers = {
            event.get("worker_connection", event.get("worker_pid"))
            for event in events if event["stage"] == "worker_resolver_reset"
        }
        if root == ffi and package == "mixed_application" and jobs > 1:
            if count < 2 or len(reset_workers) < 2:
                raise SystemExit(f"{package} {root.name}: expected phase resets in multiple workers")
        assert_inventory(inventory(root, package), expected["clean"], f"{package} retry")
        print(f"{package} {root.name}: {count} workers, {len(reset_workers)} reset, PIDs {sorted(workers)}", flush=True)


def check_interruption(package, root, command, env, logs, expected):
    graph = root / ".dart_tool/build_runner_accelerator/graph-v3.bin"
    old_graph = graph.read_bytes()
    edit(root, "broad")
    progress = logs / f"{package}-ffi-interrupted.stderr"
    with progress.open("wb") as stderr, subprocess.Popen(
        command, cwd=root, env=dict(env, BUILD_RUNNER_ACCELERATOR_METRICS="1"),
        stdout=subprocess.DEVNULL, stderr=stderr, start_new_session=True,
    ) as process:
        try:
            deadline = time.monotonic() + 45
            while b"FFI worker attached:" not in progress.read_bytes():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise SystemExit(f"{package}: no attached worker before interruption")
                time.sleep(0.005)
            os.killpg(process.pid, signal.SIGTERM)
            status = process.wait(timeout=15)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    if status != -signal.SIGTERM or graph.read_bytes() != old_graph:
        raise SystemExit(f"{package}: interrupted build changed the graph or exited unexpectedly")
    assert_inventory(inventory(root, package), expected["clean"], f"{package} interrupted build")
    run(command, root, env, logs / f"{package}-ffi-interrupted-retry")
    assert_inventory(inventory(root, package), expected["broad"], f"{package} interrupted retry")
    print(f"{package}: SIGTERM after worker attach preserved the commit and retry matched stock", flush=True)


def check_cold_shared_cache(package, fixture, pipe, ffi, commands, mode_env, logs, expected):
    cache = Path(tempfile.mkdtemp(prefix="cold-shared-cache.", dir=logs.parent / package))
    for root in (pipe, ffi):
        restore(root, fixture)
        clear_native_outputs(root, keep_worker=True)
        summaries = root / ".dart_tool/build_resolvers"
        if summaries.is_dir():
            shutil.rmtree(summaries)

    # Separate workspaces share the packed stores while their cold SDK
    # summaries are used by several workers in each workspace.
    with ThreadPoolExecutor(max_workers=2) as builds:
        pending = [
            builds.submit(
                run, commands[root], root, dict(
                    mode_env(root),
                    BUILD_RUNNER_ACCELERATOR_CACHE=str(cache),
                    BUILD_RUNNER_ACCELERATOR_METRICS="1",
                    BUILD_RUNNER_ACCELERATOR_FFI_RESET_PROBE="1" if root == ffi else "0",
                ), logs / f"{package}-{root.name}-cold-shared-cache",
            )
            for root in (pipe, ffi)
        ]
        for build in pending:
            build.result()
    for root in (pipe, ffi):
        if not (root / ".dart_tool/build_resolvers/sdk.sum").is_file():
            raise SystemExit(f"{package}: {root.name} did not produce an SDK summary")
        assert_inventory(inventory(root, package), expected["clean"], f"{package} cold {root.name}")
    for name in ("byte_store", "dep_parse"):
        if not any(path.stat().st_size > 16 for path in (cache / name).rglob("data.index")):
            raise SystemExit(f"{package}: no published entries in {name}")
    print(f"{package}: concurrent cold pipe and FFI builds shared the stores and matched stock", flush=True)


def make_mixed_fixture(count, destination):
    original = REPO / "fixtures/riverpod_app"
    for name in ("pubspec.yaml", "pubspec.lock"):
        shutil.copyfile(original / name, destination / name)
    pubspec = destination / "pubspec.yaml"
    pubspec.write_text(pubspec.read_text().replace("name: riverpod_app", "name: mixed_application"))
    subprocess.run(
        [sys.executable, SCRIPTS / "generate_application_fixture.py", str(count), destination],
        check=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--features", type=int, default=100, help="mixed application feature count")
    parser.add_argument("--sample-memory", action="store_true")
    parser.add_argument("--disable-shared-caches", action="store_true")
    parser.add_argument("--external-digest-packages",
                        help="add a pipe lane sharing digests for these comma-separated packages")
    parser.add_argument("--ffi-reader", choices=("stream", "direct"), default="stream")

    parser.add_argument(
        "--fixtures", nargs="+",
        choices=("riverpod_app", "json_serializable_100_app", "mixed_application"),
        default=("riverpod_app", "json_serializable_100_app"),
    )
    args = parser.parse_args()
    if min(args.repeats, args.jobs, args.features) < 1:
        parser.error("--repeats, --jobs and --features must be positive")
    dart_bin = args.dart.resolve()
    dart = [dart_bin, "--suppress-analytics"]
    native = args.native.resolve()
    library = args.library.resolve()
    if not all(path.is_file() for path in (dart_bin, native, library)):
        parser.error("--dart, --native and --library must point to existing files")
    results = args.results.resolve()
    results.mkdir()
    logs = results / "logs"
    logs.mkdir()
    # build_runner finds the SDK relative to the current AOT executable.
    sdk = results / "sdk"
    sdk_bin = sdk / "bin"
    sdk_bin.mkdir(parents=True)
    real_sdk = dart_bin.parent.parent
    (sdk / "lib").symlink_to(real_sdk / "lib", target_is_directory=True)
    (sdk / "version").symlink_to(real_sdk / "version")
    for entry in (real_sdk / "bin").iterdir():
        (sdk_bin / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    host = sdk_bin / "host"
    env = dict(os.environ)
    env.pop("BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH", None)
    env.pop("BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL", None)
    env.pop("BUILD_RUNNER_ACCELERATOR_FFI_RESET_PROBE", None)
    env.pop("BUILD_RUNNER_ACCELERATOR_FFI_DIRECT_READ", None)
    env.pop("BUILD_RUNNER_ACCELERATOR_EXTERNAL_DIGEST_PACKAGES", None)
    env.pop("BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG", None)
    env.update(
        BUILD_RUNNER_ACCELERATOR_WORKER_AOT="force",
        BUILD_RUNNER_ACCELERATOR_FFI_NATIVE=str(native),
        BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM="0",
        BUILD_RUNNER_ACCELERATOR_BYTE_STORE="0" if args.disable_shared_caches else "1",
        BUILD_RUNNER_ACCELERATOR_DEP_CACHE="0" if args.disable_shared_caches else "1",
        BUILD_RUNNER_ACCELERATOR_CACHE=str(results / "accelerator-cache"),
        BUILD_RUNNER_ACCELERATOR_SUPERVISED="1",
        BUILD_RUNNER_ACCELERATOR_METRICS="0",
    )

    run([*dart, "compile", "exe", SCRIPTS / "ffi_spike/host.dart", "-o", host],
        REPO, env, logs / "compile-host")
    metadata = {
        "dart": subprocess.check_output([dart_bin, "--version"], text=True).strip(),
        "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "jobs": args.jobs,
        "mixed_features": args.features,
        "shared_analyzer_byte_store": not args.disable_shared_caches,
        "shared_dependency_cache": not args.disable_shared_caches,
        "ffi_reader": args.ffi_reader,
        "mode": "Warm AOT, shared user caches and workspace SDK summaries, metrics enabled",
        "external_digest_packages": args.external_digest_packages,
    }
    (results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    records = []
    diagnostics = []

    for package in args.fixtures:
        fixture = REPO / "fixtures" / package
        work = results / package
        work.mkdir()
        if package == "mixed_application":
            with tempfile.TemporaryDirectory(prefix="build-runner-accelerator-current-baseline-work.") as scratch:
                generated = Path(scratch) / package
                generated.mkdir()
                make_mixed_fixture(args.features, generated)
                fixture = work / "source"
                shutil.copytree(generated, fixture)
        stock, pipe, ffi = (work / label for label in ("stock", "pipe", "ffi"))
        shared = work / "pipe-shared"
        native_roots = (pipe, ffi, shared) if args.external_digest_packages else (pipe, ffi)
        for root in (stock, *native_roots):
            prepare(fixture, root)
            run([*dart, "pub", "get", *(["--offline"] if args.offline else [])],
                root, env, logs / f"{package}-{root.name}-pub")
            if (root / "pubspec.lock").read_bytes() != (stock / "pubspec.lock").read_bytes():
                raise SystemExit(f"{package}: {root.name} resolved a different lockfile")
        cli_args = ["build", "--dart", dart_bin, "--jobs", str(args.jobs)]
        stock_build = [*dart, "run", "build_runner", "build", "--force-jit"]
        expected = {}
        for case in CASES:
            if case == "broad":
                restore(stock, fixture)
                run(stock_build, stock, env, logs / f"{package}-stock-restore")
            if case in ("one-file", "broad"):
                edit(stock, case)
            run(stock_build, stock, env, logs / f"{package}-stock-{case}")
            expected[case] = inventory(stock, package, stock=True)
        if expected["no-op"] != expected["clean"]:
            raise SystemExit(f"{package}: stock no-op changed outputs")
        for case in ("one-file", "broad"):
            if expected[case] == expected["clean"]:
                raise SystemExit(f"{package}: {case} edit did not change outputs")

        snapshot = work / "worker.aot"
        for root in native_roots:
            run([native, *cli_args, "--jobs", "1"], root, env, logs / f"{package}-{root.name}-prepare")
            assert_inventory(inventory(root, package), expected["clean"], f"{package} prepare")
            generated = root / ".dart_tool/build_runner_accelerator/dynamic_worker.dart"
            if root == ffi:
                shim = (SCRIPTS / "ffi_spike/worker.dart").as_uri()
                worker_import = "package:build_runner_accelerator/src/worker.dart"
                generated_source = generated.read_text()
                if generated_source.count(worker_import) != 1:
                    raise SystemExit(f"Unexpected generated worker import: {generated}")
                source = generated.with_name("ffi_worker.dart")
                source.write_text(generated_source.replace(worker_import, shim))
                run([*dart, "compile", "aot-snapshot", source, "-o", snapshot],
                    root, env, logs / f"{package}-{root.name}-compile")
        commands = {
            pipe: [native, *cli_args],
            ffi: [host, library, snapshot, *cli_args],
            shared: [native, *cli_args],
        }

        def mode_env(root):
            if root == shared:
                return dict(env, BUILD_RUNNER_ACCELERATOR_EXTERNAL_DIGEST_PACKAGES=args.external_digest_packages)
            if root == ffi:
                return dict(
                    env, BUILD_RUNNER_ACCELERATOR_FFI_DIRECT_READ="1" if args.ffi_reader == "direct" else "0",
                )
            return env

        for repeat in range(args.repeats):
            lanes = native_roots if repeat % 2 == 0 else native_roots[::-1]
            for case in CASES:
                case_executors = []
                for root in lanes:
                    label = f"{package}-{root.name}-{case}-{repeat + 1}"
                    if case == "clean":
                        restore(root, fixture)
                        clear_native_outputs(root)
                    if case == "broad":
                        restore(root, fixture)
                        run(commands[root], root, mode_env(root), logs / f"{label}-restore")
                    if case in ("one-file", "broad"):
                        edit(root, case)
                    sample = logs / f"{label}.json"
                    run(
                        [
                            sys.executable, SCRIPTS / "measure_process.py",
                            "--metrics", sample, "--stdout", logs / f"{label}.build.stdout",
                            "--stderr", logs / f"{label}.build.stderr", "--", *commands[root],
                        ],
                        root, dict(mode_env(root), BUILD_RUNNER_ACCELERATOR_METRICS="1"),
                        logs / f"{label}-measure",
                    )
                    actual = inventory(root, package)
                    assert_inventory(actual, expected[case], label)
                    record = json.loads(sample.read_text())
                    log = logs / f"{label}.build.stderr"
                    selected = executors(log, clean=case == "clean", no_op=case == "no-op")
                    case_executors.append(selected)
                    record.update(fixture=package, lane=root.name, case=case, outputs=len(actual),
                                  executors=selected, **digest_metrics(log))
                    records.append(record)
                    print(f"{label}: {record['wall_ms']:.1f} ms, {len(actual)} outputs match stock",
                          flush=True)
                if any(selected != case_executors[0] for selected in case_executors):
                    raise SystemExit(f"{package} {case}: executor mismatch: {case_executors}")

                (results / "samples.json").write_text(json.dumps(records, indent=2) + "\n")
        for root in (pipe, ffi):
            for case in ("no-op", "one-file", "broad"):
                restore(root, fixture)
                run(commands[root], root, mode_env(root), logs / f"{package}-{root.name}-{case}-restore-metrics")
                if case != "no-op":
                    edit(root, case)
                record = run(
                    commands[root], root, dict(mode_env(root), BUILD_RUNNER_ACCELERATOR_METRICS="1"),
                    logs / f"{package}-{root.name}-{case}-metrics", memory=args.sample_memory,
                )
                if record is not None:
                    diagnostics.append(dict(record, fixture=package, lane=root.name, case=case))
                assert_inventory(inventory(root, package), expected[case], f"{package} metrics")
        if diagnostics:
            (results / "memory.json").write_text(json.dumps(diagnostics, indent=2) + "\n")
        check_worker_boundary(package, fixture, pipe, ffi, commands, mode_env, logs, expected, args.jobs)
        if package == "mixed_application":
            check_interruption(package, ffi, commands[ffi], mode_env(ffi), logs, expected)
            if not args.disable_shared_caches and args.jobs > 1:
                check_cold_shared_cache(package, fixture, pipe, ffi, commands, mode_env, logs, expected)

    if diagnostics:
        (results / "memory.json").write_text(json.dumps(diagnostics, indent=2) + "\n")

    (results / "samples.json").write_text(json.dumps(records, indent=2) + "\n")
    for package in args.fixtures:
        for case in CASES:
            for lane in ("pipe", "ffi", "pipe-shared") if args.external_digest_packages else ("pipe", "ffi"):
                subset = [
                    s for s in records
                    if s["fixture"] == package and s["case"] == case and s["lane"] == lane
                ]
                wall = statistics.median(s["wall_ms"] for s in subset)
                rss = statistics.median(s["maxrss"] for s in subset)
                print(f"{package} {case} {lane}: {wall:.1f} ms, maxrss {rss:.0f} KiB")


if __name__ == "__main__":
    main()
