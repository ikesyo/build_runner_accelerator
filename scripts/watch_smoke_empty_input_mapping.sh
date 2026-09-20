#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/empty_input_mapping_app"
lockfile_source="$repo_root/pubspec.lock"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/rust"
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

cleanup() {
  local cleanup_status=$?
  worker_stop_process_group "$stock_pid"
  worker_stop_process_group "$rust_pid"
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining watch workspace and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'empty-input-mapping-watch: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
  done
  exit 1
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

write_package() {
  local directory=$1
  mkdir -p "$directory/lib" "$directory/assets"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp -R "$fixture_dir/lib/." "$directory/lib/"
  cp -R "$fixture_dir/assets/." "$directory/assets/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}" || fail "pub get failed for $directory"
}

wait_for_outputs() {
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    if [[ -f "$stock_dir/lib/input.dart.empty_mapping.out" && \
      -f "$rust_dir/lib/input.dart.empty_mapping.out" && \
      -f "$stock_dir/lib/input.dart.consumed.out" && \
      -f "$rust_dir/lib/input.dart.consumed.out" ]]; then
      return 0
    fi
    kill -0 "$stock_pid" 2>/dev/null || fail 'stock watch process exited during startup'
    kill -0 "$rust_pid" 2>/dev/null || fail 'Rust watch process exited during startup'
    sleep 0.25
  done
  fail 'watch startup timed out'
}

wait_for_changed_output() {
  for _ in $(seq 1 "$(verification_watch_poll_iterations 250)"); do
    if grep -Fq 'content=changed by watch' "$stock_dir/lib/input.dart.empty_mapping.out" 2>/dev/null && \
      grep -Fq 'content=changed by watch' "$rust_dir/lib/input.dart.empty_mapping.out" 2>/dev/null && \
      grep -Fq 'content=changed by watch' "$stock_dir/lib/input.dart.consumed.out" 2>/dev/null && \
      grep -Fq 'content=changed by watch' "$rust_dir/lib/input.dart.consumed.out" 2>/dev/null; then
      return 0
    fi
    kill -0 "$stock_pid" 2>/dev/null || fail 'stock watch process exited during rebuild'
    kill -0 "$rust_pid" 2>/dev/null || fail 'Rust watch process exited during rebuild'
    sleep 0.25
  done
  fail 'watch rebuild timed out'
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'
mkdir -p "$workspace_root/fixtures"
worker_attach "$workspace_root" || fail 'unable to attach repository package'
write_package "$stock_dir"
write_package "$rust_dir"

stock_log="$temporary_dir/stock-watch.log"
rust_log="$temporary_dir/rust-watch.log"
worker_start_process_group_in_dir "$stock_dir" "$stock_log" env \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner watch \
  --delete-conflicting-outputs
stock_pid=$worker_last_pid
worker_start_frontend_process_group "$rust_log" \
  PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" -- \
  watch --root "$rust_dir" --dart "$dart_bin" --interval-ms 200
rust_pid=$worker_last_pid

wait_for_outputs
assert_same_file "$stock_dir/lib/input.dart.empty_mapping.out" \
  "$rust_dir/lib/input.dart.empty_mapping.out"
assert_same_file "$stock_dir/lib/input.dart.consumed.out" \
  "$rust_dir/lib/input.dart.consumed.out"

printf 'changed by watch\n' >"$stock_dir/lib/input.dart"
printf 'changed by watch\n' >"$rust_dir/lib/input.dart"
wait_for_changed_output
assert_same_file "$stock_dir/lib/input.dart.empty_mapping.out" \
  "$rust_dir/lib/input.dart.empty_mapping.out"
assert_same_file "$stock_dir/lib/input.dart.consumed.out" \
  "$rust_dir/lib/input.dart.consumed.out"

# build_runner 2.16 reports the initial build as "Built with
# build_runner/aot" and announces subsequent builds with "Starting build".
# Keep the older event spellings for compatibility with earlier SDKs.
stock_events=$(grep -Ec 'Build completed|Succeeded after|Built with build_runner/aot in|Starting build #' "$stock_log" || true)
rust_events=$(grep -Fc 'Build completed (Rust frontend)' "$rust_log" || true)
((stock_events >= 2)) || fail "stock watch completed only $stock_events builds"
((rust_events >= 2)) || fail "Rust watch completed only $rust_events builds"

printf 'empty-input-mapping-watch: stock/native=yes source-output=yes generated-consumer=yes source-edit=yes\n'
