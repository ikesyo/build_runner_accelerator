#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary=${SINGLE_SCHEDULER_RESULTS_DIR:-$(mktemp -d)}
workspace="$temporary/workspace"
mkdir -p "$workspace/fixtures"
worker_ensure_frontend
worker_attach "$workspace"
fail() { printf 'single-scheduler: FAIL: %s\n' "$*" >&2; exit 1; }
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then pub_get_args+=(--offline); fi
# Exercise the ordinary single-package executor with the same tracked builder.
# Fresh copies avoid changing the workspace/individual state scope in place.
for variant in single-stock single-native; do
  root="$workspace/fixtures/$variant"
  python3 "$script_dir/prepare_single_scheduler_fixture.py" "$root" "$repo_root/fixtures/workspace_scheduler_app"
  for number in $(seq -w 1 46); do printf 'input %s\n' "$number" > "$root/lib/input_$number.seed"; done
  worker_pub_get "$root" "${pub_get_args[@]}"
done
single_stock="$workspace/fixtures/single-stock"
single_native="$workspace/fixtures/single-native"
run_single_stock() {
  verification_run_stock_build "$single_stock" "scheduler/single/stock/$1" "$temporary/single-stock-$1.log" "$dart_bin" "$pub_cache" build
}
run_single_native() {
  local history="$temporary/single-history-$1"
  local delays=${SCHEDULER_DELAYS:-}
  [[ -n "$delays" ]] || delays='{"schedule_a":0}'
  mkdir -p "$history"
  VERIFY_COMMAND_LOG="$temporary/single-native-$1.log" VERIFY_WORKSPACE="$single_native" \
    SCHEDULER_HISTORY="$history" SCHEDULER_DELAYS="$delays" \
    BUILD_RUNNER_ACCELERATOR_METRICS=1 BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
    build --root "$single_native" --dart "$dart_bin" --force-jit --jobs 2
}
single_inventory() {
  python3 - "$1" "$2" <<'PY_INVENTORY'
from pathlib import Path
import hashlib, json, sys
root, output = map(Path, sys.argv[1:])
stock = 'single-stock' in str(root)
cache = root / ('.dart_tool/build/generated' if stock else '.dart_tool/build_runner_accelerator/cache')
paths = [('source/' + p.name, p) for p in (root / 'lib').glob('*.summary')]
paths += [('cache/' + str(p.relative_to(cache)), p) for p in cache.rglob('*.made.dart')]
output.write_text(json.dumps({key: hashlib.sha256(p.read_bytes()).hexdigest() for key, p in sorted(paths)}, sort_keys=True))
PY_INVENTORY
}
compare_single() {
  single_inventory "$single_stock" "$temporary/single-stock.json"
  single_inventory "$single_native" "$temporary/single-native.json"
  cmp "$temporary/single-stock.json" "$temporary/single-native.json" || fail "single-package bytes differ: $1"
}
for step in clean noop edit broad delete rename; do
  for root in "$single_stock" "$single_native"; do
    case "$step" in
      edit) printf 'single edit\n' > "$root/lib/input.seed" ;;
      broad) for input in "$root/lib/"*.seed; do printf 'broad %s\n' "${input##*/}" > "$input"; done ;;
      delete) rm "$root/lib/input_01.seed" ;;
      rename) mv "$root/lib/input_02.seed" "$root/lib/renamed.seed" ;;
    esac
  done
  run_single_stock "$step"
  if [[ "$step" == clean ]]; then
    SCHEDULER_INPUT_RENDEZVOUS=1 run_single_native "$step"
    python3 "$script_dir/check_workspace_scheduler_history.py" "$temporary/single-history-$step" 2 0 1 | tee -a "$temporary/intervals.txt"
  else
    run_single_native "$step"
  fi
  compare_single "$step"
done
single_inventory "$single_native" "$temporary/single-before.json"
cp "$single_native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/single-before.graph"
for root in "$single_stock" "$single_native"; do
  for input in "$root/lib/"*.seed; do printf 'failure peer success %s\n' "${input##*/}" > "$input"; done
  printf 'FAIL\n' > "$root/lib/input.seed"
done
if SCHEDULER_DELAYS='{"schedule_a":2000,"schedule_a|lib/input.seed":0}' run_single_native failure; then fail 'single-package failure succeeded'; fi
single_inventory "$single_native" "$temporary/single-after.json"
cmp "$temporary/single-before.json" "$temporary/single-after.json" || fail 'single-package failure published outputs'
cmp "$temporary/single-before.graph" "$single_native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'single-package failure changed graph'
python3 - "$temporary/single-history-failure" <<'PY_ADMISSION'
from pathlib import Path
import json, sys
starts = [json.loads(p.read_text()) for p in Path(sys.argv[1]).glob('*-start.json')]
assert 1 <= len(starts) <= 2, starts
assert any(row['input'] == 'lib/input.seed' for row in starts), starts
PY_ADMISSION
for root in "$single_stock" "$single_native"; do printf 'single recovery\n' > "$root/lib/input.seed"; done
run_single_stock recovery
run_single_native recovery
compare_single recovery
single_inventory "$single_native" "$temporary/single-before.json"
cp "$single_native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/single-before.graph"
printf 'worker exit\n' > "$single_native/lib/input.seed"
if SCHEDULER_CRASH=schedule_a run_single_native worker-exit; then fail 'single-package worker exit succeeded'; fi
single_inventory "$single_native" "$temporary/single-after.json"
cmp "$temporary/single-before.json" "$temporary/single-after.json" || fail 'single-package worker exit published outputs'
cmp "$temporary/single-before.graph" "$single_native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'single-package worker exit changed graph'
cp "$single_stock/lib/input.seed" "$single_native/lib/input.seed"
run_single_native worker-recovery
compare_single worker-recovery
printf 'single-scheduler: PASS stock/native=yes overlap=yes lifecycle=yes admission=yes rollback=yes\n'
