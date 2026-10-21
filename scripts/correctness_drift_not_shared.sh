#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/drift_analyzer_app"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-drift-not-shared.XXXXXX")
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
results_dir="$temporary_dir/results"
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

remove_tree() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" ]]; then
    find "$path" -maxdepth 0 -type l -delete
    return 0
  fi
  find "$path" -depth -type f -delete
  find "$path" -depth -type l -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs: %s\n' "$temporary_dir" >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'drift-not-shared-compatibility: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,260p' "$log" >&2
  done
  exit 1
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp -s "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_same_tree() {
  local expected_root=$1
  local actual_root=$2
  [[ -d "$expected_root" ]] || fail "missing expected directory: $expected_root"
  [[ -d "$actual_root" ]] || fail "missing actual directory: $actual_root"
  local expected_files actual_files file
  expected_files=$(cd "$expected_root" && find . -type f -printf '%P\n' | sort)
  actual_files=$(cd "$actual_root" && find . -type f -printf '%P\n' | sort)
  [[ "$expected_files" == "$actual_files" ]] || {
    diff -u <(printf '%s\n' "$expected_files") <(printf '%s\n' "$actual_files") >&2 || true
    fail "generated file lists differ: $expected_root vs $actual_root"
  }
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    assert_same_file "$expected_root/$file" "$actual_root/$file"
  done <<<"$expected_files"
}

assert_missing() {
  local path=$1
  [[ ! -e "$path" ]] || fail "unexpected stale output: $path"
}

compare_outputs() {
  local label=$1
  local schema_stem=${2:-schema}
  local stock_cache="$stock_dir/.dart_tool/build/generated/drift_analyzer_app"
  local rust_cache="$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app"
  assert_same_tree "$stock_cache" "$rust_cache"
  assert_same_tree "$stock_dir/lib" "$rust_dir/lib"
  assert_same_file "$stock_dir/lib/database.drift.dart" "$rust_dir/lib/database.drift.dart"
  for suffix in \
    drift_elements.json drift_module.json types.temp.dart; do
    [[ -f "$stock_cache/lib/${schema_stem}.drift.$suffix" ]] || \
      fail "$label missing stock analyzer artifact: ${schema_stem}.drift.$suffix"
  done
  [[ -f "$stock_cache/lib/${schema_stem}.drift_prep.json" ]] || \
    fail "$label missing physical preparing artifact"
  [[ -f "$stock_cache/lib/${schema_stem}.expr.temp.dart" ]] || \
    fail "$label missing physical expression helper"
  grep -Fq 'module=present:' "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label did not expose the module artifact to a later normal builder"
  grep -Fq 'types=present:' "$rust_dir/lib/${schema_stem}.drift_analyzer_probe.txt" || \
    fail "$label did not expose the optional type helper before cleanup"
}

