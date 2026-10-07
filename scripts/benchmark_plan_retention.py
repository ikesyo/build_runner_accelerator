#!/usr/bin/env python3
"""Compare the ignored Rust planning fixture; no Dart workers or IPC in timings."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile


TEST = "build::tests::planning_retention_benchmark"


def prepare_baseline(baseline, candidate):
    """Transplant just the common fixture/benchmark into a disposable main checkout."""
    tests = candidate / "rust/src/build/tests.rs"
    source = tests.read_text()
    start = source.index("// Shared fixture for identity")
    regression = source.index("#[test]\nfn planned_actions_share", start)
    benchmark = source.index('#[test]\n#[ignore = "isolated comparison', regression)
    target = baseline / "rust/src/build/tests.rs"
    if TEST.split("::")[-1] in target.read_text():
        raise ValueError("baseline already contains benchmark; use a fresh disposable checkout")
    with target.open("a") as output:
        output.write("\n" + source[start:regression] + source[benchmark:].replace("spec.instance.", "spec."))
    execution = (candidate / "rust/src/build/execution.rs").read_text()
    start = execution.index("pub(super) fn optional_specs_by_output")
    end = execution.index("/// Return the order", start)
    with (baseline / "rust/src/build/execution.rs").open("a") as output:
        output.write("\n" + execution[start:end].replace("spec.instance.", "spec."))


def run(binary, inputs, dump=None, time_file=None):
    env = os.environ.copy()
    env.pop("PLAN_BENCH_DUMP", None)
    env["PLAN_BENCH_INPUTS"] = str(inputs)
    if dump:
        env["PLAN_BENCH_DUMP"] = str(dump)
    command = [str(binary), TEST, "--exact", "--ignored", "--nocapture", "--test-threads=1"]
    if time_file:
        # A fresh wrapper keeps RUSAGE_CHILDREN's high-water mark per run.
        wrapper = (
            "import json,resource,subprocess,sys; "
            "subprocess.run(sys.argv[2:],check=True); "
            "u=resource.getrusage(resource.RUSAGE_CHILDREN); "
            "open(sys.argv[1],'w').write(json.dumps([u.ru_utime,u.ru_stime,u.ru_maxrss]))"
        )
        command = [sys.executable, "-c", wrapper, str(time_file)] + command
    completed = subprocess.run(command, env=env, check=True, capture_output=True, text=True)
    match = re.search(r"planning_us=(\d+) planning_dirty_index_us=(\d+)", completed.stderr)
    if not match:
        raise ValueError("test did not report planning measurements")
    result = dict(zip(("planning_us", "planning_dirty_index_us"), map(int, match.groups())))
    if time_file:
        user, system, rss = json.loads(time_file.read_text())
        result.update(cpu_s=user + system, max_rss_kib=int(rss))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-baseline", type=Path)
    parser.add_argument("--candidate-checkout", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--baseline-bin", type=Path)
    parser.add_argument("--candidate-bin", type=Path)
    parser.add_argument("--inputs", type=int, nargs="+", default=[20, 5000])
    parser.add_argument("--repeats", type=int, default=7)
    args = parser.parse_args()
    if args.prepare_baseline:
        prepare_baseline(args.prepare_baseline.resolve(), args.candidate_checkout.resolve())
        return
    if not args.baseline_bin or not args.candidate_bin or args.repeats < 1 or min(args.inputs) < 1:
        parser.error("provide both test binaries, positive inputs and repeats")
    binaries = {"main": args.baseline_bin.resolve(), "candidate": args.candidate_bin.resolve()}
    with tempfile.TemporaryDirectory(prefix="plan-retention-") as temporary:
        root = Path(temporary)
        for inputs in args.inputs:
            # Equality passes are untimed; timed passes do not serialize plans.
            dumps = []
            for lane, binary in binaries.items():
                dump = root / f"{lane}.jsonl"
                run(binary, inputs, dump=dump)
                dumps.append(dump.read_bytes())
            if dumps[0] != dumps[1]:
                raise ValueError(f"plan/dirty/index mismatch for {inputs} inputs")
            samples = {lane: [] for lane in binaries}
            for repeat in range(args.repeats):
                order = list(binaries) if repeat % 2 == 0 else list(reversed(binaries))
                for lane in order:
                    samples[lane].append(run(binaries[lane], inputs, time_file=root / "time.txt"))
            summary = {lane: {key: {"median": statistics.median(row[key] for row in rows),
                                     "min": min(row[key] for row in rows),
                                     "max": max(row[key] for row in rows)}
                              for key in rows[0]} for lane, rows in samples.items()}
            print(json.dumps({"inputs": inputs, "actions": inputs * 4, "equal": True,
                              "repeats": args.repeats, "summary": summary, "samples": samples}))


if __name__ == "__main__":
    main()
