#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
worker_ensure_frontend
DART_BIN=$(resolve_toolchain_dart)
: "${DART_BIN:?Dart executable could not be resolved}"
PUB_CACHE=$(resolve_toolchain_pub_cache)
export DART_BIN PUB_CACHE
python3 "$script_dir/correctness_nested_packages.py"
