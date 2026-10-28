#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary=${SCHEDULER_RESULTS_DIR:-$(mktemp -d)}
mkdir -p "$temporary"
workspace="$temporary/workspace"
stock="$workspace/fixtures/stock"
native="$workspace/fixtures/native"
trap 'status=$?; printf "workspace-scheduler: results=%s status=%s\n" "$temporary" "$status" >&2' EXIT
fail() { printf 'workspace-scheduler: FAIL: %s\n' "$*" >&2; exit 1; }
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then pub_get_args+=(--offline); fi
worker_ensure_frontend
worker_prepare "${pub_get_args[@]}"
mkdir -p "$workspace/fixtures"
worker_attach "$workspace"
cp -R "$repo_root/fixtures/workspace_scheduler_app" "$stock"
cp -R "$repo_root/fixtures/workspace_scheduler_app" "$native"
worker_pub_get "$stock" "${pub_get_args[@]}"
worker_pub_get "$native" "${pub_get_args[@]}"
# Use exactly the same solved dependency versions for both implementations.
cmp "$stock/pubspec.lock" "$native/pubspec.lock" || fail 'dependency solutions differ'
"$dart_bin" --version > "$temporary/toolchain.txt" 2>&1
RUSTUP_HOME="$worker_rustup_home" CARGO_HOME="$worker_cargo_home" "$(resolve_toolchain_cargo)" --version >> "$temporary/toolchain.txt"
run_stock() {
  verification_run_stock_build "$stock" "workspace-scheduler/stock/$1" "$temporary/stock-$1.log" "$dart_bin" "$pub_cache" build --workspace
}
run_native() {
  local label=$1 jobs=$2 rendezvous=${3:-0}
  local history="$temporary/history-$label"
  mkdir -p "$history"
  VERIFY_COMMAND_LOG="$temporary/native-$label.log" VERIFY_WORKSPACE="$native" \
    SCHEDULER_HISTORY="$history" SCHEDULER_RENDEZVOUS="$rendezvous" \
    SCHEDULER_INPUT_RENDEZVOUS="$(( rendezvous == 1 && jobs == 3 ))" \
    BUILD_RUNNER_ACCELERATOR_METRICS=1 BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
    build --root "$native" --dart "$dart_bin" --workspace --force-jit --jobs "$jobs"
}
check_history() {
  python3 "$script_dir/check_workspace_scheduler_history.py" "$temporary/history-$1" "$2" "${3:-0}" "${4:-0}" | tee -a "$temporary/intervals.txt"
}
compare() {
  local package
  for package in a b c helper; do
    diff -r "$stock/$package/lib" "$native/$package/lib" || fail "source bytes differ: $1/$package"
  done
  local reference="$stock/.dart_tool/build/generated" actual="$native/.dart_tool/build_runner_accelerator/cache"
  mkdir -p "$temporary/stock-cache" "$temporary/native-cache"
  # Compare only the fixture's declared cache assets (stock keeps unrelated
  # bootstrap/compiler state outside this inventory).
  python3 - "$reference" "$actual" <<'PY'
from pathlib import Path
import sys
left, right = map(Path, sys.argv[1:])
def assets(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*.made.dart')}
a, b = assets(left), assets(right)
assert a == b, (sorted(a), sorted(b))
PY
}
run_stock clean
clean_native_state() {
  rm -rf "$native/.dart_tool/build_runner_accelerator/cache"
  rm -f "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$native/.dart_tool/build_runner_accelerator/workspace-mode"
  find "$native" -name '*.summary' -delete
}
for jobs in 1 2 3; do
  # Fresh native state and outputs for each bounded-concurrency observation.
  clean_native_state
  run_native "clean-$jobs" "$jobs" "$(( jobs > 1 ))"
  compare "clean-$jobs"
  check_history "clean-$jobs" "$jobs" "$(( jobs > 1 ))" "$(( jobs == 3 ))"
done
clean_native_state
BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0 run_native no-shared-store 2 1
compare no-shared-store
check_history no-shared-store 2 1
# Distinct package options are checked independently of the stock comparison.
grep -Fq 'a input:a-seed:true' "$native/a/lib/input.summary" || fail 'a options/isRoot differ'
grep -Fq 'b input:b-seed:true' "$native/b/lib/input.summary" || fail 'b options/isRoot differ'
grep -Fq 'a input:a-seed:true' "$native/c/lib/input.summary" || fail 'dependency cache output was not visible'
for step in noop edit broad delete rename failure recovery helper target; do
  case "$step" in
    noop) cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/noop.graph" ;;
    edit) for base in "$stock" "$native"; do printf 'a edited\n' > "$base/a/lib/input.seed"; done ;;
    broad) for base in "$stock" "$native"; do
      printf 'a broad\n' > "$base/a/lib/input.seed"
      printf 'a second broad\n' > "$base/a/lib/second.seed"
      printf 'b broad\n' > "$base/b/lib/input.seed"
    done ;;
    delete) rm "$stock/a/lib/second.seed" "$native/a/lib/second.seed" ;;
    rename) for base in "$stock" "$native"; do mv "$base/b/lib/input.seed" "$base/b/lib/renamed.seed"; done ;;
    failure)
      cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/before.graph"
      cp -R "$native/a/lib" "$temporary/before-a"
      cp -R "$native/b/lib" "$temporary/before-b"
      cp -R "$native/c/lib" "$temporary/before-c"
      cp -R "$native/.dart_tool/build_runner_accelerator/cache" "$temporary/before-cache"
      for base in "$stock" "$native"; do
        printf 'a staged success\n' > "$base/a/lib/input.seed"
        printf 'FAIL\n' > "$base/b/lib/renamed.seed"
      done
      if run_stock failure; then fail 'stock accepted failure'; fi
      if run_native failure 2; then fail 'native accepted failure'; fi
      cmp "$temporary/before.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'failure changed graph'
      for package in a b c; do
        diff -r --exclude='*.seed' "$temporary/before-$package" "$native/$package/lib" || fail 'failure changed source outputs'
      done
      diff -r "$temporary/before-cache" "$native/.dart_tool/build_runner_accelerator/cache" || fail 'failure changed cache outputs'
      continue ;;
    recovery) for base in "$stock" "$native"; do printf 'b recovered\n' > "$base/b/lib/renamed.seed"; done ;;
    helper) for base in "$stock" "$native"; do printf 'helper input\n' > "$base/helper/lib/input.seed"; done ;;
    target) for base in "$stock" "$native"; do printf 'extra input\n' > "$base/a/lib/extra.seed"; done ;;
  esac
  run_stock "$step"
  run_native "$step" 2
  compare "$step"
  check_history "$step" 2
  if [[ "$step" == noop ]]; then
    cmp "$temporary/noop.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'no-op changed graph'
    [[ -z "$(find "$temporary/history-noop" -type f -print -quit)" ]] || fail 'no-op ran actions'
  fi