assert_manifest_contract() {
  local manifest=$1
  MANIFEST_PATH="$manifest" python3 - <<'PY' || exit 1
import json
import os

with open(os.environ['MANIFEST_PATH'], encoding='utf-8') as manifest_file:
    builders = json.load(manifest_file)['builders']
by_id = {builder['id']: builder for builder in builders}
required = [
    'drift_dev:preparing_builder',
    'drift_dev:analyzer#factory0',
    'drift_dev:analyzer#factory1',
    'drift_dev:not_shared',
    'drift_analyzer_app:analyzer_probe',
    'drift_dev:cleanup',
]
missing = [builder_id for builder_id in required if builder_id not in by_id]
if missing:
    raise AssertionError(f'missing builders: {missing}')

normal = required[:-1]
phases = [by_id[builder_id]['phase'] for builder_id in normal]
if phases != sorted(phases) or len(set(phases)) != len(phases):
    raise AssertionError(f'unexpected normal phase order: {dict(zip(normal, phases))}')

not_shared = by_id['drift_dev:not_shared']
if not_shared['build_to'] != 'source':
    raise AssertionError(f'not_shared does not build to source: {not_shared}')
if not_shared['is_optional']:
    raise AssertionError(f'not_shared unexpectedly became an optional builder: {not_shared}')
if not_shared['required_input_suffixes'] != ['.drift_prep.json']:
    raise AssertionError(f'unexpected not_shared required inputs: {not_shared}')
if not_shared['extensions'] != [{
    'input_suffix': '.dart',
    'input_match': 'suffix',
    'input_anchored': False,
    'output_suffixes': ['.drift.dart'],
}]:
    raise AssertionError(f'unexpected not_shared mapping: {not_shared}')

cleanup = by_id['drift_dev:cleanup']
if cleanup['kind'] != 'post_process':
    raise AssertionError(f'cleanup is not post-process: {cleanup}')
if cleanup['input_extensions'] != [
    '.temp.dart', '.drift_prep.json', '.drift_module.json'
]:
    raise AssertionError(f'cleanup did not retain full runtime inputs: {cleanup}')
PY
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

mkdir -p "$fixture_root" "$results_dir"
worker_attach "$workspace_root"
mkdir -p "$stock_dir" "$rust_dir"
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.not_shared.yaml" "$directory/build.yaml"
  cp -R "$fixture_dir/lib" "$directory/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}" || fail "pub get failed in $directory"
done

run_stock() {
  local log=$1
  verification_run_stock_build "$stock_dir" "build/stock" "$log" \
    "$dart_bin" "$pub_cache" build
}

run_rust() {
  local log=$1
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$rust_dir" \
    worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" --jobs 1
}

run_stock "$temporary_dir/clean.stock.log" || fail 'stock clean build failed'
run_rust "$temporary_dir/clean.rust.log" || fail 'native clean build failed'
compare_outputs clean
assert_manifest_contract \
  "$rust_dir/.dart_tool/build_runner_accelerator/builder-manifest.json"
grep -Fq '"postProcessResults"' "$stock_dir/.dart_tool/build/asset_graph.json" || \
  fail 'stock graph did not record post-process cleanup'
grep -Fq '"deletedPrimaryInput",true' "$stock_dir/.dart_tool/build/asset_graph.json" || \
  fail 'stock cleanup did not logically delete its primary inputs'

run_stock "$temporary_dir/no-op.stock.log" || fail 'stock no-op failed'
run_rust "$temporary_dir/no-op.rust.log" || fail 'native no-op failed'
compare_outputs no-op
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || \
  fail 'native no-op was not reported'

sed -i 's/class AppDatabase/class AppDatabaseV2/' \
  "$stock_dir/lib/database.dart" "$rust_dir/lib/database.dart"
run_stock "$temporary_dir/dart-change.stock.log" || fail 'stock Dart change failed'
run_rust "$temporary_dir/dart-change.rust.log" || fail 'native Dart change failed'
compare_outputs dart-change

sed -i 's/name TEXT NOT NULL,/name TEXT NOT NULL, email TEXT NOT NULL,/' \
  "$stock_dir/lib/schema.drift" "$rust_dir/lib/schema.drift"
run_stock "$temporary_dir/sql-change.stock.log" || fail 'stock SQL change failed'
run_rust "$temporary_dir/sql-change.rust.log" || fail 'native SQL change failed'
compare_outputs sql-change

for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/lib/schema.drift" "$directory/lib/extra.drift"
  sed -i "s/{'schema.drift'}/{'schema.drift', 'extra.drift'}/" \
    "$directory/lib/database.dart"
done
run_stock "$temporary_dir/add.stock.log" || fail 'stock input addition failed'
run_rust "$temporary_dir/add.rust.log" || fail 'native input addition failed'
compare_outputs add extra

for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/extra.drift" "$directory/lib/renamed.drift"
  sed -i 's/extra.drift/renamed.drift/' "$directory/lib/database.dart"
done
run_stock "$temporary_dir/rename.stock.log" || fail 'stock input rename failed'
run_rust "$temporary_dir/rename.rust.log" || fail 'native input rename failed'
compare_outputs rename renamed
assert_missing "$rust_dir/lib/extra.drift_analyzer_probe.txt"
assert_missing "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib/extra.drift.drift_module.json"

for directory in "$stock_dir" "$rust_dir"; do
  sed -i "s/, 'renamed.drift'//" "$directory/lib/database.dart"
  find "$directory/lib" -maxdepth 1 -type f -name 'renamed.drift' -delete
done
run_stock "$temporary_dir/delete.stock.log" || fail 'stock input deletion failed'
run_rust "$temporary_dir/delete.rust.log" || fail 'native input deletion failed'
compare_outputs delete
assert_missing "$rust_dir/lib/renamed.drift_analyzer_probe.txt"
assert_missing "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib/renamed.drift.drift_module.json"

# The not_shared builder emits its source output before fatal_warnings raises.
# Native must retain the preceding successful output/cache/graph transaction.
cp "$rust_dir/lib/database.drift.dart" "$results_dir/database.before-failure.dart"
cp -R "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app" \
  "$results_dir/cache-before-failure"
cp "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" \
  "$results_dir/graph-before-failure.bin"
for directory in "$stock_dir" "$rust_dir"; do
  sed -i "s/@DriftDatabase(include: {'schema.drift'})/@DriftDatabase(include: {'schema.drift'}, queries: {'brokenQuery': 'SELECT * FROM missing_table'})/" \
    "$directory/lib/database.dart"
  cp "$fixture_dir/build.not_shared.failure.yaml" "$directory/build.yaml"
done
if run_stock "$temporary_dir/failure.stock.log"; then
  fail 'stock failure probe unexpectedly succeeded'
fi
if run_rust "$temporary_dir/failure.rust.log"; then
  fail 'native failure probe unexpectedly succeeded'
fi
grep -Fq 'Drift emitted warnings and the `fatal_warnings` build option is enabled.' \
  "$temporary_dir/failure.rust.log" || \
  fail 'native failure did not come from not_shared fatal warnings'
assert_same_file "$results_dir/database.before-failure.dart" \
  "$rust_dir/lib/database.drift.dart"
assert_same_tree "$results_dir/cache-before-failure" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app"
assert_same_file "$results_dir/graph-before-failure.bin" \
  "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin"

for directory in "$stock_dir" "$rust_dir"; do
  sed -i "/queries: {'brokenQuery'/s/, queries: {'brokenQuery': 'SELECT \* FROM missing_table'}//" \
    "$directory/lib/database.dart"
  cp "$fixture_dir/build.not_shared.yaml" "$directory/build.yaml"
done
run_stock "$temporary_dir/recovery.stock.log" || fail 'stock recovery failed'
run_rust "$temporary_dir/recovery.rust.log" || fail 'native recovery failed'
compare_outputs recovery

printf 'drift-not-shared-compatibility: not-shared=yes cleanup=full logical-delete=yes physical-cache=yes normal-visibility=yes clean-noop=yes dart-sql-change=yes add-delete-rename=yes stale-cleanup=yes failure-atomic=yes recovery=yes\n'
