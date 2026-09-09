#!/usr/bin/env bash
set -euo pipefail

# Verify the CI-style AOT prewarm contract across two relocated workspaces:
# prewarm one workspace, copy only the generated worker/AOT cache, and build
# the second workspace without recompiling the AOT executable.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
fixture_dir="$repo_root/fixtures/current_json_app"
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
fast_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-"$repo_root/rust/target/debug/build_runner_accelerator"}
temporary_dir=$(mktemp -d)
workspace_parent="$temporary_dir/workspaces"
workspace_a="$workspace_parent/a"
workspace_b="$workspace_parent/b"
prewarm_log="$temporary_dir/prewarm.log"
build_log="$temporary_dir/build.log"

remove_tree() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" ]]; then
    rm -f -- "$path"
    return 0
  fi
  find "$path" -depth -type f -delete
  find "$path" -depth -type l -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'aot-prewarm: FAIL: %s\n' "$*" >&2
  for log in "$prewarm_log" "$build_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,260p' "$log" >&2
    fi
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -x "$fast_bin" ]] || fail "Rust frontend is not executable: $fast_bin"

mkdir -p "$workspace_parent"
ln -s "$repo_root/dart_worker" "$temporary_dir/dart_worker"

setup_workspace() {
  local root=$1
  mkdir -p "$root/lib"
  cp "$fixture_dir/pubspec.yaml" "$root/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$root/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$root/build.yaml"
  cp "$fixture_dir/lib"/*.dart "$root/lib/"
  (cd "$root" && PUB_CACHE="$pub_cache" "$dart_bin" \
    --suppress-analytics pub get --offline >/dev/null) || fail "pub get failed: $root"
}

run_runner() {
  local root=$1
  local log=$2
  shift 2
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1 BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" \
    "$script_dir/run_rust_frontend.sh" \
    "$@" --root "$root" --dart "$dart_bin" --mode rust >"$log" 2>&1
}

setup_workspace "$workspace_a"
setup_workspace "$workspace_b"

key_a=$(DART_BIN="$dart_bin" BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" \
  "$script_dir/aot_cache_key.sh" "$workspace_a") || fail 'cache key generation failed'
run_runner "$workspace_a" "$prewarm_log" aot-prewarm || fail 'AOT prewarm failed'

generated_dir="$workspace_a/.dart_tool/build_runner_accelerator"
aot_root="$generated_dir/aot-sdk"
aot_path="$aot_root/bin/dynamic_worker"
if [[ ! -f "$aot_path" && -f "$aot_path.exe" ]]; then
  aot_path="$aot_path.exe"
fi
[[ -x "$aot_path" ]] || fail 'prewarm did not publish an executable'
[[ -f "$aot_path.d" ]] || fail 'prewarm did not publish a depfile'
[[ -f "$aot_path.sdk" ]] || fail 'prewarm did not publish SDK metadata'

key_b=$(DART_BIN="$dart_bin" BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" \
  "$script_dir/aot_cache_key.sh" "$workspace_b") || fail 'second cache key generation failed'
[[ "$key_a" == "$key_b" ]] || fail 'relocated workspaces produced different cache keys'

sdk_probe="$temporary_dir/sdk-probe"
mkdir -p "$sdk_probe/lib/_internal"
cp "$repo_root/.toolchains/dart/dart-sdk/lib/_internal/allowed_experiments.json" \
  "$sdk_probe/lib/_internal/allowed_experiments.json"
cp "$repo_root/.toolchains/dart/dart-sdk/version" "$sdk_probe/version"
sdk_key_a=$(DART_SDK="$sdk_probe" DART_BIN="$dart_bin" \
  BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/aot_cache_key.sh" "$workspace_a") || \
  fail 'SDK identity probe key generation failed'
printf '\nSDK identity probe\n' >>"$sdk_probe/version"
sdk_key_b=$(DART_SDK="$sdk_probe" DART_BIN="$dart_bin" \
  BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/aot_cache_key.sh" "$workspace_a") || \
  fail 'changed SDK identity probe key generation failed'
[[ "$sdk_key_a" != "$sdk_key_b" ]] || fail 'SDK change did not change cache key'

mkdir -p "$workspace_b/.dart_tool/build_runner_accelerator"
cp -a "$workspace_a/.dart_tool/build_runner_accelerator/aot-sdk" \
  "$workspace_b/.dart_tool/build_runner_accelerator/"
cp "$workspace_a/.dart_tool/build_runner_accelerator/dynamic_worker.dart" \
  "$workspace_b/.dart_tool/build_runner_accelerator/"
cp "$workspace_a/.dart_tool/build_runner_accelerator/builder-manifest.json" \
  "$workspace_b/.dart_tool/build_runner_accelerator/"

# A cache restore can leave SDK facade symlinks pointing at the prewarm
# runner's absolute SDK path. The next invocation must repair them against the
# current runner's SDK before deciding whether the executable is reusable.
rm -f -- "$workspace_b/.dart_tool/build_runner_accelerator/aot-sdk/lib" \
  "$workspace_b/.dart_tool/build_runner_accelerator/aot-sdk/version"
ln -s "$temporary_dir/missing-sdk/lib" \
  "$workspace_b/.dart_tool/build_runner_accelerator/aot-sdk/lib"
ln -s "$temporary_dir/missing-sdk/version" \
  "$workspace_b/.dart_tool/build_runner_accelerator/aot-sdk/version"

run_runner "$workspace_b" "$build_log" build || fail 'cached AOT build failed'
[[ -f "$workspace_b/lib/model_01.g.dart" ]] || fail 'cached AOT build produced no output'
if grep -Fq 'Generated:' "$build_log"; then
  fail 'cached AOT build compiled the worker again'
fi

printf '\n// AOT prewarm relocation probe\n' \
  >>"$workspace_b/.dart_tool/build_runner_accelerator/dynamic_worker.dart"
rm -f -- "$workspace_b/lib/model_02.g.dart"
run_runner "$workspace_b" "$build_log" build || fail 'invalidation build failed'
[[ -f "$workspace_b/lib/model_02.g.dart" ]] || fail 'invalidation build produced no output'
grep -Fq 'Generated:' "$build_log" || fail 'changed worker did not invalidate AOT cache'

printf 'aot-prewarm: compile-wait=yes cache-key-portable=yes cache-reuse=yes sdk-key-invalidation=yes invalidation=yes\n'
