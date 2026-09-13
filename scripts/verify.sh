#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
cargo_bin=$(resolve_toolchain_cargo)
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
results_dir=$(mktemp -d)
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

prepare_rust_binary() {
  if [[ -n "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
    [[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
      fail "BUILD_RUNNER_ACCELERATOR_BIN is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"
    return 0
  fi
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  local binary="$repo_root/rust/target/debug/build_runner_accelerator"
  [[ -x "$binary" ]] || fail "Rust frontend binary was not built: $binary"
  export BUILD_RUNNER_ACCELERATOR_BIN="$binary"
}

prepare_rust_binary

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
  CASE_FILTER="$case_name" bash "$script_dir/correctness_json_serializable.sh" \
    >"$results_dir/$case_name.log" 2>&1
}

run_cases() {
  local -a cases=("$@")
  local case_name
  for case_name in "${cases[@]}"; do
    printf 'verify: correctness: start %s\n' "$case_name"
    if run_case "$case_name"; then
      grep -E '^correctness: ' "$results_dir/$case_name.log" || true
    else
      printf '%s\n' "--- $case_name ---" >&2
      sed -n '1,220p' "$results_dir/$case_name.log" >&2
      return 1
    fi
  done
}

run_freezed_correctness() {
  printf 'verify: correctness: start freezed\n'
  if CASE_FILTER=all bash "$script_dir/correctness_freezed.sh" \
    >"$results_dir/freezed.log" 2>&1; then
    grep -E '^freezed-correctness: ' "$results_dir/freezed.log" || true
  else
    printf '%s\n' '--- freezed ---' >&2
    sed -n '1,240p' "$results_dir/freezed.log" >&2
    return 1
  fi
}

run_built_value_correctness() {
  printf 'verify: correctness: start built_value\n'
  if bash "$script_dir/correctness_built_value.sh" \
    >"$results_dir/built_value.log" 2>&1; then
    grep -E '^built-value-correctness: ' "$results_dir/built_value.log" || true
  else
    printf '%s\n' '--- built_value ---' >&2
    sed -n '1,240p' "$results_dir/built_value.log" >&2
    return 1
  fi
}

run_riverpod_correctness() {
  printf 'verify: correctness: start riverpod\n'
  if CASE_FILTER=all bash "$script_dir/correctness_riverpod.sh" \
    >"$results_dir/riverpod.log" 2>&1; then
    grep -E '^riverpod-correctness: ' "$results_dir/riverpod.log" || true
  else
    printf '%s\n' '--- riverpod ---' >&2
    sed -n '1,240p' "$results_dir/riverpod.log" >&2
    return 1
  fi
}

run_script_probe() {
  local probe_name=$1
  local script_name=$2
  local output_prefix=$3
  local log="$results_dir/$probe_name.log"
  printf 'verify: compatibility: start %s\n' "$probe_name"
  if bash "$script_dir/$script_name" >"$log" 2>&1; then
    grep -F -- "$output_prefix" "$log" || {
      printf 'missing expected output: %s\n' "$output_prefix" >&2
      return 1
    }
  else
    printf '%s\n' "--- $probe_name ---" >&2
    sed -n '1,260p' "$log" >&2
    return 1
  fi
}

run_quick() {
  printf 'verify: level=quick\n'
  (cd "$repo_root/dart_worker" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get)
  (cd "$repo_root" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics analyze dart_worker)
  bash "$script_dir/smoke.sh"
  if [[ "${VERIFY_ARBITRARY_BUILDER:-0}" == 1 ]]; then
    bash "$script_dir/correctness_arbitrary_builder.sh"
  fi
  if [[ "${VERIFY_WATCH:-0}" == 1 ]]; then
    bash "$script_dir/watch_smoke.sh"
    bash "$script_dir/watch_smoke_freezed.sh"
    bash "$script_dir/watch_smoke_riverpod.sh"
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
  run_script_probe post-process correctness_post_process_builder.sh 'post-process-builder:'
  run_script_probe post-process-watch watch_smoke_post_process_builder.sh 'post-process-builder-watch:'
}

run_compatibility_graph_suite() {
  run_script_probe target-cycle correctness_target_cycle.sh 'target-cycle:'
  run_script_probe dependency-target correctness_arbitrary_dependency_target.sh 'arbitrary-dependency-target:'
  run_script_probe applies-builders correctness_applies_builder.sh 'applies-builders:'
}

run_compatibility_mapping_suite() {
  run_script_probe capture correctness_capture_builder.sh 'capture-builder:'
  run_script_probe multi-mapping correctness_multi_mapping_builder.sh 'multi-mapping-builder:'
  run_script_probe drift correctness_drift.sh 'drift-compatibility:'
}

run_full() {
  local -a suites
  local suite
  local selected
  if ! selected=$(select_full_suites "$verify_full_suites"); then
    fail 'invalid VERIFY_FULL_SUITES selection'
  fi
  mapfile -t suites <<<"$selected"
  printf 'verify: level=full suites=%s\n' "$(IFS=,; printf '%s' "${suites[*]}")"
  for suite in "${suites[@]}"; do
    printf 'verify: suite: start %s\n' "$suite"
    case "$suite" in
      core)
        run_core_suite
        ;;
      current-codegen)
        run_current_codegen_suite
        ;;
      compatibility-lifecycle)
        run_compatibility_lifecycle_suite
        ;;
      compatibility-graph)
        run_compatibility_graph_suite
        ;;
      compatibility-mapping)
        run_compatibility_mapping_suite
        ;;
    esac
    printf 'verify: suite: pass %s\n' "$suite"
  done
  if [[ "${VERIFY_BENCHMARK:-0}" == 1 ]]; then
    COUNT=${VERIFY_COUNT:-10} JOBS=${VERIFY_BENCHMARK_JOBS:-1} \
      bash "$script_dir/benchmark_json_serializable.sh"
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
