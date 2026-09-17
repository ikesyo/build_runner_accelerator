#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/current_json_app"
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
  printf 'current-json: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
  done
  exit 1
}

assert_same_outputs() {
  local phase=$1
  local -a outputs=()
  mapfile -t outputs < <(find "$stock_dir/lib" -maxdepth 1 -type f \
    -name '*.g.dart' -printf '%f\n' | sort)
  [[ "${#outputs[@]}" -eq 10 ]] || \
    fail "$phase: expected 10 generated Dart files, found ${#outputs[@]}"
  local rust_output_count
  rust_output_count=$(find "$rust_dir/lib" -maxdepth 1 -type f \
    -name '*.g.dart' | wc -l | tr -d ' ')
  [[ "$rust_output_count" -eq 10 ]] || \
    fail "$phase: expected 10 Rust generated Dart files, found $rust_output_count"
  for output in "${outputs[@]}"; do
    [[ -f "$rust_dir/lib/$output" ]] || fail "$phase: missing Rust output $output"
    cmp "$stock_dir/lib/$output" "$rust_dir/lib/$output" || \
      fail "$phase: generated output differs: $output"
  done
}

assert_rust_frontend() {
  local log=$1
  ! grep -Fq 'using Dart fallback' "$log" || \
    fail "Rust frontend unexpectedly used Dart fallback"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

worker_ensure_frontend || fail 'Rust frontend build failed'

write_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib"/*.dart "$directory/lib/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" --offline
}

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build
}
run_rust() {
  local directory=$1
  local log=$2
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend build --root "$directory" --dart "$dart_bin"
}
mkdir -p "$fixture_root"
worker_attach "$workspace_root"
write_package "$stock_dir"
write_package "$rust_dir"

run_stock "$stock_dir" "$temporary_dir/initial.stock.log" || \
  fail 'initial stock build failed'
run_rust "$rust_dir" "$temporary_dir/initial.rust.log" || \
  fail 'initial Rust build failed'
assert_rust_frontend "$temporary_dir/initial.rust.log"
assert_same_outputs initial

run_stock "$stock_dir" "$temporary_dir/no-op.stock.log" || \
  fail 'no-op stock build failed'
run_rust "$rust_dir" "$temporary_dir/no-op.rust.log" || \
  fail 'no-op Rust build failed'
assert_rust_frontend "$temporary_dir/no-op.rust.log"
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || \
  fail 'no-op: Rust frontend did not report no work'
assert_same_outputs no-op

sed -i 's/baseline-marker: base/baseline-marker: one-file/' \
  "$stock_dir/lib/model_01.dart" "$rust_dir/lib/model_01.dart"
run_stock "$stock_dir" "$temporary_dir/one-file.stock.log" || \
  fail 'one-file stock build failed'
run_rust "$rust_dir" "$temporary_dir/one-file.rust.log" || \
  fail 'one-file Rust build failed'
assert_rust_frontend "$temporary_dir/one-file.rust.log"
assert_same_outputs one-file

sed -i 's/baseline-marker: one-file/baseline-marker: broad/' \
  "$stock_dir/lib"/*.dart "$rust_dir/lib"/*.dart
run_stock "$stock_dir" "$temporary_dir/broad.stock.log" || \
  fail 'broad stock build failed'
run_rust "$rust_dir" "$temporary_dir/broad.rust.log" || \
  fail 'broad Rust build failed'
assert_rust_frontend "$temporary_dir/broad.rust.log"
assert_same_outputs broad

printf 'current-json: clean=yes no-op=yes one-file=yes broad=yes stock-match=yes\n'
