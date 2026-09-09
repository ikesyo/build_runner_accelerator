#!/usr/bin/env bash
set -euo pipefail

# Verify the AOT worker cache, its reuse, and source invalidation.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fast_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-"$repo_root/rust/target/debug/build_runner_accelerator"}
fixture_dir="$repo_root/fixtures/current_json_app"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
rust_dir="$workspace_root/fixtures/rust"
first_log="$temporary_dir/first.log"
reuse_log="$temporary_dir/reuse.log"
invalidation_log="$temporary_dir/invalidation.log"

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
  printf 'aot-worker: FAIL: %s\n' "$*" >&2
  for log in "$first_log" "$reuse_log" "$invalidation_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,260p' "$log" >&2
    fi
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -x "$fast_bin" ]] || fail "Rust frontend is not executable: $fast_bin"

mkdir -p "$rust_dir/lib"
cp "$fixture_dir/pubspec.yaml" "$rust_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$rust_dir/pubspec.lock"
cp "$fixture_dir/build.yaml" "$rust_dir/build.yaml"
cp "$fixture_dir/lib"/*.dart "$rust_dir/lib/"
ln -s "$repo_root/dart_worker" "$workspace_root/dart_worker"

(cd "$rust_dir" && PUB_CACHE="$pub_cache" "$dart_bin" \
  --suppress-analytics pub get --offline >/dev/null) || fail 'pub get failed'

run_rust() {
  local log=$1
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1 BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" \
    "$script_dir/run_rust_frontend.sh" build --root "$rust_dir" \
    --dart "$dart_bin" --mode rust >"$log" 2>&1
}

run_rust "$first_log" || fail 'initial AOT build failed'
aot_root="$rust_dir/.dart_tool/build_runner_accelerator/aot-sdk"
aot_path="$aot_root/bin/dynamic_worker"
[[ -x "$aot_path" ]] || fail 'AOT executable was not generated'
[[ -L "$aot_root/lib" ]] || fail 'AOT SDK lib facade was not generated'
[[ -L "$aot_root/version" ]] || fail 'AOT SDK version facade was not generated'
grep -Fq 'Generated:' "$first_log" || fail 'initial build did not compile AOT worker'

mv "$rust_dir/lib/model_01.g.dart" "$temporary_dir/old-model-01.g.dart"
run_rust "$reuse_log" || fail 'AOT cache reuse build failed'
[[ -f "$rust_dir/lib/model_01.g.dart" ]] || fail 'cache reuse did not regenerate output'
if grep -Fq 'Generated:' "$reuse_log"; then
  fail 'unchanged AOT worker was compiled again'
fi

printf '\n// AOT cache invalidation probe\n' \
  >>"$rust_dir/.dart_tool/build_runner_accelerator/dynamic_worker.dart"
mv "$rust_dir/lib/model_02.g.dart" "$temporary_dir/old-model-02.g.dart"
run_rust "$invalidation_log" || fail 'AOT invalidation build failed'
[[ -f "$rust_dir/lib/model_02.g.dart" ]] || \
  fail 'invalidation build did not regenerate output'
grep -Fq 'Generated:' "$invalidation_log" || \
  fail 'changed AOT worker was not recompiled'

printf 'aot-worker: first-compile=yes cache-reuse=yes invalidation-recompile=yes output=yes\n'
