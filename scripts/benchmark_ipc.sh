#!/usr/bin/env bash
set -euo pipefail

# Run the existing current-JSON benchmark with the opt-in IPC timings and
# summarize the Rust transport and Dart asset-RPC measurements. This keeps the
# FFI investigation on the same fixture and warm-up protocol as the published
# baseline benchmark.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-}
results_dir=${RESULTS_DIR:-}
cases=${CASES:-"no-op one-file broad"}
repeat_count=${REPEATS:-3}
jobs=${ACCELERATOR_JOBS:-1}
launcher=${ACCELERATOR_LAUNCHER:-0}
shared_memory=${BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY:-0}

fail() {
  printf 'benchmark-ipc: FAIL: %s\n' "$*" >&2
  exit 1
}

if [[ -z "$results_dir" ]]; then
  results_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-ipc.XXXXXX")
else
  mkdir -p "$results_dir"
  results_dir=$(cd -- "$results_dir" && pwd)
fi

if [[ -z "$dart_bin" ]]; then
  # shellcheck source=scripts/toolchain.sh
  source "$script_dir/toolchain.sh"
  dart_bin=$(resolve_toolchain_dart)
fi

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ "$repeat_count" =~ ^[1-9][0-9]*$ ]] ||
  fail "REPEATS must be a positive integer: $repeat_count"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] ||
  fail "ACCELERATOR_JOBS must be a positive integer: $jobs"
[[ "$launcher" == 0 || "$launcher" == 1 ]] ||
  fail "ACCELERATOR_LAUNCHER must be 0 or 1: $launcher"
[[ "$shared_memory" == 0 || "$shared_memory" == 1 ]] ||
  fail "BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY must be 0 or 1: $shared_memory"

run_log="$results_dir/benchmark.log"
printf 'benchmark-ipc: cases=%s repeats=%s jobs=%s launcher=%s shared_memory=%s\n' \
  "$cases" "$repeat_count" "$jobs" "$launcher" "$shared_memory"
printf 'benchmark-ipc: results=%s\n' "$results_dir"

if ! (
  export BUILD_RUNNER_ACCELERATOR_METRICS=1
  export DART_BIN="$dart_bin"
  export RESULTS_DIR="$results_dir/raw"
  export CASES="$cases"
  export REPEATS="$repeat_count"
  export LANE=accelerator
  export ACCELERATOR_JOBS="$jobs"
  export ACCELERATOR_LAUNCHER="$launcher"
  export BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY="$shared_memory"
  bash "$script_dir/benchmark_current_baseline.sh"
) >"$run_log" 2>&1; then
  cat "$run_log" >&2
  fail "current baseline benchmark failed; raw results are in $results_dir/raw"
fi

cat "$run_log"
python3 "$script_dir/summarize_ipc_metrics.py" "$results_dir/raw"
