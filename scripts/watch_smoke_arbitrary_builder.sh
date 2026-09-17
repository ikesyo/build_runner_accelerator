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
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
stock_log="$temporary_dir/stock-watch.log"
rust_log="$temporary_dir/rust-watch.log"
stock_pid=
rust_pid=

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
  worker_stop_process_group "$stock_pid"
  worker_stop_process_group "$rust_pid"
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'arbitrary-builder-watch: FAIL: %s\n' "$*" >&2
  verification_report_watch_timeout "arbitrary-builder-watch" "$workspace_root" "$stock_log" "$stock_pid" "$rust_log" "$rust_pid"
  for log in "$stock_log" "$rust_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,220p' "$log" >&2
    fi
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

worker_ensure_frontend || fail 'Rust frontend build failed'

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/arbitrary_builder.dart" "$directory/lib/arbitrary_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  mkdir -p "$directory/lib/assets/nested"
  printf 'capture watch\n' >"$directory/lib/assets/nested/input.txt"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" || \
    fail "pub get failed for $directory"
}

mkdir -p "$fixture_root"
worker_attach "$workspace_root"
prepare_package "$stock_dir"
prepare_package "$rust_dir"

worker_start_process_group_in_dir "$stock_dir" "$stock_log" \
  env PUB_CACHE="$pub_cache" \
  "$dart_bin" --suppress-analytics run build_runner \
  watch --delete-conflicting-outputs
stock_pid=$worker_last_pid

worker_start_frontend_process_group "$rust_log" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  PUB_CACHE="$pub_cache" -- \
  watch --root "$rust_dir" --dart "$dart_bin" --interval-ms 200
rust_pid=$worker_last_pid

wait_for_path() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    [[ -f "$path" ]] && return 0
    kill -0 "$pid" 2>/dev/null || fail "watch process exited before creating $path"
    sleep 0.25
  done
  fail "timed out waiting for $path"
}

wait_for_text() {
  local path=$1
  local expected=$2
  local pid=$3
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    if [[ -f "$path" ]] && grep -Fq -- "$expected" "$path"; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || fail "watch process exited before writing $expected"
    sleep 0.25
  done
  fail "timed out waiting for $expected in $path"
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_no_file() {
  local path=$1
  [[ ! -e "$path" ]] || fail "unexpected stale file: $path"
}

atomic_write() {
  local path=$1
  local temporary_path="${path}.tmp"
  printf 'changed\n' >"$temporary_path"
  mv -- "$temporary_path" "$path"
}

wait_for_initial_outputs() {
  wait_for_path "$stock_dir/lib/input.gen.txt" "$stock_pid"
  wait_for_path "$stock_dir/lib/input.meta.txt" "$stock_pid"
  wait_for_path "$stock_dir/lib/generated/nested/input.dart" "$stock_pid"
  wait_for_path "$rust_dir/lib/input.gen.txt" "$rust_pid"
  wait_for_path "$rust_dir/lib/input.meta.txt" "$rust_pid"
  wait_for_path "$rust_dir/lib/generated/nested/input.dart" "$rust_pid"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$stock_dir/lib/input.meta.txt" "$rust_dir/lib/input.meta.txt"
  assert_same_file \
    "$stock_dir/lib/generated/nested/input.dart" \
    "$rust_dir/lib/generated/nested/input.dart"
}

wait_for_initial_outputs

rm -f -- \
  "$stock_dir/lib/input.gen.txt" "$stock_dir/lib/input.meta.txt" \
  "$rust_dir/lib/input.gen.txt" "$rust_dir/lib/input.meta.txt"
wait_for_path "$stock_dir/lib/input.gen.txt" "$stock_pid"
wait_for_path "$stock_dir/lib/input.meta.txt" "$stock_pid"
wait_for_path "$rust_dir/lib/input.gen.txt" "$rust_pid"
wait_for_path "$rust_dir/lib/input.meta.txt" "$rust_pid"
assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
assert_same_file "$stock_dir/lib/input.meta.txt" "$rust_dir/lib/input.meta.txt"

atomic_write "$stock_dir/lib/input.txt"
atomic_write "$rust_dir/lib/input.txt"
wait_for_text "$stock_dir/lib/input.gen.txt" 'changed generated' "$stock_pid"
wait_for_text "$rust_dir/lib/input.gen.txt" 'changed generated' "$rust_pid"
assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
assert_same_file "$stock_dir/lib/input.meta.txt" "$rust_dir/lib/input.meta.txt"

atomic_write "$stock_dir/lib/assets/nested/input.txt"
atomic_write "$rust_dir/lib/assets/nested/input.txt"
wait_for_text "$stock_dir/lib/generated/nested/input.dart" \
  'changed captured' "$stock_pid"
wait_for_text "$rust_dir/lib/generated/nested/input.dart" \
  'changed captured' "$rust_pid"
assert_same_file \
  "$stock_dir/lib/generated/nested/input.dart" \
  "$rust_dir/lib/generated/nested/input.dart"

mv "$stock_dir/lib/input.txt" "$stock_dir/lib/renamed.txt"
mv "$rust_dir/lib/input.txt" "$rust_dir/lib/renamed.txt"
wait_for_path "$stock_dir/lib/renamed.gen.txt" "$stock_pid"
wait_for_path "$stock_dir/lib/renamed.meta.txt" "$stock_pid"
wait_for_path "$rust_dir/lib/renamed.gen.txt" "$rust_pid"
wait_for_path "$rust_dir/lib/renamed.meta.txt" "$rust_pid"
sleep 1
assert_same_file "$stock_dir/lib/renamed.gen.txt" "$rust_dir/lib/renamed.gen.txt"
assert_same_file "$stock_dir/lib/renamed.meta.txt" "$rust_dir/lib/renamed.meta.txt"
assert_no_file "$stock_dir/lib/input.gen.txt"
assert_no_file "$stock_dir/lib/input.meta.txt"
assert_no_file "$rust_dir/lib/input.gen.txt"
assert_no_file "$rust_dir/lib/input.meta.txt"

rust_rebuilds=$(grep -Fc 'Change detected; rebuilding' "$rust_log" || true)
(( rust_rebuilds >= 3 )) || fail "Rust watch emitted only $rust_rebuilds rebuild events"

printf 'arbitrary-builder-watch: output-delete=yes atomic-save=yes rename=yes\n'
