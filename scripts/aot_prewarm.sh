#!/usr/bin/env bash
set -euo pipefail

# Generate and synchronously compile the AOT worker for a CI prewarm job.
# Cache restore/save is intentionally left to the CI provider.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
fast_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-"$repo_root/rust/target/debug/build_runner_accelerator"}
workspace_root=${1:-"$PWD"}

[[ -x "$fast_bin" ]] || {
  printf 'Rust frontend is not executable: %s\n' "$fast_bin" >&2
  exit 1
}

cache_key=$(DART_BIN="$dart_bin" BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" \
  "$script_dir/aot_cache_key.sh" "$workspace_root")

BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/run_rust_frontend.sh" \
  aot-prewarm --root "$workspace_root" --dart "$dart_bin" --mode rust

aot_root="$workspace_root/.dart_tool/build_runner_accelerator/aot-sdk"
aot_path="$aot_root/bin/dynamic_worker"
if [[ ! -f "$aot_path" && -f "$aot_path.exe" ]]; then
  aot_path="$aot_path.exe"
fi
[[ -x "$aot_path" ]] || {
  printf 'AOT executable was not generated: %s\n' "$aot_path" >&2
  exit 1
}

printf 'AOT prewarm complete\n'
printf 'AOT cache key: %s\n' "$cache_key"
printf 'AOT cache root: %s\n' '.dart_tool/build_runner_accelerator/aot-sdk'
printf 'Generated worker: %s\n' '.dart_tool/build_runner_accelerator/dynamic_worker.dart'
printf 'Builder manifest: %s\n' '.dart_tool/build_runner_accelerator/builder-manifest.json'

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'aot_cache_key=%s\n' "$cache_key"
    printf 'aot_cache_root=%s\n' '.dart_tool/build_runner_accelerator/aot-sdk'
    printf 'generated_worker=.dart_tool/build_runner_accelerator/dynamic_worker.dart\n'
    printf 'builder_manifest=.dart_tool/build_runner_accelerator/builder-manifest.json\n'
  } >>"$GITHUB_OUTPUT"
fi
