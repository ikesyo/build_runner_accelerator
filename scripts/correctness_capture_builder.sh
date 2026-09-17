#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/arbitrary_builder_app"
temporary_dir=$(mktemp -d)
test_root="$temporary_dir/workspace"
test_fixtures_dir="$test_root/fixtures"
stock_dir="$test_fixtures_dir/stock"
rust_dir="$test_fixtures_dir/rust"

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
  printf 'capture-builder: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,180p' "$log" >&2
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib/assets/nested"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/arbitrary_builder.dart" "$directory/lib/arbitrary_builder.dart"
  printf 'capture input\n' >"$directory/lib/assets/nested/input.txt"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache"
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
    build --root "$directory" --dart "$dart_bin"
}
assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file remains: $1"
}

mkdir -p "$test_fixtures_dir"
worker_attach "$test_root"
prepare_package "$stock_dir"
prepare_package "$rust_dir"

run_stock "$stock_dir" "$temporary_dir/initial.stock.log"
run_rust "$rust_dir" "$temporary_dir/initial.rust.log"
assert_same_file \
  "$stock_dir/lib/generated/nested/input.dart" \
  "$rust_dir/lib/generated/nested/input.dart"
grep -Fq 'Rust frontend: 2 build action(s)' "$temporary_dir/initial.rust.log" || \
  fail 'initial Rust action count differs'

run_rust "$rust_dir" "$temporary_dir/no-op.rust.log"
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || \
  fail 'Rust capture no-op was not reported'

printf 'capture changed\n' >"$stock_dir/lib/assets/nested/input.txt"
printf 'capture changed\n' >"$rust_dir/lib/assets/nested/input.txt"
run_stock "$stock_dir" "$temporary_dir/change.stock.log"
run_rust "$rust_dir" "$temporary_dir/change.rust.log"
assert_same_file \
  "$stock_dir/lib/generated/nested/input.dart" \
  "$rust_dir/lib/generated/nested/input.dart"

mv "$stock_dir/lib/assets/nested/input.txt" \
  "$stock_dir/lib/assets/nested/renamed.txt"
mv "$rust_dir/lib/assets/nested/input.txt" \
  "$rust_dir/lib/assets/nested/renamed.txt"
run_stock "$stock_dir" "$temporary_dir/rename.stock.log"
run_rust "$rust_dir" "$temporary_dir/rename.rust.log"
assert_same_file \
  "$stock_dir/lib/generated/nested/renamed.dart" \
  "$rust_dir/lib/generated/nested/renamed.dart"
assert_no_file "$stock_dir/lib/generated/nested/input.dart"
assert_no_file "$rust_dir/lib/generated/nested/input.dart"

rm -f -- \
  "$stock_dir/lib/assets/nested/renamed.txt" \
  "$rust_dir/lib/assets/nested/renamed.txt"
run_stock "$stock_dir" "$temporary_dir/delete.stock.log"
run_rust "$rust_dir" "$temporary_dir/delete.rust.log"
assert_no_file "$stock_dir/lib/generated/nested/renamed.dart"
assert_no_file "$rust_dir/lib/generated/nested/renamed.dart"
grep -Fq 'Rust frontend: 0 build action(s)' "$temporary_dir/delete.rust.log" || \
  fail 'delete Rust action count differs'

printf 'capture-builder: multi-group=yes anchor=yes rename=yes delete=yes\n'
