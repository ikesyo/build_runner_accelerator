#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/json_serializable_app"
watch_dir=$(mktemp -d "$repo_root/fixtures/build-runner-accelerator-watch.XXXXXX")
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
  local cleanup_status=$?
  worker_stop_process_group "$watch_pid"
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$watch_dir"
  remove_tree "$results_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'watch-smoke: FAIL: %s\n' "$*" >&2
  verification_report_watch_timeout "watch-smoke" "$watch_dir" "$log_path" "$watch_pid"
  if [[ -f "$log_path" ]]; then
    sed -n '1,220p' "$log_path" >&2
  fi
  exit 1
}

if [[ ! -x "$dart_bin" ]]; then
  fail "Dart executable not found: $dart_bin"
fi
worker_ensure_frontend || fail 'Rust frontend build failed'

mkdir -p "$watch_dir/lib"
cp "$fixture_dir/pubspec.yaml" "$watch_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$watch_dir/pubspec.lock"
cp "$fixture_dir/build.yaml" "$watch_dir/build.yaml"
cp "$fixture_dir/lib/model.dart" "$watch_dir/lib/model.dart"
sed -i "1i import 'conditional_base.dart' if (dart.library.io) 'conditional_io.dart' if (dart.library.html) 'conditional_html.dart';" \
  "$watch_dir/lib/model.dart"
printf '%s\n' "const conditionalDefault = 'base';" \
  >"$watch_dir/lib/conditional_base.dart"
printf '%s\n' "const conditionalDefault = 'io';" \
  >"$watch_dir/lib/conditional_io.dart"
printf '%s\n' "const conditionalDefault = 'html';" \
  >"$watch_dir/lib/conditional_html.dart"
verification_run_pub_get "$watch_dir" "pub-get/watch" "$dart_bin" "$pub_cache" "${pub_get_args[@]}"

worker_start_frontend_process_group "$log_path" \
  BUILD_RUNNER_ACCELERATOR_METRICS=1 PUB_CACHE="$pub_cache" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" -- \
  watch --root "$watch_dir" --dart "$dart_bin" --interval-ms 200
watch_pid=$worker_last_pid

wait_for_initial_build() {
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
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
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
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
cp "$watch_dir/lib/model.g.dart" "$results_dir/model.after-source-edit.g.dart"

printf '%s\n' "const conditionalDefault = 'htmlChanged';" \
  >"$watch_dir/lib/conditional_html.dart"
wait_for_rebuild 3
sleep 1
rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
((rebuild_count == 3)) || fail "conditional import edit caused $rebuild_count rebuild events"
cmp "$results_dir/model.after-source-edit.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'inactive conditional import changed generated output'
action_build_count=$(grep -Fc 'Rust frontend: 2 build action(s)' "$log_path" || true)
((action_build_count >= 4)) || \
  fail 'conditional import edit did not rerun the affected build actions'

metrics_count=$(grep -Fc 'Rust metrics:' "$log_path" || true)
((metrics_count >= 4)) || fail "watch emitted only $metrics_count metrics lines"
grep -Fq 'worker_starts_total=1' "$log_path" || \
  fail 'watch did not retain the initial worker'
grep -Fq 'worker_resets_total=3' "$log_path" || \
  fail 'watch did not reset the resident worker between builds'

printf 'watch-smoke: generated-output-delete=yes source-edit=yes conditional-import-edit=yes event-count=3\n'
