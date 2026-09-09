#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
count=${COUNT:-10}
jobs=${JOBS:-1}
builders=${BUILDERS:-json,freezed,riverpod}
metrics=${BUILD_RUNNER_ACCELERATOR_METRICS:-1}
repeat=${REPEAT:-1}
results_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-benchmark-matrix.XXXXXX")
trap 'find "$results_dir" -depth -type f -delete; find "$results_dir" -depth -type d -empty -delete' EXIT

fail() {
  printf 'benchmark-matrix: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$repeat" =~ ^[1-9][0-9]*$ ]] || fail "REPEAT must be a positive integer: $repeat"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" && -x "$repo_root/rust/target/debug/build_runner_accelerator" ]]; then
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi

run_builder() {
  local builder=$1
  case "$builder" in
    json)
      COUNT="$count" JOBS="$jobs" BUILD_RUNNER_ACCELERATOR_METRICS="$metrics" \
        bash "$script_dir/benchmark_json_serializable.sh"
      ;;
    freezed)
      JOBS="$jobs" BUILD_RUNNER_ACCELERATOR_METRICS="$metrics" \
        bash "$script_dir/benchmark_freezed.sh"
      ;;
    riverpod)
      JOBS="$jobs" BUILD_RUNNER_ACCELERATOR_METRICS="$metrics" \
        bash "$script_dir/benchmark_riverpod.sh"
      ;;
    *)
      fail "unknown builder: $builder"
      ;;
  esac
}

IFS=',' read -r -a selected_builders <<<"$builders"
((${#selected_builders[@]} > 0)) || fail 'BUILDERS is empty'

printf 'benchmark-matrix: jobs=%s json_count=%s metrics=%s builders=%s\n' \
  "$jobs" "$count" "$metrics" "$builders"
for iteration in $(seq 1 "$repeat"); do
  printf 'benchmark-matrix: iteration=%s/%s\n' "$iteration" "$repeat"
  for builder in "${selected_builders[@]}"; do
    builder=${builder//[[:space:]]/}
    [[ -n "$builder" ]] || fail 'BUILDERS contains an empty item'
    log_path="$results_dir/${builder}-${iteration}.log"
    printf 'benchmark-matrix: start builder=%s iteration=%s\n' "$builder" "$iteration"
    if ! run_builder "$builder" >"$log_path" 2>&1; then
      cat "$log_path" >&2
      fail "benchmark failed: $builder iteration=$iteration"
    fi
    printf 'benchmark-matrix: builder=%s iteration=%s timing\n' "$builder" "$iteration"
    rg '^(stock|rust)_[^ ]+ real=' "$log_path" || true
    if [[ "$metrics" == 1 ]]; then
      printf 'benchmark-matrix: builder=%s iteration=%s runtime-metrics\n' "$builder" "$iteration"
      rg '^(Dart resolver metrics:|Dart metrics:|Rust (metrics|filesystem metrics|graph metrics|workspace metrics):)' \
        "$log_path" || true
    fi
  done
done

printf 'benchmark-matrix: pass\n'
