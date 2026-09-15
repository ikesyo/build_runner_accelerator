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
fixture_dir="$repo_root/fixtures/trigger_builder_app"
worker_dir="$repo_root/dart_worker"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
test_fixtures_dir="$workspace_root/fixtures"
stock_dir="$test_fixtures_dir/stock"
rust_dir="$test_fixtures_dir/rust"
stock_log="$temporary_dir/stock.log"
rust_log="$temporary_dir/rust.log"
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

stop_process_group() {
  local pid=$1
  [[ -n "$pid" ]] || return 0
  kill -- -"$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_process_group "$stock_pid"
  stop_process_group "$rust_pid"
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'trigger-builder-watch: FAIL: %s\n' "$*" >&2
  for log in "$stock_log" "$rust_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,260p' "$log" >&2
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

wait_for_path() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 240); do
    [[ -f "$path" ]] && return 0
    kill -0 "$pid" 2>/dev/null || fail "watch exited before creating $path"
    sleep 0.25
  done
  fail "timed out waiting for $path"
}

wait_for_absent() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 240); do
    [[ ! -e "$path" ]] && return 0
    kill -0 "$pid" 2>/dev/null || fail "watch exited before removing $path"
    sleep 0.25
  done
  fail "timed out waiting for removal of $path"
}

wait_for_text() {
  local path=$1
  local expected=$2
  local pid=$3
  for _ in $(seq 1 240); do
    if [[ -f "$path" ]] && grep -Fq -- "$expected" "$path"; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || fail "watch exited before writing $expected"
    sleep 0.25
  done
  fail "timed out waiting for $expected in $path"
}

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib"/* "$directory/lib/"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null) || \
    fail "pub get failed for $directory"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$test_fixtures_dir"
ln -s "$worker_dir" "$workspace_root/dart_worker"
prepare_package "$stock_dir"
prepare_package "$rust_dir"

(
  cd "$stock_dir"
  exec setsid env PUB_CACHE="$pub_cache" \
    "$dart_bin" --suppress-analytics run build_runner watch \
    --delete-conflicting-outputs
) >"$stock_log" 2>&1 &
stock_pid=$!

setsid env BUILD_RUNNER_ACCELERATOR_METRICS=1 BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$script_dir/run_rust_frontend.sh" watch --root "$rust_dir" --dart "$dart_bin" \
  --interval-ms 200 >"$rust_log" 2>&1 &
rust_pid=$!

wait_for_path "$stock_dir/lib/generated_input.consumer.dart" "$stock_pid"
wait_for_path "$rust_dir/lib/generated_input.consumer.dart" "$rust_pid"
assert_same_file \
  "$stock_dir/lib/generated_input.consumer.dart" \
  "$rust_dir/lib/generated_input.consumer.dart"

for directory in "$stock_dir" "$rust_dir"; do
  printf "import 'package:trigger_builder_app/trigger_marker.dart';\nclass PlainInput {}\n" \
    >"$directory/lib/plain_input.dart.tmp"
  mv -- "$directory/lib/plain_input.dart.tmp" "$directory/lib/plain_input.dart"
done
wait_for_path "$stock_dir/lib/plain_input.triggered.dart" "$stock_pid"
wait_for_path "$rust_dir/lib/plain_input.triggered.dart" "$rust_pid"
assert_same_file \
  "$stock_dir/lib/plain_input.triggered.dart" \
  "$rust_dir/lib/plain_input.triggered.dart"

for directory in "$stock_dir" "$rust_dir"; do
  printf 'class PlainInput {}\n' >"$directory/lib/plain_input.dart.tmp"
  mv -- "$directory/lib/plain_input.dart.tmp" "$directory/lib/plain_input.dart"
done
wait_for_absent "$stock_dir/lib/plain_input.triggered.dart" "$stock_pid"
wait_for_absent "$rust_dir/lib/plain_input.triggered.dart" "$rust_pid"

for directory in "$stock_dir" "$rust_dir"; do
  printf '// seed-watch-v2\nclass Seed {}\n' >"$directory/lib/seed.dart.tmp"
  mv -- "$directory/lib/seed.dart.tmp" "$directory/lib/seed.dart"
done
wait_for_text "$stock_dir/lib/generated_input.consumer.dart" 'seed-watch-v2' "$stock_pid"
wait_for_text "$rust_dir/lib/generated_input.consumer.dart" 'seed-watch-v2' "$rust_pid"
assert_same_file \
  "$stock_dir/lib/generated_input.consumer.dart" \
  "$rust_dir/lib/generated_input.consumer.dart"

grep -Fq '"status":"not_triggered"' "$rust_log" || \
  fail 'Rust watch did not record a trigger skip'
grep -Fq 'worker_starts_total=1' "$rust_log" || \
  fail 'Rust watch did not retain the resident worker'

printf 'trigger-builder-watch: trigger-transition=yes generated-chain=yes stock-match=yes worker-lifetime=yes\n'
