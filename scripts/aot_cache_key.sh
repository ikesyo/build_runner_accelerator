#!/usr/bin/env bash
set -euo pipefail

# Print the portable cache identity for the generated AOT worker.
# The first argument is the build_runner workspace root; the current directory
# is used when it is omitted.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
workspace_root=${1:-"$PWD"}

worker_require_frontend

# The bounded verification wrapper records command stdout in its log, so
# explicitly recover the one machine-readable key for callers using $(...).
key_log=$(mktemp)
trap 'rm -f -- "$key_log"' EXIT
VERIFY_COMMAND_LOG="$key_log" worker_run_frontend \
  aot-cache-key --root "$workspace_root" --dart "$dart_bin" --mode rust
awk '/^build-runner-accelerator-aot-/ { key = $0; count++ }
     END { if (count == 1) print key; else exit 1 }' "$key_log"
