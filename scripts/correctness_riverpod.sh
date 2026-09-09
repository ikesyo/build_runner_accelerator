#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
cargo_bin=${CARGO_BIN:-"$repo_root/.toolchains/cargo/bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
fixture_dir="$repo_root/fixtures/riverpod_app"
results_dir=$(mktemp -d)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/fast-build-riverpod-root.XXXXXX")
test_fixtures_dir="$test_root/fixtures"
mkdir -p "$test_fixtures_dir"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
case_filter=${CASE_FILTER:-all}
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
  if [[ "${KEEP_TEMP:-0}" == 1 ]]; then
    printf 'riverpod-correctness: keeping temp workspace %s\n' "$test_root" >&2
    return 0
  fi
  for path in "${cleanup_paths[@]}"; do
    remove_tree "$path"
  done
  find "$test_root" -maxdepth 1 -type l -name dart_worker -delete
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT

fail() {
  printf 'riverpod-correctness: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" && ! -x "$cargo_bin" ]]; then
  fail "Cargo executable not found: $cargo_bin"
fi

prepare_rust_binary() {
  if [[ -n "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
    [[ -x "$FAST_BUILD_RUNNER_BIN" ]] || \
      fail "FAST_BUILD_RUNNER_BIN is not executable: $FAST_BUILD_RUNNER_BIN"
    return 0
  fi
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  FAST_BUILD_RUNNER_BIN="$repo_root/rust/target/debug/fast_build_runner"
  export FAST_BUILD_RUNNER_BIN
  [[ -x "$FAST_BUILD_RUNNER_BIN" ]] || fail 'Rust frontend binary was not built'
}

prepare_rust_binary

new_package_dir() {
  local role=$1
  local directory
  directory=$(mktemp -d "$test_fixtures_dir/fast-build-riverpod-${role}.XXXXXX")
  cleanup_paths+=("$directory")
  printf '%s\n' "$directory"
}

prepare_package() {
  local directory=$1
  local package_name=$2
  mkdir -p "$directory/lib"
  sed "s/^name: .*/name: $package_name/" \
    "$fixture_dir/pubspec.yaml" >"$directory/pubspec.yaml"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  cp "$fixture_dir/lib/secondary.dart" "$directory/lib/secondary.dart"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null)
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs >"$log" 2>&1)
}

run_rust() {
  local directory=$1
  local log=$2
  (cd "$repo_root" && \
    PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      FAST_BUILD_RUNNER_BIN="$FAST_BUILD_RUNNER_BIN" \
      "$repo_root/scripts/run_rust_frontend.sh" \
      build --root "$directory" --dart "$dart_bin" --jobs 1 >"$log" 2>&1)
}

assert_contains() {
  local file=$1
  local expected=$2
  rg -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
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
    "$2/.dart_tool/fast_build_runner/cache/$rust_package_name/lib/model.riverpod.g.part"
  assert_same_file \
    "$1/.dart_tool/build/generated/$stock_package_name/lib/model.json_serializable.g.part" \
    "$2/.dart_tool/fast_build_runner/cache/$rust_package_name/lib/model.json_serializable.g.part"
  assert_same_file \
    "$1/.dart_tool/build/generated/$stock_package_name/lib/secondary.riverpod.g.part" \
    "$2/.dart_tool/fast_build_runner/cache/$rust_package_name/lib/secondary.riverpod.g.part"
  assert_same_file "$1/lib/secondary.g.dart" "$2/lib/secondary.g.dart"
}

assert_actions() {
  assert_contains "$1" "Rust frontend: $2 build action(s)"
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
  assert_actions "$results_dir/$name.rust.initial.log" 7
  cp "$rust_dir/.dart_tool/fast_build_runner/graph-v3.bin" \
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
  assert_actions "$results_dir/$name.rust.change.log" 4
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
    "$rust_dir/.dart_tool/fast_build_runner/cache/$rust_package_name/lib/model.riverpod.g.part" \
    "$stock_dir/.dart_tool/build/generated/$stock_package_name/lib/model.json_serializable.g.part" \
    "$rust_dir/.dart_tool/fast_build_runner/cache/$rust_package_name/lib/model.json_serializable.g.part" \
    "$stock_dir/.dart_tool/build/generated/$stock_package_name/lib/secondary.riverpod.g.part" \
    "$rust_dir/.dart_tool/fast_build_runner/cache/$rust_package_name/lib/secondary.riverpod.g.part" \
    "$stock_dir/lib/secondary.g.dart" "$rust_dir/lib/secondary.g.dart"
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_outputs "$stock_dir" "$rust_dir"
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
    "$rust_dir/.dart_tool/fast_build_runner/graph-v3.bin" || \
    fail 'Rust graph changed after failed Riverpod build'
  assert_same_file "$results_dir/$name.model.before.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" 'error'
  printf 'riverpod-correctness: failure-rollback-and-diagnostic: pass\n'
}

run_selected() {
  local name=$1
  shift
  if [[ "$case_filter" == all || "$case_filter" == "$name" ]]; then
    "$@"
  fi
}

run_selected no-op run_case_noop
run_selected source-edit run_case_source_edit
run_selected generated-output-delete run_case_generated_output_delete
run_selected failure run_case_failure

printf 'riverpod-correctness: cases=%s pass\n' "$case_filter"
