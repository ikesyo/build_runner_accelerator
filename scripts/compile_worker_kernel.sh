#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
package_config="$repo_root/dart_worker/.dart_tool/package_config.json"
worker_kernel=${FAST_BUILD_RUNNER_WORKER_KERNEL:-"$repo_root/.toolchains/fast_build_runner_worker.dill"}

fail() {
  printf 'compile-worker-kernel: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -f "$package_config" ]] || \
  fail "Dart worker package config not found: $package_config; run dart pub get first"

mkdir -p "$(dirname -- "$worker_kernel")"
(cd "$repo_root/dart_worker" && \
  PUB_CACHE="$pub_cache" "$dart_bin" compile kernel \
    --packages="$package_config" bin/fast_build_worker.dart \
    -o "$worker_kernel" >&2)

printf '%s\n' "$worker_kernel"
