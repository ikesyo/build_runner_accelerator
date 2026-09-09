#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
cargo_bin=${CARGO_BIN:-"$repo_root/.toolchains/cargo/bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
fixture_dir="$repo_root/fixtures/json_serializable_app"
watch_dir=$(mktemp -d "$repo_root/fixtures/fast-build-watch.XXXXXX")
results_dir=$(mktemp -d)
log_path="$results_dir/watch.log"
watch_pid=
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

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
  remove_tree "$watch_dir"
  remove_tree "$results_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'watch-smoke: FAIL: %s\n' "$*" >&2
  if [[ -f "$log_path" ]]; then
    sed -n '1,220p' "$log_path" >&2
  fi
  exit 1
}

if [[ ! -x "$dart_bin" ]]; then
  fail "Dart executable not found: $dart_bin"
fi
if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" && ! -x "$cargo_bin" ]]; then
  fail "Cargo executable not found: $cargo_bin"
fi

if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml") || \
    fail 'Rust frontend build failed'
  FAST_BUILD_RUNNER_BIN="$repo_root/rust/target/debug/fast_build_runner"
  export FAST_BUILD_RUNNER_BIN
fi
[[ -x "$FAST_BUILD_RUNNER_BIN" ]] || \
  fail "Rust frontend binary is not executable: $FAST_BUILD_RUNNER_BIN"

mkdir -p "$watch_dir/lib"
cp "$fixture_dir/pubspec.yaml" "$watch_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$watch_dir/pubspec.lock"
cp "$fixture_dir/build.yaml" "$watch_dir/build.yaml"
cp "$fixture_dir/lib/model.dart" "$watch_dir/lib/model.dart"
(cd "$watch_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "${pub_get_args[@]}" >/dev/null)

setsid env FAST_BUILD_RUNNER_METRICS=1 PUB_CACHE="$pub_cache" \
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$script_dir/run_rust_frontend.sh" \
  watch --root "$watch_dir" --dart "$dart_bin" --interval-ms 200 \
  >"$log_path" 2>&1 &
watch_pid=$!

wait_for_initial_build() {
  for _ in $(seq 1 240); do
    if grep -Fq 'Watching ' "$log_path" && [[ -f "$watch_dir/lib/model.g.dart" ]]; then
      return 0
    fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited during startup'
    sleep 0.25
  done
  fail 'watch startup timed out'
}

wait_for_rebuild() {
  local expected_count=$1
  for _ in $(seq 1 240); do
    local rebuild_count
    local completed_count
    rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
    completed_count=$(grep -Fc 'Build completed (Rust frontend)' "$log_path" || true)
    if ((rebuild_count >= expected_count && completed_count >= expected_count + 1)); then
      return 0
    fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited during rebuild'
    sleep 0.25
  done
  fail "watch rebuild timed out at event count $expected_count"
}

wait_for_initial_build
cp "$watch_dir/lib/model.g.dart" "$results_dir/model.before.g.dart"

find "$watch_dir/lib" -maxdepth 1 -type f -name 'model.g.dart' -delete
wait_for_rebuild 1
sleep 1
rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
((rebuild_count == 1)) || fail "generated output deletion caused $rebuild_count rebuild events"
[[ -f "$watch_dir/lib/model.g.dart" ]] || fail 'generated output was not restored'
cmp "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'restored generated output differs from baseline'

sed -i 's/displayName/displayNameChanged/g' "$watch_dir/lib/model.dart"
wait_for_rebuild 2
sleep 1
rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
((rebuild_count == 2)) || fail "source edit caused $rebuild_count rebuild events"
if cmp -s "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart"; then
  fail 'source edit did not change generated output'
fi

metrics_count=$(grep -Fc 'Rust metrics:' "$log_path" || true)
((metrics_count >= 3)) || fail "watch emitted only $metrics_count metrics lines"
grep -Fq 'worker_starts_total=1' "$log_path" || \
  fail 'watch did not retain the initial worker'
grep -Fq 'worker_resets_total=2' "$log_path" || \
  fail 'watch did not reset the resident worker between builds'

printf 'watch-smoke: generated-output-delete=yes source-edit=yes event-count=2\n'
