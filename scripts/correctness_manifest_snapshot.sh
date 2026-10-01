#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
temporary_dir=$(mktemp -d)
cleanup() {
  local status=$?
  if ((status != 0)); then
    printf 'manifest-snapshot: retaining failure logs: %s\n' "$temporary_dir" >&2
    for log in "$temporary_dir"/*.log; do
      [[ -f "$log" ]] && tail -n 30 "$log" >&2
    done
  else
    rm -rf -- "$temporary_dir"
  fi
}
trap cleanup EXIT
worker_ensure_frontend
worker_prepare
worker_attach "$temporary_dir/workspace"
fixture="$temporary_dir/workspace/fixtures/app"
mkdir -p "$fixture"
cp "$repo_root/fixtures/json_serializable_app/pubspec.yaml" "$fixture/"
cp "$repo_root/fixtures/json_serializable_app/pubspec.lock" "$fixture/"
cp -R "$repo_root/fixtures/json_serializable_app/lib" "$fixture/"
worker_pub_get "$fixture" --offline
export BUILD_RUNNER_ACCELERATOR_CACHE="$temporary_dir/cache"
export BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0
export BUILD_RUNNER_ACCELERATOR_PLAN_ONLY=1
export BUILD_RUNNER_ACCELERATOR_METRICS=1
export BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=1
manifest="$fixture/.dart_tool/build_runner_accelerator/builder-manifest.json"
entrypoint="$fixture/.dart_tool/build_runner_accelerator/dynamic_worker.dart"

generate() {
  local label=$1 expected=$2
  rm -f -- "$manifest" "$entrypoint"
  VERIFY_COMMAND_LOG="$temporary_dir/$label.log" VERIFY_WORKSPACE="$fixture" \
    worker_run_frontend build --root "$fixture" --dart "$dart_bin" --mode rust
  grep -Fq -- "$expected" "$temporary_dir/$label.log"
}

generate cold 'Rust manifest snapshot: cache=miss'
cp "$manifest" "$temporary_dir/expected.json"
cp "$entrypoint" "$temporary_dir/expected.dart"
generate warm 'Rust manifest snapshot: cache=hit'
cmp "$manifest" "$temporary_dir/expected.json"
cmp "$entrypoint" "$temporary_dir/expected.dart"

# A dependency edit must invalidate compiled code even when its mtime is
# restored. The generated worker and manifest should remain identical.
dependency="$temporary_dir/workspace/lib/src/manifest/source.dart"
cp -p "$dependency" "$temporary_dir/dependency.before"
printf '\n// Snapshot invalidation probe.\n' >>"$dependency"
touch -r "$temporary_dir/dependency.before" "$dependency"
generate dependency 'Rust manifest snapshot: cache=miss'
cmp "$manifest" "$temporary_dir/expected.json"
cmp "$entrypoint" "$temporary_dir/expected.dart"
generate dependency-warm 'Rust manifest snapshot: cache=hit'

# DART_SDK selects worker AOT preparation inputs; generator kernels must use
# the SDK of the actual --dart executable instead of that independent override.
mkdir -p "$temporary_dir/override-sdk/lib"
DART_SDK="$temporary_dir/override-sdk" \
  generate sdk-override 'Rust manifest snapshot: cache=hit'

# Runtime build configuration must be reread without recompiling the kernel.
cat >"$fixture/build.yaml" <<'YAML'
targets:
  $default:
    builders:
      json_serializable:
        options:
          explicit_to_json: true
YAML
generate configuration 'Rust manifest snapshot: cache=hit'
python3 - "$manifest" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
assert any(b['options'].get('explicit_to_json') is True for b in manifest['builders'])
PY
rm "$fixture/build.yaml"

kernel=$(find "$temporary_dir/cache/manifest-kernel" -name generator.dill -type f)
printf 'corrupt' >"$kernel"
generate corrupt 'Rust manifest snapshot: cache=miss'
cmp "$manifest" "$temporary_dir/expected.json"

printf 'not a directory' >"$temporary_dir/unwritable-cache"
BUILD_RUNNER_ACCELERATOR_CACHE="$temporary_dir/unwritable-cache" \
  generate unavailable 'Rust manifest snapshot unavailable; using Dart source'
cmp "$manifest" "$temporary_dir/expected.json"
BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=0 \
  generate disabled 'Rust plan only:'
cmp "$manifest" "$temporary_dir/expected.json"
cmp "$entrypoint" "$temporary_dir/expected.dart"
printf 'manifest-snapshot: PASS cold/hit/code-edit/sdk-override/config-edit/corruption/unavailable/disabled\n'
