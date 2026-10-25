#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
worker_ensure_frontend
export DART_BIN="$worker_dart_bin"
export PUB_CACHE="$worker_pub_cache"
python3 "$script_dir/correctness_shared_parts.py" "$@"