done
grep -Fq 'helper input:helper-seed:false' "$native/.dart_tool/build_runner_accelerator/cache/schedule_helper/lib/input.made.dart" || fail 'non-output package options/isRoot differ'
grep -Fq 'extra input:extra-seed:true' "$native/a/lib/extra.summary" || fail 'target-specific options differ'
# A worker exiting during a concurrent wave must join its successful peer and
# preserve the same publication boundary as an ordinary builder exception.
cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/crash.graph"
cp -R "$native/.dart_tool/build_runner_accelerator/cache" "$temporary/crash-cache"
for package in a b c; do cp -R "$native/$package/lib" "$temporary/crash-$package"; done
printf 'crash peer success\n' > "$native/a/lib/input.seed"
printf 'crash request\n' > "$native/b/lib/renamed.seed"
if SCHEDULER_CRASH=schedule_b run_native worker-exit 2; then fail 'worker exit succeeded'; fi
cmp "$temporary/crash.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'worker exit changed graph'
diff -r "$temporary/crash-cache" "$native/.dart_tool/build_runner_accelerator/cache" || fail 'worker exit changed cache'
for package in a b c; do
  diff -r --exclude='*.seed' "$temporary/crash-$package" "$native/$package/lib" || fail 'worker exit changed outputs'
done
for package in a b; do cp "$stock/$package/lib/"*.seed "$native/$package/lib/"; done
run_native worker-recovery 2
compare worker-recovery
printf 'workspace-scheduler: PASS stock/native=yes jobs=1,2,3 overlap=yes dependency=yes resolver=yes options=yes rollback=yes lifecycle=yes\n'
