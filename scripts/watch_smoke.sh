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
sed -i 's/- lib\/\*\*\.dart/- lib\/model.dart/' "$watch_dir/build.yaml"
cp "$fixture_dir/lib/model.dart" "$watch_dir/lib/model.dart"
sed -i "1i import 'conditional_base.dart' if (dart.library.io) 'conditional_io.dart' if (dart.library.html) 'conditional_html.dart';" \
  "$watch_dir/lib/model.dart"
printf '%s\n' "const conditionalDefault = 'base';" \
  >"$watch_dir/lib/conditional_base.dart"
printf '%s\n' "const conditionalDefault = 'io';" \
  >"$watch_dir/lib/conditional_io.dart"
printf '%s\n' "const conditionalDefault = 'html';" \
  >"$watch_dir/lib/conditional_html.dart"
printf '%s\n' "const conditionalDefault = 'web';" \
  >"$watch_dir/lib/conditional_web.dart"
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

wait_for_stable_watch_state() {
  local expected_rebuild_count=$1
  local expected_completed_count=$2
  local stable_samples=0
  local last_signature=
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    local rebuild_count
    local completed_count
    local log_bytes
    local signature
    rebuild_count=$(grep -Fc 'Change detected; rebuilding' "$log_path" || true)
    completed_count=$(grep -Fc 'Build completed (Rust frontend)' "$log_path" || true)
    if ((rebuild_count > expected_rebuild_count || completed_count > expected_completed_count)); then
      fail "watch observed extra work (rebuilds=$rebuild_count completed=$completed_count; expected=$expected_rebuild_count/$expected_completed_count)"
    fi
    if ((rebuild_count == expected_rebuild_count && completed_count == expected_completed_count)); then
      log_bytes=$(wc -c <"$log_path")
      signature="$rebuild_count:$completed_count:$log_bytes"
      if [[ "$signature" == "$last_signature" ]]; then
        ((stable_samples += 1))
      else
        stable_samples=0
      fi
      if ((stable_samples >= 8)); then
        return 0
      fi
      last_signature=$signature
    else
      stable_samples=0
      last_signature=
    fi
    kill -0 "$watch_pid" 2>/dev/null || fail 'watch process exited during rebuild'
    sleep 0.25
  done
  fail "watch state did not settle at rebuild/completion counts $expected_rebuild_count/$expected_completed_count"
}

wait_for_initial_build
wait_for_stable_watch_state 0 1
cp "$watch_dir/lib/model.g.dart" "$results_dir/model.before.g.dart"

find "$watch_dir/lib" -maxdepth 1 -type f -name 'model.g.dart' -delete
wait_for_stable_watch_state 1 2
[[ -f "$watch_dir/lib/model.g.dart" ]] || fail 'generated output was not restored'
cmp "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'restored generated output differs from baseline'

sed -i 's/displayName/displayNameChanged/g' "$watch_dir/lib/model.dart"
wait_for_stable_watch_state 2 3
if cmp -s "$results_dir/model.before.g.dart" "$watch_dir/lib/model.g.dart"; then
  fail 'source edit did not change generated output'
fi
cp "$watch_dir/lib/model.g.dart" "$results_dir/model.after-source-edit.g.dart"

sed -i 's/conditional_html.dart/conditional_web.dart/' \
  "$watch_dir/lib/model.dart"
wait_for_stable_watch_state 3 4
cmp "$results_dir/model.after-source-edit.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'conditional import target edit changed generated output'
model_metric_count_before=$(grep -Fc '"input":"json_serializable_app|lib/model.dart"' "$log_path" || true)

printf '%s\n' "const conditionalDefault = 'webChanged';" \
  >"$watch_dir/lib/conditional_web.dart"
wait_for_stable_watch_state 4 5
cmp "$results_dir/model.after-source-edit.g.dart" "$watch_dir/lib/model.g.dart" || \
  fail 'inactive conditional import changed generated output'
model_metric_count_after=$(grep -Fc '"input":"json_serializable_app|lib/model.dart"' "$log_path" || true)
((model_metric_count_after > model_metric_count_before)) || \
  fail 'conditional import target edit did not rerun the affected model builder'

metrics_count=$(grep -Fc 'Rust metrics:' "$log_path" || true)
((metrics_count >= 5)) || fail "watch emitted only $metrics_count metrics lines"
grep -Fq 'worker_starts_total=1' "$log_path" || \
  fail 'watch did not retain the initial worker'
grep -Fq 'worker_resets_total=4' "$log_path" || \
  fail 'watch did not reset the resident worker between builds'

printf 'watch-smoke: generated-output-delete=yes source-edit=yes conditional-dependency-edit=yes event-count=4\n'
