#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
package_config="$worker_package_dir/.dart_tool/package_config.json"
worker_kernel=${BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL:-"$repo_root/.toolchains/build_runner_accelerator_worker.dill"}

fail() {
  printf 'compile-worker-kernel: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_prepare --offline >/dev/null || fail 'worker pub get failed'
[[ -f "$package_config" ]] || \
  fail "Dart worker package config not found: $package_config; run dart pub get first"

mkdir -p "$(dirname -- "$worker_kernel")"
(cd "$worker_package_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" compile kernel \
    --packages="$package_config" bin/fast_build_worker.dart \
    -o "$worker_kernel" >&2)

printf '%s\n' "$worker_kernel"
