#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/optional_cleanup_app"
lockfile_source="$fixture_dir/pubspec.lock"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
stock_log="$temporary_dir/stock-watch.log"
rust_log="$temporary_dir/rust-watch.log"
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

cleanup() {
  local cleanup_status=$?
  worker_stop_process_group "$stock_pid"
  worker_stop_process_group "$rust_pid"
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'optional-cleanup-watch: FAIL: %s\n' "$*" >&2
  verification_report_watch_timeout "optional-cleanup-watch" "$workspace_root" "$stock_log" "$stock_pid" "$rust_log" "$rust_pid"
  for log in "$stock_log" "$rust_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,240p' "$log" >&2
    fi
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

worker_ensure_frontend || fail 'Rust frontend build failed'

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/builders.dart" "$directory/lib/builders.dart"
  cp "$fixture_dir/lib/input.seed" "$directory/lib/input.seed"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" || \
    fail "pub get failed for $directory"
}

mkdir -p "$fixture_root"
worker_attach "$workspace_root"
prepare_package "$stock_dir"
prepare_package "$rust_dir"

worker_start_process_group_in_dir "$stock_dir" "$stock_log" \
  env PUB_CACHE="$pub_cache" \
  "$dart_bin" --suppress-analytics run build_runner \
  watch --delete-conflicting-outputs
stock_pid=$worker_last_pid

wait_for_path() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    [[ -f "$path" ]] && return 0
    kill -0 "$pid" 2>/dev/null || fail "watch exited before creating $path"
    sleep 0.25
  done
  fail "timed out waiting for $path"
}

wait_for_absent() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
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
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
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

wait_for_native_successes() {
  local expected=$1 count
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    count=$(grep -Fc 'Build completed (Rust frontend)' "$rust_log" || true)
    ((count >= expected)) && return 0
    kill -0 "$rust_pid" 2>/dev/null || fail 'native watch exited'
    sleep 0.25
  done
  fail "timed out waiting for $expected successful native builds"
}

atomic_write() {
  local path=$1
  local temporary_path="${path}.tmp"
  printf 'changed optional\n' >"$temporary_path"
  mv -- "$temporary_path" "$path"
}

# Start sequentially to avoid competing stock/native compiler work.
wait_for_text "$stock_log" 'Built with build_runner' "$stock_pid"
worker_start_frontend_process_group "$rust_log" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  PUB_CACHE="$pub_cache" -- \
  watch --root "$rust_dir" --dart "$dart_bin" --interval-ms 200 --jobs 1
rust_pid=$worker_last_pid


outputs=(input.stage input.ready input.final input.stage.receipt input.ready.receipt)
check_outputs() {
  local prefix=$1 text=$2
  local output
  for output in "${outputs[@]}"; do
    output=${output/input./$prefix.}
    wait_for_text "$stock_dir/lib/$output" "$text" "$stock_pid"
    wait_for_text "$rust_dir/lib/$output" "$text" "$rust_pid"
    assert_same_file "$stock_dir/lib/$output" "$rust_dir/lib/$output"
  done
}
check_outputs input initial
wait_for_text "$rust_log" "Watching $rust_dir (native filesystem events)" "$rust_pid"
atomic_write "$stock_dir/lib/input.seed"
atomic_write "$rust_dir/lib/input.seed"
check_outputs input 'changed optional'
wait_for_native_successes 2
# An optional builder error leaves all native committed files and graph intact.
cp "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary_dir/graph.before"
cp -R "$rust_dir/lib" "$temporary_dir/lib.before"
for directory in "$stock_dir" "$rust_dir"; do
  printf 'FAIL\n' >"$temporary_dir/failing.seed"
  cp "$temporary_dir/failing.seed" "$directory/lib/input.seed"
done
wait_for_text "$stock_log" 'optional cleanup failure' "$stock_pid"
wait_for_text "$rust_log" 'optional cleanup failure' "$rust_pid"
cmp "$temporary_dir/graph.before" "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'graph published on failure'
cp "$rust_dir/lib/input.seed" "$temporary_dir/lib.before/input.seed"
diff -ru "$temporary_dir/lib.before" "$rust_dir/lib" || fail 'output published on failure'
printf 'recovered\n' >"$stock_dir/lib/input.seed"
printf 'recovered\n' >"$rust_dir/lib/input.seed"
check_outputs input recovered
wait_for_native_successes 3
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/input.seed" "$directory/lib/renamed.seed"
done
check_outputs renamed recovered
for output in "${outputs[@]}"; do
  wait_for_absent "$stock_dir/lib/$output" "$stock_pid"
  wait_for_absent "$rust_dir/lib/$output" "$rust_pid"
done
rm "$stock_dir/lib/renamed.seed" "$rust_dir/lib/renamed.seed"
for output in "${outputs[@]}"; do
  output=${output/input./renamed.}
  wait_for_absent "$stock_dir/lib/$output" "$stock_pid"
  wait_for_absent "$rust_dir/lib/$output" "$rust_pid"
done
printf 'restored\n' >"$stock_dir/lib/input.seed"
printf 'restored\n' >"$rust_dir/lib/input.seed"
check_outputs input restored
printf 'optional-cleanup-watch: change=yes failure-recovery=yes rename=yes delete=yes restore=yes\n'
