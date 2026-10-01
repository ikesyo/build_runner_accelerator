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
    printf 'early-catalog: retaining failure logs: %s\n' "$temporary_dir" >&2
    for log in "$temporary_dir"/*.log; do
      [[ -f "$log" ]] && tail -n 25 "$log" >&2
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
find "$fixture/lib" -name '*.g.dart' -delete
worker_pub_get "$fixture" --offline
export BUILD_RUNNER_ACCELERATOR_CACHE="$temporary_dir/cache"
export BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1
export BUILD_RUNNER_ACCELERATOR_METRICS=1
export BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=1
export BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG=1
unset BUILD_RUNNER_ACCELERATOR_PLAN_ONLY
state="$fixture/.dart_tool/build_runner_accelerator"
manifest="$state/builder-manifest.json"
entrypoint="$state/dynamic_worker.dart"
helper="$temporary_dir/workspace/tool/generate_worker_catalog.dart"
generator="$temporary_dir/workspace/tool/generate_builder_manifest.dart"
cp "$helper" "$temporary_dir/helper.before"

generate() {
  local label=$1
  rm -f -- "$manifest" "$entrypoint"
  VERIFY_COMMAND_LOG="$temporary_dir/$label.log" VERIFY_WORKSPACE="$fixture" \
    worker_run_frontend build --root "$fixture" --dart "$dart_bin" --mode rust --jobs 1
}
no_early_catalog() {
  ! grep -Fq 'Rust manifest early catalog:' "$temporary_dir/$1.log"
}

generate cold
grep -Fq 'aot_started=true' "$temporary_dir/cold.log"
grep -Fq 'Dart manifest probe: executor=worker-aot' "$temporary_dir/cold.log"
if grep -Fq 'discarding early AOT' "$temporary_dir/cold.log"; then
  exit 1
fi
cp "$manifest" "$temporary_dir/expected.json"
cp "$entrypoint" "$temporary_dir/expected.dart"
cp -R "$fixture/lib" "$temporary_dir/expected-lib"

# Snapshot hits must avoid the extra selector even when the manifest is gone.
generate warm
grep -Fq 'Rust manifest snapshot: cache=hit' "$temporary_dir/warm.log"
no_early_catalog warm
cmp "$manifest" "$temporary_dir/expected.json"
cmp "$entrypoint" "$temporary_dir/expected.dart"
export BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=0
rm -rf -- "$temporary_dir/cache/probe"
BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG=0 generate disabled
no_early_catalog disabled
grep -Fq 'Dart manifest probe: executor=source' "$temporary_dir/disabled.log"
cmp "$manifest" "$temporary_dir/expected.json"
cmp "$entrypoint" "$temporary_dir/expected.dart"
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 generate jit
no_early_catalog jit
cmp "$entrypoint" "$temporary_dir/expected.dart"
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background generate background
no_early_catalog background
cmp "$entrypoint" "$temporary_dir/expected.dart"
explicit_aot=$(find "$state/aot-sdk/bin" -type f \( -name dynamic_worker -o -name dynamic_worker.exe \) -print -quit)
[[ -n "$explicit_aot" ]]
BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH="$explicit_aot" generate explicit-aot
no_early_catalog explicit-aot
cmp "$entrypoint" "$temporary_dir/expected.dart"

# A failing helper can leave a file behind. The full generator must replace it.
cat >"$helper" <<'DART'
import 'dart:io';
void main(List<String> args) {
  File(args[1]).writeAsStringSync('void main() {}\n');
  exitCode = 1;
}
DART
generate helper-failure
grep -Fq 'Rust early catalog unavailable; using full generator' "$temporary_dir/helper-failure.log"
cmp "$manifest" "$temporary_dir/expected.json"
cmp "$entrypoint" "$temporary_dir/expected.dart"

# A valid but different early executable must never run the actual build.
sed -i '/exitCode = 1;/d' "$helper"
rm -rf -- "$temporary_dir/cache/probe"
rm -f "$state/graph-v3.bin"
find "$fixture/lib" -name '*.g.dart' -delete
generate mismatch
grep -Fq 'discarding early AOT' "$temporary_dir/mismatch.log"
grep -Fq 'Dart manifest probe: executor=source' "$temporary_dir/mismatch.log"
cmp "$entrypoint" "$temporary_dir/expected.dart"
diff -r "$fixture/lib" "$temporary_dir/expected-lib"

# Failure of the authoritative generator cannot commit a graph or outputs,
# even after a successful early compilation. Auto mode still uses stock Dart.
cp "$temporary_dir/helper.before" "$helper"
cat >"$generator" <<'DART'
void main(List<String> args) => throw StateError('full generator failure probe');
DART
rm -f "$state/graph-v3.bin"
find "$fixture/lib" -name '*.g.dart' -delete
export BUILD_RUNNER_ACCELERATOR_CACHE="$temporary_dir/failure-cache"
rm -rf -- "$state/aot-sdk"
if generate generator-failure; then
  printf 'early-catalog: failing full generator unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq 'aot_started=true' "$temporary_dir/generator-failure.log"
[[ ! -e "$manifest" && ! -e "$state/graph-v3.bin" ]]
[[ -z $(find "$fixture/lib" -name '*.g.dart' -print -quit) ]]
VERIFY_COMMAND_LOG="$temporary_dir/auto-fallback.log" VERIFY_WORKSPACE="$fixture" \
  worker_run_frontend build --root "$fixture" --dart "$dart_bin" --mode auto --jobs 1
grep -Fq 'using Dart fallback' "$temporary_dir/auto-fallback.log"
diff -r "$fixture/lib" "$temporary_dir/expected-lib"
printf 'early-catalog: PASS cold/hit/disabled/jit/background/explicit-aot/helper-failure/mismatch/generator-failure/auto-fallback\n'
