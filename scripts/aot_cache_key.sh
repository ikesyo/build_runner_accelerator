#!/usr/bin/env bash
set -euo pipefail

# Print the portable cache identity for the generated AOT worker.
# The first argument is the build_runner workspace root; the current directory
# is used when it is omitted.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
fast_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-"$repo_root/rust/target/debug/build_runner_accelerator"}
workspace_root=${1:-"$PWD"}

[[ -x "$fast_bin" ]] || {
  printf 'Rust frontend is not executable: %s\n' "$fast_bin" >&2
  exit 1
}

BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/run_rust_frontend.sh" \
  aot-cache-key --root "$workspace_root" --dart "$dart_bin" --mode rust
