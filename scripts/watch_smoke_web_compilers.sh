#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/web_compilers_support.sh"
: "${VERIFY_WATCH_TIMEOUT_SECONDS:=600}"
export VERIFY_WATCH_TIMEOUT_SECONDS
# Validate the SDK facade and compiler subprocess with a stable AOT worker.
# Keep an explicit override available for separate cold-script investigations.
: "${BUILD_RUNNER_ACCELERATOR_WORKER_AOT:=force}"
export BUILD_RUNNER_ACCELERATOR_WORKER_AOT
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/web-compilers-watch.XXXXXX")
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/native"
stock_log="$temporary_dir/stock.watch.log"
native_log="$temporary_dir/native.watch.log"
stock_pid=
native_pid=
pub_get_args=()
[[ "${PUB_GET_OFFLINE:-0}" != 1 ]] || pub_get_args+=(--offline)
cleanup() {
  local status=$?
  worker_stop_process_group "$stock_pid"
  worker_stop_process_group "$native_pid"
  if ((status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'web-compilers-watch: retained workspace/logs: %s\n' "$temporary_dir" >&2
    return
  fi
  find "$temporary_dir" -depth -type f -delete
  find "$temporary_dir" -depth -type l -delete
  find "$temporary_dir" -depth -type d -empty -delete
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
stock_successes() { grep -Fc 'Built with build_runner/aot in' "$stock_log" || true; }
native_successes() { grep -Fc 'Build completed (Rust frontend)' "$native_log" || true; }
checkpoint() { stock_before=$(stock_successes); native_before=$(native_successes); }
wait_pair() {
  local stage=${1:-initial}
  for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
    if (( $(stock_successes) > stock_before && $(native_successes) > native_before )) &&
      web_compare > "$temporary_dir/compare.log" 2>&1; then return; fi
    kill -0 "$stock_pid" && kill -0 "$native_pid" || break
    sleep 0.2
  done
  printf 'web-compilers-watch: convergence failed: %s\n' "$stage" >&2
  tail -n 80 "$stock_log" "$native_log" "$temporary_dir/compare.log" >&2 || true
  return 1
}
web_prepare
worker_start_process_group_in_dir "$stock_dir" "$stock_log" \
  env PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner watch
stock_pid=$worker_last_pid
for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
  (( $(stock_successes) > 0 )) && break
  kill -0 "$stock_pid"
  sleep 0.2
done
(( $(stock_successes) > 0 ))
worker_start_frontend_process_group "$native_log" \
  PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  BUILD_RUNNER_ACCELERATOR_METRICS=0 -- \
  watch --root "$rust_dir" --dart "$dart_bin" --jobs 1 --interval-ms 200
native_pid=$worker_last_pid
stock_before=0
native_before=0
wait_pair initial
checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/hello web/watch library/' "$directory/lib/message.dart"
done
wait_pair library-change
checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  sed -i "s/print(message());/print('watch entry: \${message()}');/" "$directory/web/main.dart"
done
wait_pair entry-change
checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  printf "String extra() => 'watch added';\n" > "$directory/lib/extra.dart"
  printf "import 'package:build_web_compilers_app/extra.dart';\nvoid main() { print(extra()); }\n" > "$directory/web/extra.dart"
done
wait_pair add
checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/extra.dart" "$directory/lib/renamed.dart"
  mv "$directory/web/extra.dart" "$directory/web/renamed.dart"
  sed -i 's@/extra.dart@/renamed.dart@' "$directory/web/renamed.dart"
done
wait_pair rename
checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  rm "$directory/lib/renamed.dart" "$directory/web/renamed.dart"
done
wait_pair delete
web_atomic save
for directory in "$stock_dir" "$rust_dir"; do
  printf "String message() => missingCompilerSymbol;\n" > "$directory/lib/message.dart"
  printf "void main() { print('tentative watch output'); }\n" > "$directory/web/aaa.dart"
done
for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
  if grep -Fq 'missingCompilerSymbol' "$stock_log" &&
     grep -Fq 'watch build failed:' "$native_log"; then break; fi
  sleep 0.2
done
grep -Fq 'missingCompilerSymbol' "$stock_log"
grep -Fq 'missingCompilerSymbol' "$native_log"
grep -Fq 'watch build failed:' "$native_log"
web_atomic check
[[ -e "$stock_dir/.dart_tool/build/generated/build_web_compilers_app/web/aaa.dart.js" ]]
[[ ! -e "$rust_dir/.dart_tool/build_runner_accelerator/cache/build_web_compilers_app/web/aaa.dart.js" ]]
checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  printf "String message() => 'watch recovered';\n" > "$directory/lib/message.dart"
done
wait_pair recovery
printf 'web-compilers-watch: PASS raw-bytes=yes change-add-rename-delete=yes compiler-failure-recovery=yes\n'
