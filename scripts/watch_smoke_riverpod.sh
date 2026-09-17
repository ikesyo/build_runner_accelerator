#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/riverpod_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-riverpod-watch-root.XXXXXX")
watch_dir="$test_root/fixtures/watch"
results_dir=$(mktemp -d)
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi
log_path="$results_dir/watch.log"
watch_pid=

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  local cleanup_status=$?
  worker_stop_process_group "$watch_pid"
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'riverpod-watch-smoke: FAIL: %s\n' "$*" >&2
  verification_report_watch_timeout "riverpod-watch-smoke" "$watch_dir" "$log_path" "$watch_pid"
  [[ -f "$log_path" ]] && sed -n '1,240p' "$log_path" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

mkdir -p "$watch_dir/lib"
worker_attach "$test_root"
cp "$fixture_dir/pubspec.yaml" "$watch_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$watch_dir/pubspec.lock"
cp "$fixture_dir/build.yaml" "$watch_dir/build.yaml"
cp "$fixture_dir/lib/model.dart" "$watch_dir/lib/model.dart"
cp "$fixture_dir/lib/secondary.dart" "$watch_dir/lib/secondary.dart"
verification_run_pub_get "$watch_dir" "pub-get/watch" "$dart_bin" "$pub_cache" "${pub_get_args[@]}"

worker_start_frontend_process_group "$log_path" \
  BUILD_RUNNER_ACCELERATOR_METRICS=1 PUB_CACHE="$pub_cache" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" -- \
  watch --root "$watch_dir" --dart "$dart_bin" \
  --interval-ms 200
watch_pid=$worker_last_pid

wait_for_initial_build() {
  for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
    if grep -Fq 'Watching ' "$log_path" && \
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
  for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
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
cp "$watch_dir/lib/model.g.dart" "$results_dir/model.before.g.dart"

rm -f -- "$watch_dir/lib/model.g.dart"
wait_for_rebuild 1
sleep 1
(( $(grep -Fc 'Change detected; rebuilding' "$log_path" || true) == 1 )) || \
  fail 'generated output deletion caused multiple rebuild events'
[[ -f "$watch_dir/lib/model.g.dart" ]] || fail 'Riverpod generated output was not restored'
cmp "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'restored Riverpod output differs from baseline'

sed -i 's/=> 42;/=> 43;/' "$watch_dir/lib/model.dart"
wait_for_rebuild 2
sleep 1
(( $(grep -Fc 'Change detected; rebuilding' "$log_path" || true) == 2 )) || \
  fail 'source edit caused multiple rebuild events'
cmp -s "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart" && \
  fail 'source edit did not change Riverpod output'

grep -Fq 'worker_starts_total=1' "$log_path" || fail 'watch did not retain the initial worker'
printf 'riverpod-watch-smoke: generated-output-delete=yes source-edit=yes event-count=2\n'
