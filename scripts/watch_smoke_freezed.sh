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
fixture_dir="$repo_root/fixtures/freezed_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-freezed-watch-root.XXXXXX")
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
  printf 'freezed-watch-smoke: FAIL: %s\n' "$*" >&2
  if [[ -f "$log_path" ]]; then
    sed -n '1,240p' "$log_path" >&2
  fi
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml") || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend binary is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$watch_dir/lib"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
cp "$fixture_dir/pubspec.yaml" "$watch_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$watch_dir/pubspec.lock"
cp "$fixture_dir/build.yaml" "$watch_dir/build.yaml"
cp "$fixture_dir/lib/model.dart" "$watch_dir/lib/model.dart"
cp "$fixture_dir/lib/serializable.dart" "$watch_dir/lib/serializable.dart"
(cd "$watch_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)

setsid env BUILD_RUNNER_ACCELERATOR_METRICS=1 PUB_CACHE="$pub_cache" \
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  "$script_dir/run_rust_frontend.sh" \
  watch --root "$watch_dir" --dart "$dart_bin" --interval-ms 200 \
  >"$log_path" 2>&1 &
watch_pid=$!

wait_for_initial_build() {
  for _ in $(seq 1 300); do
    if grep -Fq 'Watching ' "$log_path" && \
      [[ -f "$watch_dir/lib/model.freezed.dart" ]] && \
      [[ -f "$watch_dir/lib/serializable.g.dart" ]]; then
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
    rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
    completed_count=$(grep -Fc 'Build completed (Rust frontend)' "$log_path" || true)
    if ((rebuild_count >= expected_count && completed_count >= expected_count + 1)); then
      return 0
    fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited during rebuild'
    sleep 0.2
  done
  fail "watch rebuild timed out at event count $expected_count"
}

wait_for_initial_build
cp "$watch_dir/lib/model.freezed.dart" "$results_dir/model.before.freezed.dart"

find "$watch_dir/lib" -maxdepth 1 -type f -name 'model.freezed.dart' -delete
wait_for_rebuild 1
sleep 1
rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
((rebuild_count == 1)) || \
  fail "generated output deletion caused $rebuild_count rebuild events"
[[ -f "$watch_dir/lib/model.freezed.dart" ]] || \
  fail 'Freezed generated output was not restored'
cmp "$results_dir/model.before.freezed.dart" \
  "$watch_dir/lib/model.freezed.dart" || \
  fail 'restored Freezed output differs from baseline'

sed -i 's/displayName/displayNameChanged/g' "$watch_dir/lib/model.dart"
wait_for_rebuild 2
sleep 1
rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
((rebuild_count == 2)) || fail "source edit caused $rebuild_count rebuild events"
if cmp -s "$results_dir/model.before.freezed.dart" \
  "$watch_dir/lib/model.freezed.dart"; then
  fail 'source edit did not change Freezed output'
fi

metrics_count=$(grep -Fc 'Rust metrics:' "$log_path" || true)
((metrics_count >= 3)) || fail "watch emitted only $metrics_count metrics lines"
grep -Fq 'worker_starts_total=1' "$log_path" || \
  fail 'watch did not retain the initial worker'
grep -Fq 'worker_resets_total=2' "$log_path" || \
  fail 'watch did not reset the resident worker between builds'

printf 'freezed-watch-smoke: generated-output-delete=yes source-edit=yes event-count=2\n'
