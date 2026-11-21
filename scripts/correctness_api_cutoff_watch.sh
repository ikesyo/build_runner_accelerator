#!/usr/bin/env bash
set -euo pipefail

# ADR 0056 stage 4 watch coverage: with a resident worker, a
# body-only dependency edit must skip the opted-in resolver-only
# action while the opted-in direct-read action reruns, and an API
# edit must rerun both. One-shot builds cannot catch stale
# fingerprint answers or binding mistakes across successive passes
# on the same worker, so this drives a real `watch` process.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/api_cutoff_app"
watch_dir=$(mktemp -d "$repo_root/fixtures/build-runner-accelerator-api-cutoff-watch.XXXXXX")
stock_dir=$(mktemp -d "$repo_root/fixtures/build-runner-accelerator-api-cutoff-watch-stock.XXXXXX")
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
  remove_tree "$stock_dir"
  remove_tree "$results_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'api-cutoff-watch: FAIL: %s\n' "$*" >&2
  verification_report_watch_timeout "api-cutoff-watch" "$watch_dir" "$log_path" "$watch_pid"
  if [[ -f "$log_path" ]]; then
    sed -n '1,220p' "$log_path" >&2
  fi
  exit 1
}

if [[ ! -x "$dart_bin" ]]; then
  fail "Dart executable not found: $dart_bin"
fi
worker_ensure_frontend || fail 'Rust frontend build failed'

cp -r "$fixture_dir/." "$watch_dir/"
verification_run_pub_get "$watch_dir" "pub-get/api-cutoff-watch" "$dart_bin" "$pub_cache" "${pub_get_args[@]}"

worker_start_frontend_process_group "$log_path" \
  BUILD_RUNNER_ACCELERATOR_METRICS=1 PUB_CACHE="$pub_cache" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" -- \
  watch --root "$watch_dir" --dart "$dart_bin" --interval-ms 200 \
  --api-cutoff 'api_cutoff_app:summary' --api-cutoff 'api_cutoff_app:echo' \
  --api-cutoff 'api_cutoff_app:probe' --api-cutoff 'api_cutoff_app:ast'
watch_pid=$worker_last_pid

summary_runs() {
  grep -Fc 'Dart action metrics: {"builder":"api_cutoff_app:summary"' "$log_path" || true
}
echo_runs() {
  grep -Fc 'Dart action metrics: {"builder":"api_cutoff_app:echo"' "$log_path" || true
}
probe_runs() {
  grep -Fc 'Dart action metrics: {"builder":"api_cutoff_app:probe"' "$log_path" || true
}
ast_runs() {
  grep -Fc 'Dart action metrics: {"builder":"api_cutoff_app:ast"' "$log_path" || true
}

wait_for_initial_build() {
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    if grep -Fq 'Watching ' "$log_path" && [[ -f "$watch_dir/lib/consumer.summary.txt" ]]; then
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
summary_before=$(summary_runs)
echo_before=$(echo_runs)
probe_before=$(probe_runs)
ast_before=$(ast_runs)
((summary_before >= 1)) || fail 'summary action did not run in the initial watch build'
((echo_before >= 1)) || fail 'echo action did not run in the initial watch build'
((probe_before >= 1)) || fail 'probe action did not run in the initial watch build'
((ast_before >= 1)) || fail 'ast action did not run in the initial watch build'
cp "$watch_dir/lib/consumer.summary.txt" "$results_dir/summary.initial.txt"

# Body-only edit: the resident worker must answer the preflight
# with the unchanged fingerprint, so summary is skipped while the
# direct-read echo action reruns.
sed -i "s/widget-v1/widget-v2/" "$watch_dir/lib/api.dart"
wait_for_stable_watch_state 1 2
[[ "$(summary_runs)" == "$summary_before" ]] || \
  fail 'summary action reran after a body-only edit in watch mode'
[[ "$(probe_runs)" == "$probe_before" ]] || \
  fail 'probe action reran after a body-only edit in watch mode'
(( $(echo_runs) > echo_before )) || \
  fail 'echo action did not rerun after a body-only edit in watch mode'
# The ast action is opted in but observes the dependency through
# its AST, so the safety net downgrades it: it must rerun on the
# body-only edit, and its output embeds the body text, so the new
# body must be visible immediately, not only after a later edit.
(( $(ast_runs) > ast_before )) || \
  fail 'ast action did not rerun after a body-only edit in watch mode'
grep -Fq 'widget-v2' "$watch_dir/lib/consumer.ast.txt" || \
  fail 'ast output did not pick up the body edit in watch mode'
cmp "$results_dir/summary.initial.txt" "$watch_dir/lib/consumer.summary.txt" || \
  fail 'summary output changed after a body-only edit in watch mode'
grep -Fq 'widget-v2' "$watch_dir/lib/consumer.echo.txt" || \
  fail 'echo output did not pick up the body edit in watch mode'
summary_before=$(summary_runs)

# API edit on the same resident worker: the fingerprint changes,
# so the summary action reruns and observes the new method.
python3 - "$watch_dir/lib/api.dart" <<'PYEOF'
import sys

path = sys.argv[1]
source = open(path).read()
anchor = "  /// Extra rendering.\n  String extra() => 'extra';\n}"
if source.count(anchor) != 1:
    raise SystemExit("api edit anchor not found")
source = source.replace(
    anchor,
    "  /// Extra rendering.\n  String extra() => 'extra';\n\n"
    "  /// Whether the widget is ready.\n  bool ready() => true;\n}",
)
open(path, "w").write(source)
PYEOF
wait_for_stable_watch_state 2 3
(( $(summary_runs) > summary_before )) || \
  fail 'summary action did not rerun after an API edit in watch mode'
grep -Fq 'ready' "$watch_dir/lib/consumer.summary.txt" || \
  fail 'summary output did not observe the API edit in watch mode'
grep -Fq 'ready' "$watch_dir/lib/consumer.probe.txt" || \
  fail 'probe output did not observe the API edit in watch mode'

worker_stop_process_group "$watch_pid"
watch_pid=

# The final sources, built once by stock, must produce identical
# outputs to the ones the watch session converged to.
cp -r "$fixture_dir/." "$stock_dir/"
cp "$watch_dir/lib/api.dart" "$stock_dir/lib/api.dart"
verification_run_pub_get "$stock_dir" "pub-get/api-cutoff-watch-stock" "$dart_bin" "$pub_cache" "${pub_get_args[@]}"
(
  cd "$stock_dir"
  PUB_CACHE="$pub_cache" "$dart_bin" run build_runner build \
    --delete-conflicting-outputs >"$results_dir/stock.log" 2>&1
) || fail 'stock build failed for the watch comparison'
cmp "$stock_dir/lib/consumer.summary.txt" "$watch_dir/lib/consumer.summary.txt" || \
  fail 'watch summary output differs from stock'
cmp "$stock_dir/lib/consumer.echo.txt" "$watch_dir/lib/consumer.echo.txt" || \
  fail 'watch echo output differs from stock'
cmp "$stock_dir/lib/consumer.probe.txt" "$watch_dir/lib/consumer.probe.txt" || \
  fail 'watch probe output differs from stock'
cmp "$stock_dir/lib/consumer.ast.txt" "$watch_dir/lib/consumer.ast.txt" || \
  fail 'watch ast output differs from stock'
cmp "$stock_dir/lib/consumer.combined.txt" "$watch_dir/lib/consumer.combined.txt" || \
  fail 'watch combined output differs from stock'

printf 'api-cutoff-watch: PASS body-only-skip=yes api-rerun=yes stock-identical=yes\n'
