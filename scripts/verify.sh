#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
results_dir=${VERIFY_RESULTS_DIR:-$(mktemp -d)}
: "${VERIFY_STREAM_LOGS:=1}"
verify_level=${VERIFY_LEVEL:-quick}
verify_cases=${VERIFY_CASES:-failure,conditional-dependency}
verify_full_suites=${VERIFY_FULL_SUITES:-all}

full_suites=(
  core
  current-codegen
  compatibility-lifecycle
  compatibility-graph
  compatibility-mapping
)

all_cases=(
  generated-output-delete
  input-delete
  rename
  failure
  affected-actions
  generate-for
  builder-options
  glob-membership
  conditional-dependency
  empty-options
)

cleanup() {
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining full-verification logs: %s\n' "$results_dir" >&2
    return 0
  fi
  [[ -d "$results_dir" ]] || return 0
  find "$results_dir" -depth -type f -delete
  find "$results_dir" -depth -type d -empty -delete
}
trap cleanup EXIT

fail() {
  printf 'verify: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ "$verify_level" == full && "${VERIFY_FULL_TIMEOUT_GUARD:-0}" != 1 ]]; then
  full_timeout=$(verification_timeout_seconds VERIFY_FULL_TIMEOUT_SECONDS 3600) || exit 2
  full_log=${VERIFY_FULL_LOG:-$results_dir/full-verification.log}
  if VERIFY_WORKSPACE="$repo_root" VERIFY_FULL_TIMEOUT_GUARD=1 verification_run_command "full-verification" "$full_timeout" "$full_log" env VERIFY_FULL_TIMEOUT_GUARD=1 bash "$script_dir/verify.sh" "$@"; then
    exit 0
  else
    exit $?
  fi
fi

worker_ensure_frontend || fail 'Rust frontend build failed'

is_known_case() {
  local wanted=$1
  local known
  for known in "${all_cases[@]}"; do
    [[ "$wanted" == "$known" ]] && return 0
  done
  return 1
}

select_cases() {
  local raw=$1
  local item
  local -a requested
  if [[ "$raw" == all ]]; then
    printf '%s\n' "${all_cases[@]}"
    return 0
  fi

  IFS=',' read -r -a requested <<<"$raw"
  ((${#requested[@]} > 0)) || fail 'VERIFY_CASES is empty'
  for item in "${requested[@]}"; do
    item=${item//[[:space:]]/}
    [[ -n "$item" ]] || fail "VERIFY_CASES contains an empty case"
    is_known_case "$item" || fail "unknown correctness case: $item"
    printf '%s\n' "$item"
  done
}

is_known_full_suite() {
  local wanted=$1
  local known
  for known in "${full_suites[@]}"; do
    [[ "$wanted" == "$known" ]] && return 0
  done
  return 1
}

select_full_suites() {
  local raw=$1
  local item
  local -a requested
  if [[ "$raw" == all ]]; then
    printf '%s\n' "${full_suites[@]}"
    return 0
  fi

  IFS=',' read -r -a requested <<<"$raw"
  ((${#requested[@]} > 0)) || fail 'VERIFY_FULL_SUITES is empty'
  for item in "${requested[@]}"; do
    item=${item//[[:space:]]/}
    [[ -n "$item" ]] || fail "VERIFY_FULL_SUITES contains an empty suite"
    is_known_full_suite "$item" || fail "unknown full verification suite: $item"
    printf '%s\n' "$item"
  done
}

run_case() {
  local case_name=$1
  local log="$results_dir/$case_name.log"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_CASE_TIMEOUT_SECONDS 1200) || return 2
  verification_run_command_in_dir "$repo_root" "case/json/$case_name" "$log" "$timeout_seconds" env CASE_FILTER="$case_name" bash "$script_dir/correctness_json_serializable.sh"
}

run_cases() {
  local -a cases=("$@")
  local case_name
  for case_name in "${cases[@]}"; do
    if ! run_case "$case_name"; then
      printf '%s\n' "--- $case_name ---" >&2
      tail -n 160 "$results_dir/$case_name.log" >&2 || true
      return 1
    fi
  done
}

run_freezed_correctness() {
  local log="$results_dir/freezed.log"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_CASE_TIMEOUT_SECONDS 1200) || return 2
  verification_run_command_in_dir "$repo_root" "case/freezed" "$log" "$timeout_seconds" env CASE_FILTER=all bash "$script_dir/correctness_freezed.sh" || {
    printf '%s\n' "--- freezed ---" >&2
    tail -n 200 "$log" >&2 || true
    return 1
  }
}

run_built_value_correctness() {
  local log="$results_dir/built_value.log"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_CASE_TIMEOUT_SECONDS 1200) || return 2
  verification_run_command_in_dir "$repo_root" "case/built-value" "$log" "$timeout_seconds" env bash "$script_dir/correctness_built_value.sh" || {
    printf '%s\n' "--- built-value ---" >&2
    tail -n 200 "$log" >&2 || true
    return 1
  }
}

run_trigger_correctness() {
  local log="$results_dir/trigger_builder.log"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_CASE_TIMEOUT_SECONDS 1200) || return 2
  verification_run_command_in_dir "$repo_root" "case/trigger-builder" "$log" "$timeout_seconds" env bash "$script_dir/correctness_trigger_builder.sh" || {
    printf '%s\n' "--- trigger-builder ---" >&2
    tail -n 200 "$log" >&2 || true
    return 1
  }
}

run_riverpod_correctness() {
  local log="$results_dir/riverpod.log"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_CASE_TIMEOUT_SECONDS 1200) || return 2
  verification_run_command_in_dir "$repo_root" "case/riverpod" "$log" "$timeout_seconds" env CASE_FILTER=all bash "$script_dir/correctness_riverpod.sh" || {
    printf '%s\n' "--- riverpod ---" >&2
    tail -n 200 "$log" >&2 || true
    return 1
  }
}

run_script_probe() {
  local probe_name=$1
  local script_name=$2
  local output_prefix=$3
  local log="$results_dir/$probe_name.log"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_CASE_TIMEOUT_SECONDS 1200) || return 2
  if verification_run_command_in_dir "$repo_root" "case/$probe_name" "$log" "$timeout_seconds" bash "$script_dir/$script_name"; then
    grep -F -- "$output_prefix" "$log" || {
      printf 'missing expected output: %s\n' "$output_prefix" >&2
      return 1
    }
  else
    printf '%s\n' "--- $probe_name ---" >&2
    tail -n 200 "$log" >&2 || true
    return 1
  fi
}

run_quick() {
  printf 'verify: level=quick\n'
  worker_prepare
  (cd "$repo_root" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics analyze \
      lib bin test tool)
  bash "$script_dir/smoke.sh"
  run_trigger_correctness
  if [[ "${VERIFY_ARBITRARY_BUILDER:-0}" == 1 ]]; then
    bash "$script_dir/correctness_arbitrary_builder.sh"
  fi
  if [[ "${VERIFY_WATCH:-0}" == 1 ]]; then
    bash "$script_dir/watch_smoke.sh"
    bash "$script_dir/watch_smoke_freezed.sh"
    bash "$script_dir/watch_smoke_riverpod.sh"
    bash "$script_dir/watch_smoke_trigger_builder.sh"
  fi
}

run_targeted() {
  local -a cases
  mapfile -t cases < <(select_cases "$verify_cases")
  printf 'verify: level=targeted cases=%s\n' "$verify_cases"
  if ! run_cases "${cases[@]}"; then
    fail 'targeted correctness case failed'
  fi
}

run_core_suite() {
  local -a cases=("${all_cases[@]}")
  VERIFY_WATCH=0 run_quick
  run_script_probe watch watch_smoke.sh 'watch-smoke:'
  run_cases "${cases[@]}"
  run_built_value_correctness
}

run_current_codegen_suite() {
  run_freezed_correctness
  run_script_probe freezed-watch watch_smoke_freezed.sh 'freezed-watch-smoke:'
  run_riverpod_correctness
  run_script_probe riverpod-watch watch_smoke_riverpod.sh 'riverpod-watch-smoke:'
}

run_compatibility_lifecycle_suite() {
  run_script_probe lifetime correctness_lifetime_compatibility.sh 'lifetime-compatibility:'
  run_script_probe optional-builder correctness_optional_builder.sh 'optional-builder: PASS'
  run_script_probe post-process correctness_post_process_builder.sh 'post-process-builder:'
  run_script_probe post-process-watch watch_smoke_post_process_builder.sh 'post-process-builder-watch:'
  run_script_probe optional-builder-watch watch_smoke_optional_builder.sh 'optional-builder-watch:'
  run_script_probe trigger-builder-watch watch_smoke_trigger_builder.sh 'trigger-builder-watch:'
}

run_compatibility_graph_suite() {
  run_script_probe target-cycle correctness_target_cycle.sh 'target-cycle:'
  run_script_probe dependency-target correctness_arbitrary_dependency_target.sh 'arbitrary-dependency-target:'
  run_script_probe applies-builders correctness_applies_builder.sh 'applies-builders:'
}

run_compatibility_mapping_suite() {
  run_script_probe capture correctness_capture_builder.sh 'capture-builder:'
  run_script_probe multi-mapping correctness_multi_mapping_builder.sh 'multi-mapping-builder:'
  run_script_probe empty-input-mapping correctness_empty_input_mapping.sh 'empty-input-mapping:'
  run_script_probe empty-input-mapping-watch watch_smoke_empty_input_mapping.sh 'empty-input-mapping-watch:'
  run_script_probe drift correctness_drift.sh 'drift-compatibility:'
  run_script_probe drift-analyzer correctness_drift_analyzer.sh 'drift-analyzer-compatibility:'
  run_script_probe drift-analyzer-watch watch_smoke_drift_analyzer.sh 'drift-analyzer-watch:'
}

run_full() {
  local -a suites
  local suite
  local selected
  local suite_timeout
  local suite_log
  local suite_results_dir
  local suite_status
  if [[ -n "${VERIFY_SUITE_BODY:-}" ]]; then
    case "$VERIFY_SUITE_BODY" in
      core) run_core_suite ;;
      current-codegen) run_current_codegen_suite ;;
      compatibility-lifecycle) run_compatibility_lifecycle_suite ;;
      compatibility-graph) run_compatibility_graph_suite ;;
      compatibility-mapping) run_compatibility_mapping_suite ;;
      *) fail "unknown suite body: $VERIFY_SUITE_BODY" ;;
    esac
    return
  fi
  if ! selected=$(select_full_suites "$verify_full_suites"); then
    fail 'invalid VERIFY_FULL_SUITES selection'
  fi
  mapfile -t suites <<<"$selected"
  printf 'verify: level=full suites=%s\n' "$(IFS=,; printf '%s' "${suites[*]}")"
  suite_timeout=$(verification_timeout_seconds VERIFY_SUITE_TIMEOUT_SECONDS 1800) || return 2
  for suite in "${suites[@]}"; do
    suite_log="$results_dir/suite-$suite.log"
    suite_results_dir="$results_dir/suite-$suite"
    mkdir -p -- "$suite_results_dir"
    if VERIFY_WORKSPACE="$repo_root" verification_run_command "suite/$suite" "$suite_timeout" "$suite_log" env VERIFY_FULL_TIMEOUT_GUARD=1 VERIFY_SUITE_BODY="$suite" VERIFY_RESULTS_DIR="$suite_results_dir" bash "$script_dir/verify.sh"; then
      suite_status=0
    else
      suite_status=$?
    fi
    if ((suite_status != 0)); then
      printf 'verify: FAIL: full verification suite failed: %s (status=%s)\n' "$suite" "$suite_status" >&2
      return "$suite_status"
    fi
  done
  if [[ "${VERIFY_BENCHMARK:-0}" == 1 ]]; then
    COUNT=${VERIFY_COUNT:-10} JOBS=${VERIFY_BENCHMARK_JOBS:-1} bash "$script_dir/benchmark_json_serializable.sh"
    JOBS=${VERIFY_BENCHMARK_JOBS:-1} bash "$script_dir/benchmark_freezed.sh"
    JOBS=${VERIFY_BENCHMARK_JOBS:-1} bash "$script_dir/benchmark_riverpod.sh"
  fi
}

case "$verify_level" in
  quick)
    run_quick
    ;;
  targeted)
    run_targeted
    ;;
  full)
    run_full
    ;;
  *)
    fail "VERIFY_LEVEL must be quick, targeted, or full: $verify_level"
    ;;
esac

printf 'verify: pass level=%s\n' "$verify_level"
