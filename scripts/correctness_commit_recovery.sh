#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
worker_ensure_frontend
worker_prepare
cargo_bin=$(resolve_toolchain_cargo)
artifacts=$(mktemp)
trap 'rm -f -- "$artifacts"' EXIT
env RUSTUP_HOME="$worker_rustup_home" CARGO_HOME="$worker_cargo_home" \
  "$cargo_bin" test --locked --manifest-path "$repo_root/rust/Cargo.toml" \
  --no-run --message-format=json >"$artifacts"
test_binary=$(python3 - "$artifacts" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    item = json.loads(line)
    if item.get('reason') == 'compiler-artifact' and item.get('profile', {}).get('test') and item.get('executable'):
        print(item['executable'])
PY
)
python3 "$script_dir/correctness_commit_recovery.py" \
  --test-binary "$test_binary" --native "$BUILD_RUNNER_ACCELERATOR_BIN" \
  --dart "$worker_dart_bin"
