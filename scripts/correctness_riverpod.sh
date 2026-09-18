#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/riverpod_app"
results_dir=$(mktemp -d)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-riverpod-root.XXXXXX")
test_fixtures_dir="$test_root/fixtures"
mkdir -p "$test_fixtures_dir"
worker_attach "$test_root"
case_filter=${CASE_FILTER:-all}
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi
cleanup_paths=()
stock_dir=
rust_dir=
stock_package_name=
rust_package_name=

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  if [[ "${KEEP_TEMP:-0}" == 1 ]]; then
    printf 'riverpod-correctness: keeping temp workspace %s\n' "$test_root" >&2
    return 0
  fi
  for path in "${cleanup_paths[@]}"; do
    remove_tree "$path"
  done
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT

fail() {
  printf 'riverpod-correctness: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

new_package_dir() {
  local role=$1
  local directory
  directory=$(mktemp -d "$test_fixtures_dir/build-runner-accelerator-riverpod-${role}.XXXXXX")
  cleanup_paths+=("$directory")
  printf '%s\n' "$directory"
}

prepare_package() {
  local directory=$1
  local package_name=$2
  mkdir -p "$directory/lib"
  sed "s/^name: .*/name: $package_name/" \
    "$fixture_dir/pubspec.yaml" >"$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  cp "$fixture_dir/lib/secondary.dart" "$directory/lib/secondary.dart"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}"
}

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
}
run_rust() {
  local directory=$1
  local log=$2
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend \
    build --root "$directory" --dart "$dart_bin" --jobs 1
}
assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_outputs() {
  assert_same_file "$1/lib/model.freezed.dart" "$2/lib/model.freezed.dart"
  assert_same_file "$1/lib/model.g.dart" "$2/lib/model.g.dart"
  assert_same_file \
    "$1/.dart_tool/build/generated/$stock_package_name/lib/model.riverpod.g.part" \
    "$2/.dart_tool/build_runner_accelerator/cache/$rust_package_name/lib/model.riverpod.g.part"
  assert_same_file \
    "$1/.dart_tool/build/generated/$stock_package_name/lib/model.json_serializable.g.part" \
    "$2/.dart_tool/build_runner_accelerator/cache/$rust_package_name/lib/model.json_serializable.g.part"
  assert_same_file \
    "$1/.dart_tool/build/generated/$stock_package_name/lib/secondary.riverpod.g.part" \
    "$2/.dart_tool/build_runner_accelerator/cache/$rust_package_name/lib/secondary.riverpod.g.part"
  assert_same_file "$1/lib/secondary.g.dart" "$2/lib/secondary.g.dart"
}

assert_actions() {
  local file=$1
  local expected=$2
  local actual
  if grep -Fq -- "Rust frontend: $expected build action(s)" "$file"; then
    return 0
  fi
  actual=$(grep -F 'Rust frontend:' "$file" | tail -n 1 || true)
  fail "${file##*/} does not contain: Rust frontend: $expected build action(s); observed: ${actual:-<none>}"
}

setup_case() {
  local name=$1
  local prefix="fast_build_riverpod_${name//-/_}"
  stock_package_name="${prefix}_stock"
  rust_package_name="${prefix}_rust"
  stock_dir=$(new_package_dir "${name}-stock")
  rust_dir=$(new_package_dir "${name}-rust")
  prepare_package "$stock_dir" "$stock_package_name"
  prepare_package "$rust_dir" "$rust_package_name"
  run_stock "$stock_dir" "$results_dir/$name.stock.initial.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.initial.log"
  assert_outputs "$stock_dir" "$rust_dir"
  # Follow build_runner's findBuilderOrder: applies_builders selects a
  # consumer but does not add a synthetic phase edge. Generated-input
  # dependencies still drive the phase-aware actions, which total nine for
  # this fixture.
  assert_actions "$results_dir/$name.rust.initial.log" 9
  cp "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" \
    "$results_dir/$name.graph.before.bin"
  cp "$rust_dir/lib/model.g.dart" "$results_dir/$name.model.before.g.dart"
}

run_case_noop() {
  local name=noop
  setup_case "$name"
  run_rust "$rust_dir" "$results_dir/$name.rust.noop.log"
  assert_contains "$results_dir/$name.rust.noop.log" 'No work to do (Rust frontend)'
  printf 'riverpod-correctness: no-op: pass\n'
}

run_case_source_edit() {
  local name=source-edit
  setup_case "$name"
  sed -i 's/=> 42;/=> 43;/' "$stock_dir/lib/model.dart"
  sed -i 's/=> 42;/=> 43;/' "$rust_dir/lib/model.dart"
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_outputs "$stock_dir" "$rust_dir"
  # The same generic phase ordering reduces the dirty generated-input batch
  # to five native actions while preserving the stock output inventory.
  assert_actions "$results_dir/$name.rust.change.log" 5
  cmp -s "$results_dir/$name.model.before.g.dart" "$rust_dir/lib/model.g.dart" && \
    fail 'source edit did not change Riverpod output'
  printf 'riverpod-correctness: source-edit-and-invalidation: pass\n'
}

run_case_generated_output_delete() {
  local name=generated-output-delete
  setup_case "$name"
  rm -f -- "$stock_dir/lib/model.freezed.dart" "$rust_dir/lib/model.freezed.dart" \
    "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart" \
    "$stock_dir/.dart_tool/build/generated/$stock_package_name/lib/model.riverpod.g.part" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/$rust_package_name/lib/model.riverpod.g.part" \
    "$stock_dir/.dart_tool/build/generated/$stock_package_name/lib/model.json_serializable.g.part" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/$rust_package_name/lib/model.json_serializable.g.part" \
    "$stock_dir/.dart_tool/build/generated/$stock_package_name/lib/secondary.riverpod.g.part" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/$rust_package_name/lib/secondary.riverpod.g.part" \
    "$stock_dir/lib/secondary.g.dart" "$rust_dir/lib/secondary.g.dart"
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_outputs "$stock_dir" "$rust_dir"
  # Rebuilding the deleted generated outputs now takes seven actions under
  # the same official phase ordering.
  assert_actions "$results_dir/$name.rust.change.log" 7
  printf 'riverpod-correctness: generated-output-delete: pass\n'
}

run_case_failure() {
  local name=failure
  setup_case "$name"
  sed -i 's/=> 42;/=> ;/' "$stock_dir/lib/model.dart"
  sed -i 's/=> 42;/=> ;/' "$rust_dir/lib/model.dart"
  if run_stock "$stock_dir" "$results_dir/$name.stock.change.log"; then
    fail 'stock failure unexpectedly succeeded'
  fi
  if run_rust "$rust_dir" "$results_dir/$name.rust.change.log"; then
    fail 'Rust failure unexpectedly succeeded'
  fi
  cmp "$results_dir/$name.graph.before.bin" \
    "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" || \
    fail 'Rust graph changed after failed Riverpod build'
  assert_same_file "$results_dir/$name.model.before.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" 'error'
  printf 'riverpod-correctness: failure-rollback-and-diagnostic: pass\n'
}

run_selected() {
  local name=$1
  shift
  if [[ "$case_filter" == all || "$case_filter" == "$name" ]]; then
    verification_run_case "riverpod/$name" "$@"
  fi
}

run_selected no-op run_case_noop
run_selected source-edit run_case_source_edit
run_selected generated-output-delete run_case_generated_output_delete
run_selected failure run_case_failure

printf 'riverpod-correctness: cases=%s pass\n' "$case_filter"
