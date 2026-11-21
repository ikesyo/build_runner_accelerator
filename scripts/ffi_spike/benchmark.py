#!/usr/bin/env python3
"""Compare BRA's pipe worker and the same worker running inside an AOT host."""

import argparse
import hashlib
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
GENERATED = (".g.dart", ".freezed.dart", ".g.part")
CASES = ("clean", "no-op", "one-file", "broad")


def run(command, cwd, env, log, *, expected_status=0):
    with log.with_suffix(".stdout").open("wb") as stdout, log.with_suffix(
        ".stderr"
    ).open("wb") as stderr:
        process = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=stdout, stderr=stderr,
            start_new_session=True,
        )
        try:
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


def clear_native_outputs(root):
    for path in (root / "lib").rglob("*"):
        if path.is_file() and path.name.endswith(GENERATED):
            path.unlink()
    tool = root / ".dart_tool/build_runner_accelerator"
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


def check_worker_boundary(package, fixture, pipe, ffi, commands, mode_env, logs, expected):
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
            commands[root], root, dict(mode_env(root), BUILD_RUNNER_ACCELERATOR_WALL_TRACE="1"),
            log,
        )
        events = [
            json.loads(line.removeprefix("Rust wall trace: "))
            for line in log.with_suffix(".stderr").read_text().splitlines()
            if line.startswith("Rust wall trace: ")
        ]
        (scheduler,) = [event["pid"] for event in events if event["stage"] == "native_build"]
        workers = {event["worker_pid"] for event in events if "worker_pid" in event}
        if len(workers) != 1 or (scheduler in workers) != (root == ffi):
            raise SystemExit(f"{package}: unexpected worker PIDs {workers} for scheduler {scheduler}")
        assert_inventory(inventory(root, package), expected["clean"], f"{package} retry")
        print(f"{package} {root.name}: scheduler PID {scheduler}, worker PID {next(iter(workers))}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", type=Path, required=True)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument(
        "--fixtures", nargs="+",
        choices=("riverpod_app", "json_serializable_100_app"),
        default=("riverpod_app", "json_serializable_100_app"),
    )
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    results = args.results.resolve()
    results.mkdir()
    logs = results / "logs"
    logs.mkdir()
    dart_bin = args.dart.resolve()
    dart = [dart_bin, "--suppress-analytics"]
    native = args.native.resolve()
    library = args.library.resolve()
    # build_runner finds the SDK relative to the current AOT executable.
    sdk = results / "sdk"
    sdk_bin = sdk / "bin"
    sdk_bin.mkdir(parents=True)
    (sdk / "lib").symlink_to(dart_bin.parent.parent / "lib", target_is_directory=True)
    host = sdk_bin / "host"
    env = dict(os.environ)
    env.pop("BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH", None)
    env.pop("BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL", None)
    env.update(
        BUILD_RUNNER_ACCELERATOR_WORKER_AOT="0",
        BUILD_RUNNER_ACCELERATOR_CACHE=str(results / "accelerator-cache"),
        BUILD_RUNNER_ACCELERATOR_SUPERVISED="1",
        BUILD_RUNNER_ACCELERATOR_METRICS="0",
    )

    run([*dart, "compile", "exe", SCRIPTS / "ffi_spike/host.dart", "-o", host],
        REPO, env, logs / "compile-host")
    metadata = {
        "dart": subprocess.check_output([dart_bin, "--version"], text=True).strip(),
        "source_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "jobs": 1,
        "mode": "AOT worker precompiled before measurements",
    }
    (results / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    records = []

    for package in args.fixtures:
        fixture = REPO / "fixtures" / package
        work = results / package
        work.mkdir()
        stock, pipe, ffi = (work / label for label in ("stock", "pipe", "ffi"))
        for root in (stock, pipe, ffi):
            prepare(fixture, root)
            run([*dart, "pub", "get", *(["--offline"] if args.offline else [])],
                root, env, logs / f"{package}-{root.name}-pub")
        cli_args = ["build", "--dart", dart_bin, "--jobs", "1"]
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

        worker_paths = {}
        for root in (pipe, ffi):
            run([native, *cli_args], root, env, logs / f"{package}-{root.name}-prepare")
            assert_inventory(inventory(root, package), expected["clean"], f"{package} prepare")
            generated = root / ".dart_tool/build_runner_accelerator/dynamic_worker.dart"
            source = generated
            output = sdk_bin / f"{package}-worker" if root == pipe else work / "worker.aot"
            if root == ffi:
                shim = (SCRIPTS / "ffi_spike/worker.dart").as_uri()
                worker_import = "package:build_runner_accelerator/src/worker.dart"
                generated_source = generated.read_text()
                if generated_source.count(worker_import) != 1:
                    raise SystemExit(f"Unexpected generated worker import: {generated}")
                source = generated.with_name("ffi_worker.dart")
                source.write_text(generated_source.replace(worker_import, shim))
            run(
                [*dart, "compile", "exe" if root == pipe else "aot-snapshot", source, "-o", output],
                root, env, logs / f"{package}-{root.name}-compile",
            )
            worker_paths[root] = output
        commands = {
            pipe: [native, *cli_args],
            ffi: [host, library, worker_paths[ffi], *cli_args],
        }

        def mode_env(root):
            return (
                dict(env, BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH=str(worker_paths[pipe]))
                if root == pipe else env
            )

        for repeat in range(args.repeats):
            lanes = (pipe, ffi) if repeat % 2 == 0 else (ffi, pipe)
            for case in CASES:
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
                        root, mode_env(root), logs / f"{label}-measure",
                    )
                    actual = inventory(root, package)
                    assert_inventory(actual, expected[case], label)
                    record = json.loads(sample.read_text())
                    record.update(fixture=package, lane=root.name, case=case, outputs=len(actual))
                    records.append(record)
                    print(f"{label}: {record['wall_ms']:.1f} ms, {len(actual)} outputs match stock",
                          flush=True)

        for root in (pipe, ffi):
            restore(root, fixture)
            run(commands[root], root, mode_env(root), logs / f"{package}-{root.name}-restore-metrics")
            edit(root, "broad")
            run(
                commands[root], root, dict(mode_env(root), BUILD_RUNNER_ACCELERATOR_METRICS="1"),
                logs / f"{package}-{root.name}-broad-metrics",
            )
            assert_inventory(inventory(root, package), expected["broad"], f"{package} metrics")
        check_worker_boundary(package, fixture, pipe, ffi, commands, mode_env, logs, expected)

    (results / "samples.json").write_text(json.dumps(records, indent=2) + "\n")
    for package in args.fixtures:
        for case in CASES:
            for lane in ("pipe", "ffi"):
                subset = [
                    s for s in records
                    if s["fixture"] == package and s["case"] == case and s["lane"] == lane
                ]
                wall = statistics.median(s["wall_ms"] for s in subset)
                rss = statistics.median(s["maxrss"] for s in subset)
                print(f"{package} {case} {lane}: {wall:.1f} ms, maxrss {rss:.0f} KiB")


if __name__ == "__main__":
    main()
