#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/arbitrary_dependency_app"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"

remove_tree() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" ]]; then
    rm -f -- "$path"
    return 0
  fi
  find "$path" -depth -type f -delete
  find "$path" -depth -type l -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'arbitrary-dependency: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,220p' "$log" >&2
    fi
  done
  exit 1
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,180p' "$file" >&2
    fail "${file##*/} does not contain: $expected"
  }
}

assert_no_file() {
  local path=$1
  [[ ! -e "$path" ]] || fail "unexpected file: $path"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

worker_ensure_frontend || fail 'Rust frontend build failed'

worker_prepare >/dev/null || fail 'worker pub get failed'

mkdir -p "$fixture_root"
worker_attach "$workspace_root"

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$repo_root/fixtures/arbitrary_builder_app/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/dependency_builder.dart" "$directory/lib/dependency_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" || \
    fail "pub get failed for $directory"
}

prepare_package "$stock_dir"
prepare_package "$rust_dir"

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
    build --root "$directory" --dart "$dart_bin"
}
run_required() {
  local label=$1
  shift
  if ! "$@"; then
    fail "$label failed"
  fi
}

run_required 'stock initial build' \
  run_stock "$stock_dir" "$temporary_dir/stock.initial.log"
run_required 'Rust initial build' \
  run_rust "$rust_dir" "$temporary_dir/rust.initial.log"
assert_same_file "$stock_dir/lib/input.summary.txt" "$rust_dir/lib/input.summary.txt"
assert_contains "$rust_dir/lib/input.summary.txt" 'hello seed summary'
assert_contains "$temporary_dir/rust.initial.log" 'Rust frontend: 2 build action(s)'
rust_cache="$rust_dir/.dart_tool/build_runner_accelerator/cache/arbitrary_dependency_app/lib/input.seed.txt"
[[ -f "$rust_cache" ]] || fail 'Rust cache output was not committed'

run_required 'Rust no-op build' \
  run_rust "$rust_dir" "$temporary_dir/rust.no-op.log"
assert_contains "$temporary_dir/rust.no-op.log" 'No work to do (Rust frontend)'

printf 'changed\n' >"$stock_dir/lib/input.txt"
printf 'changed\n' >"$rust_dir/lib/input.txt"
run_required 'stock input-change build' \
  run_stock "$stock_dir" "$temporary_dir/stock.input-change.log"
run_required 'Rust input-change build' \
  run_rust "$rust_dir" "$temporary_dir/rust.input-change.log"
assert_same_file "$stock_dir/lib/input.summary.txt" "$rust_dir/lib/input.summary.txt"
assert_contains "$rust_dir/lib/input.summary.txt" 'changed seed summary'
assert_contains "$temporary_dir/rust.input-change.log" 'Rust frontend: 2 build action(s)'

find "$stock_dir/.dart_tool/build" -type f -name 'input.seed.txt' -delete
rm -f -- "$rust_cache"
run_required 'stock cache-missing build' \
  run_stock "$stock_dir" "$temporary_dir/stock.cache-missing.log"
run_required 'Rust cache-missing build' \
  run_rust "$rust_dir" "$temporary_dir/rust.cache-missing.log"
assert_same_file "$stock_dir/lib/input.summary.txt" "$rust_dir/lib/input.summary.txt"
assert_contains "$temporary_dir/rust.cache-missing.log" 'Rust frontend: 2 build action(s)'
[[ -f "$rust_cache" ]] || fail 'Rust cache output was not restored'

printf 'arbitrary-dependency: cache-output=yes required-input=yes phase-order=yes recovery=yes\n'
