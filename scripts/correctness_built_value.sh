#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/built_value_app"
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
  printf 'built-value-correctness: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
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

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file remains: $1"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

worker_ensure_frontend || fail 'Rust frontend build failed'

mkdir -p "$fixture_root"
worker_attach "$workspace_root"
mkdir -p "$stock_dir" "$rust_dir"
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp -R "$fixture_dir/lib" "$directory/"
  cp -R "$fixture_dir/bin" "$directory/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" "$dart_bin" "$pub_cache" || fail "pub get failed in $directory"
done

verification_run_stock_build "$stock_dir" "build/stock" "$temporary_dir/stock.log" \
  "$dart_bin" "$pub_cache" build || fail 'stock build failed'
VERIFY_COMMAND_LOG="$temporary_dir/rust.log" VERIFY_WORKSPACE="$rust_dir" \
  worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" --jobs 1 || fail 'Rust build failed'

assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/built_value_app/lib/model.built_value.g.part" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/lib/model.built_value.g.part"
assert_no_file "$stock_dir/.dart_tool/build/generated/built_value_app/bin/example.built_value.g.part"
assert_no_file "$stock_dir/.dart_tool/build/generated/built_value_app/lib/plain.built_value.g.part"
assert_no_file "$stock_dir/bin/example.g.dart"
assert_no_file "$stock_dir/lib/plain.g.dart"
assert_no_file "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/bin/example.built_value.g.part"
assert_no_file "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/lib/plain.built_value.g.part"
assert_no_file "$rust_dir/bin/example.g.dart"
assert_no_file "$rust_dir/lib/plain.g.dart"
assert_contains "$temporary_dir/rust.log" 'Build completed (Rust frontend)'

# A normal builder may stop emitting an output after an input changes. The
# native frontend must remove the previous part and combined source output.
for directory in "$stock_dir" "$rust_dir"; do
  printf '// no longer a built_value library\nvoid model() {}\n' >"$directory/lib/model.dart"
done
verification_run_stock_build "$stock_dir" "build/stock-change" "$temporary_dir/stock-change.log" \
  "$dart_bin" "$pub_cache" build || \
  fail 'stock changed-input build failed'
VERIFY_COMMAND_LOG="$temporary_dir/rust-change.log" VERIFY_WORKSPACE="$rust_dir" \
  worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" --jobs 1 || \
  fail 'Rust changed-input build failed'
assert_no_file "$stock_dir/lib/model.g.dart"
assert_no_file "$rust_dir/lib/model.g.dart"
assert_no_file \
  "$stock_dir/.dart_tool/build/generated/built_value_app/lib/model.built_value.g.part"
assert_no_file \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/lib/model.built_value.g.part"

printf 'built-value-correctness: non-triggered-input=yes output-match=yes\n'
