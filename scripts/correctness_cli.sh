#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
worker_ensure_frontend
export DART_BIN="$(resolve_toolchain_dart)" PUB_CACHE="$(resolve_toolchain_pub_cache)"
python3 "$script_dir/correctness_cli.py"
