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
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/post_process_builder_app"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
stock_log="$temporary_dir/stock-watch.log"
rust_log="$temporary_dir/rust-watch.log"
stock_pid=
rust_pid=
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

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
  printf 'post-process-builder-watch: FAIL: %s\n' "$*" >&2
  for log in "$stock_log" "$rust_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,220p' "$log" >&2
    fi
  done
  exit 1
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
  fail "Rust frontend binary is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/post_process_builder.dart" \
    "$directory/lib/post_process_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "${pub_get_args[@]}" >/dev/null) || \
    fail "pub get failed for $directory"
}

mkdir -p "$fixture_root"
ln -s "$worker_dir" "$workspace_root/dart_worker"
prepare_package "$stock_dir"
prepare_package "$rust_dir"

(
  cd "$stock_dir"
  exec setsid env PUB_CACHE="$pub_cache" \
    "$dart_bin" --suppress-analytics run build_runner \
    watch --delete-conflicting-outputs
) >"$stock_log" 2>&1 &
stock_pid=$!

setsid env BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$script_dir/run_rust_frontend.sh" \
  watch --root "$rust_dir" --dart "$dart_bin" --interval-ms 200 \
  >"$rust_log" 2>&1 &
rust_pid=$!

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

stock_post_output() {
  local directory=$1
  printf '%s\n' \
    "$directory/.dart_tool/build/generated/post_process_builder_app/lib/input.gen.txt.post.txt"
}

rust_post_output() {
  local directory=$1
  printf '%s\n' \
    "$directory/.dart_tool/build_runner_accelerator/cache/post_process_builder_app/lib/input.gen.txt.post.txt"
}

wait_for_path "$stock_dir/lib/input.gen.txt" "$stock_pid"
wait_for_path "$rust_dir/lib/input.gen.txt" "$rust_pid"
wait_for_path "$(stock_post_output "$stock_dir")" "$stock_pid"
wait_for_path "$(rust_post_output "$rust_dir")" "$rust_pid"
assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
assert_same_file "$(stock_post_output "$stock_dir")" "$(rust_post_output "$rust_dir")"

atomic_write "$stock_dir/lib/input.txt"
atomic_write "$rust_dir/lib/input.txt"
wait_for_text "$stock_dir/lib/input.gen.txt" 'changed generated' "$stock_pid"
wait_for_text "$rust_dir/lib/input.gen.txt" 'changed generated' "$rust_pid"
wait_for_text "$(stock_post_output "$stock_dir")" 'changed generated' "$stock_pid"
wait_for_text "$(rust_post_output "$rust_dir")" 'changed generated' "$rust_pid"
assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
assert_same_file "$(stock_post_output "$stock_dir")" "$(rust_post_output "$rust_dir")"

mv "$stock_dir/lib/input.txt" "$stock_dir/lib/renamed.txt"
mv "$rust_dir/lib/input.txt" "$rust_dir/lib/renamed.txt"
wait_for_path "$stock_dir/lib/renamed.gen.txt" "$stock_pid"
wait_for_path "$rust_dir/lib/renamed.gen.txt" "$rust_pid"
wait_for_path \
  "$stock_dir/.dart_tool/build/generated/post_process_builder_app/lib/renamed.gen.txt.post.txt" \
  "$stock_pid"
wait_for_path \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/post_process_builder_app/lib/renamed.gen.txt.post.txt" \
  "$rust_pid"
sleep 1
assert_same_file "$stock_dir/lib/renamed.gen.txt" "$rust_dir/lib/renamed.gen.txt"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/post_process_builder_app/lib/renamed.gen.txt.post.txt" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/post_process_builder_app/lib/renamed.gen.txt.post.txt"
assert_no_file "$stock_dir/lib/input.gen.txt"
assert_no_file "$rust_dir/lib/input.gen.txt"
assert_no_file "$(stock_post_output "$stock_dir")"
assert_no_file "$(rust_post_output "$rust_dir")"

rust_rebuilds=$(grep -Fc 'Change detected; rebuilding' "$rust_log" || true)
(( rust_rebuilds >= 2 )) || fail "Rust watch emitted only $rust_rebuilds rebuild events"

printf 'post-process-builder-watch: input-change=yes rename=yes\n'
