#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
worker_dir="$repo_root/dart_worker"
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
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  fail 'BUILD_RUNNER_ACCELERATOR_BIN is required; build the Rust frontend first'
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib/assets/nested"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/arbitrary_builder.dart" "$directory/lib/arbitrary_builder.dart"
  printf 'capture input\n' >"$directory/lib/assets/nested/input.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)
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
  PUB_CACHE="$pub_cache" \
    BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
    "$script_dir/run_rust_frontend.sh" \
    build --root "$directory" --dart "$dart_bin" >"$log" 2>&1
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
ln -s "$worker_dir" "$test_root/dart_worker"
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
