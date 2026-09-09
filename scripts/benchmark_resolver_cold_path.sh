#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
results_dir=$(mktemp -d "${TMPDIR:-/tmp}/fast-build-resolver-cold-path.XXXXXX")

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() { remove_tree "$results_dir"; }
trap cleanup EXIT

run_benchmark() {
  local label=$1
  local script=$2
  local log="$results_dir/$label.log"
  local benchmark_jobs=${JOBS:-1}

  JOBS="$benchmark_jobs" FAST_BUILD_RUNNER_METRICS=1 "$script_dir/$script" >"$log" 2>&1
  local cold_metrics
  cold_metrics=$(rg '^Dart resolver metrics: ' "$log" || true)
  if [[ -z "$cold_metrics" ]]; then
    printf 'resolver-cold-path-benchmark: %s metrics not found\n' "$label" >&2
    cat "$log" >&2
    return 1
  fi
  local observation_count
  observation_count=$(printf '%s\n' "$cold_metrics" | wc -l | tr -d ' ')
  printf '%s jobs=%s resolver_observations=%s\n' \
    "$label" "$benchmark_jobs" "$observation_count"
  printf '%s\n' "$cold_metrics"
}

run_benchmark freezed benchmark_freezed.sh
run_benchmark riverpod benchmark_riverpod.sh
