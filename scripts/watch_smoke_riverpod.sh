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
fixture_dir="$repo_root/fixtures/riverpod_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-riverpod-watch-root.XXXXXX")
watch_dir="$test_root/fixtures/watch"
results_dir=$(mktemp -d)
log_path="$results_dir/watch.log"
watch_pid=

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  if [[ -n "$watch_pid" ]]; then
    kill -- "-$watch_pid" 2>/dev/null || true
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'riverpod-watch-smoke: FAIL: %s\n' "$*" >&2
  [[ -f "$log_path" ]] && sed -n '1,240p' "$log_path" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  (cd "$repo_root" && RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml") || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || fail 'Rust frontend binary is not executable'

mkdir -p "$watch_dir/lib"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
cp "$fixture_dir/pubspec.yaml" "$watch_dir/pubspec.yaml"
cp "$fixture_dir/build.yaml" "$watch_dir/build.yaml"
cp "$fixture_dir/lib/model.dart" "$watch_dir/lib/model.dart"
cp "$fixture_dir/lib/secondary.dart" "$watch_dir/lib/secondary.dart"
(cd "$watch_dir" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null)

setsid env BUILD_RUNNER_ACCELERATOR_METRICS=1 PUB_CACHE="$pub_cache" \
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  "$script_dir/run_rust_frontend.sh" watch --root "$watch_dir" --dart "$dart_bin" \
  --interval-ms 200 >"$log_path" 2>&1 &
watch_pid=$!

wait_for_initial_build() {
  for _ in $(seq 1 300); do
    if rg -Fq 'Watching ' "$log_path" && \
      [[ -f "$watch_dir/lib/model.freezed.dart" ]] && \
      [[ -f "$watch_dir/lib/model.g.dart" ]]; then
      return 0
    fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited during startup'
    sleep 0.2
  done
  fail 'watch startup timed out'
}

wait_for_rebuild() {
  local expected_count=$1
  for _ in $(seq 1 300); do
    local rebuild_count
    local completed_count
    rebuild_count=$(rg -Fc 'Change detected; rebuilding' "$log_path" || true)
    completed_count=$(rg -Fc 'Build completed (Rust frontend)' "$log_path" || true)
    if ((rebuild_count >= expected_count && completed_count >= expected_count + 1)); then
      return 0
    fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited during rebuild'
    sleep 0.2
  done
  fail "watch rebuild timed out at event count $expected_count"
}

wait_for_initial_build
cp "$watch_dir/lib/model.g.dart" "$results_dir/model.before.g.dart"

rm -f -- "$watch_dir/lib/model.g.dart"
wait_for_rebuild 1
sleep 1
(( $(rg -Fc 'Change detected; rebuilding' "$log_path" || true) == 1 )) || \
  fail 'generated output deletion caused multiple rebuild events'
[[ -f "$watch_dir/lib/model.g.dart" ]] || fail 'Riverpod generated output was not restored'
cmp "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'restored Riverpod output differs from baseline'

sed -i 's/=> 42;/=> 43;/' "$watch_dir/lib/model.dart"
wait_for_rebuild 2
sleep 1
(( $(rg -Fc 'Change detected; rebuilding' "$log_path" || true) == 2 )) || \
  fail 'source edit caused multiple rebuild events'
cmp -s "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart" && \
  fail 'source edit did not change Riverpod output'

rg -Fq 'worker_starts_total=1' "$log_path" || fail 'watch did not retain the initial worker'
printf 'riverpod-watch-smoke: generated-output-delete=yes source-edit=yes event-count=2\n'
