#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary=${SCHEDULER_REUSE_RESULTS_DIR:-$(mktemp -d)}
workspace="$temporary/workspace"
mkdir -p "$workspace/fixtures"
worker_ensure_frontend
worker_attach "$workspace"
fail() { printf 'scheduler-reuse: FAIL: %s\n' "$*" >&2; exit 1; }
for variant in stock native; do
  root="$workspace/fixtures/$variant"
  cp -R "$repo_root/fixtures/workspace_scheduler_app" "$root"
  rm "$root/b/lib/input.seed" "$root/c/lib/input.seed"
  for input in input second extra; do printf 'EMPTY\n' > "$root/a/lib/$input.seed"; done
  worker_pub_get "$root"
done
stock="$workspace/fixtures/stock"
native="$workspace/fixtures/native"
for step in clean noop marker; do
  if [[ "$step" == marker ]]; then
    for root in "$stock" "$native"; do printf "const marker = 'edited';\n" > "$root/a/lib/marker.dart"; done
  fi
  verification_run_stock_build "$stock" "scheduler-reuse/stock/$step" "$temporary/stock-$step.log" "$dart_bin" "$pub_cache" build --workspace
  history="$temporary/history-$step"
  mkdir -p "$history"
  VERIFY_COMMAND_LOG="$temporary/native-$step.log" VERIFY_WORKSPACE="$native" \
    SCHEDULER_HISTORY="$history" SCHEDULER_DELAYS='{"schedule_a":0}' \
    BUILD_RUNNER_ACCELERATOR_METRICS=1 BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
    build --root "$native" --dart "$dart_bin" --workspace --force-jit --jobs 1
  diff -r "$stock/a/lib" "$native/a/lib" || fail 'source bytes differ'
  python3 - "$stock" "$native" "$history" "$step" "$temporary/native-$step.log" <<'PY'
from pathlib import Path
import json, re, sys
stock, native, history = map(Path, sys.argv[1:4])
step, log = sys.argv[4:]
def cache(root, suffix):
    base=root/suffix
    return {str(p.relative_to(base)):p.read_bytes() for p in base.rglob('*.made.dart')}
assert cache(stock,'.dart_tool/build/generated') == cache(native,'.dart_tool/build_runner_accelerator/cache') == {}
starts=[json.loads(p.read_text()) for p in history.glob('*-start.json')]
assert len(starts) == (0 if step=='noop' else 3), starts
if step!='noop':
    assert {row['input'] for row in starts} == {'lib/input.seed','lib/second.seed','lib/extra.seed'}, starts
    metrics=Path(log).read_text()
    assert re.search(r'worker_initializes_total=1\b',metrics), metrics
    assert re.search(r'resolver_resets_total=0\b',metrics), metrics
PY
done
printf 'scheduler-reuse: PASS stock/native=yes resolver-dependencies=yes options=yes resets=0\n'
