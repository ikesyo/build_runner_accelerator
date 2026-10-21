#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
source "$script_dir/registry_override_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/registry-override-watch.XXXXXX")
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/native"
stock_log="$temporary_dir/stock.watch.log"
native_log="$temporary_dir/native.watch.log"
stock_pid=
native_pid=
stock_before=0
native_before=0
pub_get_args=()
[[ "${PUB_GET_OFFLINE:-0}" != 1 ]] || pub_get_args+=(--offline)
cleanup() {
  local status=$?
  worker_stop_process_group "$stock_pid"
  worker_stop_process_group "$native_pid"
  if ((status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'registry-override-watch: retained workspace/logs: %s\n' "$temporary_dir" >&2
    return
  fi
  find "$temporary_dir" -depth -type f -delete
  find "$temporary_dir" -depth -type l -delete
  find "$temporary_dir" -depth -type d -empty -delete
}
trap cleanup EXIT
fail() {
  printf 'registry-override-watch: FAIL: %s\n' "$*" >&2
  tail -100 "$stock_log" "$native_log" >&2 || true
  exit 1
}
stock_successes() { grep -Fc 'Built with build_runner/aot in' "$stock_log" || true; }
native_successes() { grep -Ec 'Rust watch cycle metrics: .* success=true' "$native_log" || true; }
checkpoint() {
  stock_before=$(stock_successes)
  native_before=$(native_successes)
}
wait_pair() {
  local needle=${1:-}
  local absent=${2:-}
  for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
    if (( $(stock_successes) > stock_before && $(native_successes) > native_before )) &&
      [[ -f "$rust_dir/lib/conduit.g.dart" ]] &&
      { [[ -z "$needle" ]] || grep -Fq "$needle" "$rust_dir/lib/conduit.g.dart"; } &&
      { [[ -z "$absent" ]] || ! grep -Fq "$absent" "$rust_dir/lib/conduit.g.dart"; } &&
      registry_override_compare > "$temporary_dir/compare.log" 2>&1; then
      sleep 0.5
      return
    fi
    kill -0 "$stock_pid" 2>/dev/null || fail 'stock watch exited'
    kill -0 "$native_pid" 2>/dev/null || fail 'native watch exited'
    sleep 0.2
  done
  cat "$temporary_dir/compare.log" >&2 || true
  fail "watch did not converge: $needle / absent=$absent"
}

registry_override_prepare
worker_start_process_group_in_dir "$stock_dir" "$stock_log" \
  env PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner watch
stock_pid=$worker_last_pid
# Compile/start the two frontends sequentially on small local runners.
for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
  (( $(stock_successes) > 0 )) && break
  kill -0 "$stock_pid" 2>/dev/null || fail 'stock watch startup failed'
  sleep 0.2
done
(( $(stock_successes) > 0 )) || fail 'stock watch startup timed out'
worker_start_frontend_process_group "$native_log" \
  PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  BUILD_RUNNER_ACCELERATOR_METRICS=1 -- \
  watch --root "$rust_dir" --dart "$dart_bin" --jobs 1 --interval-ms 200
native_pid=$worker_last_pid
wait_pair "map['Zulu']"

checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/Zulu/WatchZulu/' "$directory/lib/model.serializable.conduit.json"
done
wait_pair "map['WatchZulu']" "map['Zulu']"

checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  printf '{"controllers":["WatchAdded"]}\n' > "$directory/lib/extra.record"
  printf '{"channels":["WatchChannel"]}\n' > "$directory/lib/extra.cached"
done
wait_pair "map['WatchAdded']"
grep -Fq "map['WatchChannel']" "$rust_dir/lib/conduit.g.dart"

checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/extra.record" "$directory/lib/renamed.record"
  mv "$directory/lib/extra.cached" "$directory/lib/renamed.cached"
done
wait_pair 'registry_builder_app/renamed.controller.conduit.dart' 'registry_builder_app/extra.controller.conduit.dart'
[[ ! -e "$rust_dir/lib/extra.controller.conduit.json" ]]

checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  find "$directory/lib" -maxdepth 1 -type f \( -name 'renamed.record' -o -name 'renamed.cached' \) -delete
done
wait_pair "map['Health']" 'WatchAdded'
[[ ! -e "$rust_dir/lib/renamed.controller.conduit.json" ]]

registry_override_capture_atomic lib/controller.record lib/channel.cached
for directory in "$stock_dir" "$rust_dir"; do
  printf '{invalid JSON\n' > "$directory/lib/controller.record"
  sed -i 's/Channel/BrokenChannel/' "$directory/lib/channel.cached"
done
for _ in $(seq 1 "$(verification_watch_poll_iterations 200)"); do
  if grep -Fq 'FormatException' "$stock_log" &&
    grep -Eq 'Rust watch cycle metrics: .* success=false' "$native_log"; then break; fi
  sleep 0.2
done
grep -Fq 'FormatException' "$stock_log" || fail 'stock registry failure missing'
grep -Fq 'FormatException' "$native_log" || fail 'native registry failure missing'
sleep 0.5
registry_override_assert_atomic

checkpoint
for directory in "$stock_dir" "$rust_dir"; do
  printf '{"controllers":["Health"]}\n' > "$directory/lib/controller.record"
  sed -i 's/BrokenChannel/Channel/' "$directory/lib/channel.cached"
done
wait_pair "map['Health']" 'BrokenChannel'

checkpoint
find "$stock_dir/lib" "$rust_dir/lib" -maxdepth 1 -name 'conduit.g.dart' -delete
wait_pair "map['Health']"

checkpoint
cp "$rust_dir/lib/conduit.g.dart" "$temporary_dir/before-non-target.dart"
printf 'non-target watch edit\n' | tee -a "$stock_dir/lib/ignored.json" >> "$rust_dir/lib/ignored.json"
# An unchanged glob membership and an unread asset need not start a stock
# cycle. Allow the watcher/debounce window, then assert retained output bytes.
sleep 1
kill -0 "$stock_pid" 2>/dev/null || fail 'stock watch exited after ignored edit'
kill -0 "$native_pid" 2>/dev/null || fail 'native watch exited after ignored edit'
registry_override_compare
cmp "$temporary_dir/before-non-target.dart" "$rust_dir/lib/conduit.g.dart"
printf 'registry-override-watch: PASS stock/native=yes ordered-glob=yes change-add-delete-rename=yes output-restore=yes atomic-recovery=yes\n'
