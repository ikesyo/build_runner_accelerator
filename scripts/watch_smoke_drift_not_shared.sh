#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/drift_analyzer_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-drift-not-shared-watch.XXXXXX")
watch_dir="$test_root/fixtures/watch"
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
  find "$path" -depth -type l -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  local cleanup_status=$?
  worker_stop_process_group "$watch_pid"
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace and logs: %s %s\n' \
      "$test_root" "$results_dir" >&2
    return 0
  fi
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'drift-not-shared-watch: FAIL: %s\n' "$*" >&2
  verification_report_watch_timeout \
    'drift-not-shared-watch' "$watch_dir" "$log_path" "$watch_pid"
  [[ ! -f "$log_path" ]] || sed -n '1,320p' "$log_path" >&2
  exit 1
}

wait_for_success_count() {
  local expected=$1
  for _ in $(seq 1 "$(verification_watch_poll_iterations 300)"); do
    local succeeded
    succeeded=$(grep -Ec 'Rust watch cycle metrics: .* success=true' "$log_path" || true)
    if ((succeeded >= expected)); then return 0; fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited'
    sleep 0.2
  done
  fail "watch completion timed out at count $expected"
}

wait_for_failure_count() {
  local expected=$1
  for _ in $(seq 1 "$(verification_watch_poll_iterations 300)"); do
    local failures
    failures=$(grep -Fc 'fatal_warnings' "$log_path" || true)
    if ((failures >= expected)); then return 0; fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited after failure'
    sleep 0.2
  done
  fail 'watch failure was not observed'
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

mkdir -p "$watch_dir"
worker_attach "$test_root"
cp "$fixture_dir/pubspec.yaml" "$watch_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$watch_dir/pubspec.lock"
cp "$fixture_dir/build.not_shared.failure.yaml" "$watch_dir/build.yaml"
cp -R "$fixture_dir/lib" "$watch_dir/"
verification_run_pub_get "$watch_dir" 'pub-get/watch' "$dart_bin" "$pub_cache" \
  "${pub_get_args[@]}"

worker_start_frontend_process_group "$log_path" \
  BUILD_RUNNER_ACCELERATOR_METRICS=1 PUB_CACHE="$pub_cache" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" -- \
  watch --root "$watch_dir" --dart "$dart_bin" --jobs 1 --interval-ms 200
watch_pid=$worker_last_pid

wait_for_success_count 1
[[ -f "$watch_dir/lib/database.drift.dart" ]] || fail 'initial not_shared output missing'
[[ -f "$watch_dir/lib/schema.drift_analyzer_probe.txt" ]] || fail 'initial analyzer probe missing'
cp "$watch_dir/lib/database.drift.dart" "$results_dir/database.initial.dart"
sleep 1

find "$watch_dir/lib" -maxdepth 1 -type f -name 'database.drift.dart' -delete
wait_for_success_count 2
assert_restored="$watch_dir/lib/database.drift.dart"
[[ -f "$assert_restored" ]] || fail 'deleted not_shared output was not restored'
cmp "$results_dir/database.initial.dart" "$assert_restored" >/dev/null || \
  fail 'restored not_shared output differs from baseline'

sed -i 's/name TEXT NOT NULL,/name TEXT NOT NULL, email TEXT NOT NULL,/' \
  "$watch_dir/lib/schema.drift"
wait_for_success_count 3
if cmp -s "$results_dir/database.initial.dart" "$watch_dir/lib/database.drift.dart"; then
  fail 'SQL edit did not update not_shared output'
fi
cp "$watch_dir/lib/database.drift.dart" "$results_dir/database.before-failure.dart"
cp "$watch_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" \
  "$results_dir/graph.before-failure.bin"

sed -i "s/@DriftDatabase(include: {'schema.drift'})/@DriftDatabase(include: {'schema.drift'}, queries: {'brokenQuery': 'SELECT * FROM missing_table'})/" \
  "$watch_dir/lib/database.dart"
wait_for_failure_count 1
sleep 1
cmp "$results_dir/database.before-failure.dart" "$watch_dir/lib/database.drift.dart" >/dev/null || \
  fail 'failed watch attempt published not_shared output'
cmp "$results_dir/graph.before-failure.bin" \
  "$watch_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" >/dev/null || \
  fail 'failed watch attempt published graph state'

sed -i "/queries: {'brokenQuery'/s/, queries: {'brokenQuery': 'SELECT \* FROM missing_table'}//" \
  "$watch_dir/lib/database.dart"
wait_for_success_count 4

mv "$watch_dir/lib/schema.drift" "$watch_dir/lib/schema_renamed.drift"
sed -i 's/schema.drift/schema_renamed.drift/' "$watch_dir/lib/database.dart"
wait_for_success_count 5
[[ -f "$watch_dir/lib/schema_renamed.drift_analyzer_probe.txt" ]] || \
  fail 'renamed input output missing'
[[ ! -e "$watch_dir/lib/schema.drift_analyzer_probe.txt" ]] || \
  fail 'renamed input left stale source output'
[[ ! -e "$watch_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib/schema.drift.drift_module.json" ]] || \
  fail 'renamed input left stale cache output'

sed -i "s/@DriftDatabase(include: {'schema_renamed.drift'})/@DriftDatabase()/" \
  "$watch_dir/lib/database.dart"
find "$watch_dir/lib" -maxdepth 1 -type f -name 'schema_renamed.drift' -delete
wait_for_success_count 6
[[ ! -e "$watch_dir/lib/schema_renamed.drift_analyzer_probe.txt" ]] || \
  fail 'deleted input left stale source output'

cp "$fixture_dir/lib/schema.drift" "$watch_dir/lib/schema.drift"
sed -i "s/@DriftDatabase()/@DriftDatabase(include: {'schema.drift'})/" \
  "$watch_dir/lib/database.dart"
wait_for_success_count 7
[[ -f "$watch_dir/lib/schema.drift_analyzer_probe.txt" ]] || \
  fail 'recreated input did not restore source output'
[[ -f "$watch_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib/schema.drift.drift_module.json" ]] || \
  fail 'recreated input did not restore cache output'

printf 'drift-not-shared-watch: output-delete=yes sql-change=yes failure-atomic=yes recovery=yes rename=yes input-delete=yes recreate=yes\n'
