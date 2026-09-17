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
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-drift-analyzer.XXXXXX")
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
  printf 'drift-analyzer-compatibility: FAIL: %s\n' "$*" >&2
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
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
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
    printf '%s\n' "--- generated file list mismatch ---" >&2
    diff -u <(printf '%s\n' "$expected_files") <(printf '%s\n' "$actual_files") >&2 || true
    fail "generated file lists differ: $expected_root vs $actual_root"
  }
  [[ -n "$expected_files" ]] || return 0
  while IFS= read -r file; do
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
  assert_same_tree \
    "$stock_dir/.dart_tool/build/generated/drift_analyzer_app" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app"
  assert_same_tree "$stock_dir/lib" "$rust_dir/lib"

  local generated_stock="$stock_dir/.dart_tool/build/generated/drift_analyzer_app/lib"
  local generated_rust="$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib"
  [[ -f "$generated_stock/database.dart.drift_elements.json" ]] || \
    fail "$label missing discover output"
  [[ -f "$generated_stock/database.dart.drift_module.json" ]] || \
    fail "$label missing analyzer module output"
  [[ -f "$generated_stock/${schema_stem}.drift.types.temp.dart" ]] || \
    fail "$label missing generated type helper output"
  [[ -f "$generated_rust/${schema_stem}.drift.types.temp.dart" ]] || \
    fail "$label missing native generated type helper output"
  grep -Fq 'elements=present:' "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label did not read discover cache artifact"
  grep -Fq 'module=present:' "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label did not read analyzer cache artifact"
  grep -Fq 'types=present:' "$rust_dir/lib/${schema_stem}.drift_analyzer_probe.txt" || \
    fail "$label did not observe the optional type helper"
  grep -Fq 'input_library=drift_analyzer_app' \
    "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label inputLibrary was not available"
  grep -Fq 'library_for=drift_analyzer_app' \
    "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label resolver.libraryFor was not available"
  grep -Fq 'find_library_by_name=drift_analyzer_app' \
    "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label resolver.findLibraryByName was not available"
  grep -Fq 'asset_id_for_element=lib/database.dart' \
    "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label resolver.assetIdForElement was not available"
  grep -Fq 'language_version=3.13' \
    "$rust_dir/lib/database.drift_analyzer_probe.txt" || \
    fail "$label package language version was not visible"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

mkdir -p "$fixture_root" "$results_dir"
worker_attach "$workspace_root"
mkdir -p "$stock_dir" "$rust_dir"
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp -R "$fixture_dir/lib" "$directory/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}" || \
    fail "pub get failed in $directory"
done

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build
}

run_rust() {
  local directory=$1
  local log=$2
  local jobs=$3
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend build \
    --root "$directory" --dart "$dart_bin" --jobs "$jobs"
}

run_stock "$stock_dir" "$temporary_dir/clean.stock.log" || fail 'stock clean build failed'
run_rust "$rust_dir" "$temporary_dir/clean.rust.log" 1 || fail 'Rust clean build failed'
compare_outputs clean
grep -Fq 'drift_dev:analyzer#factory0' \
  "$rust_dir/.dart_tool/build_runner_accelerator/builder-manifest.json" || \
  fail 'manifest did not expand the discover factory'
grep -Fq 'drift_dev:analyzer#factory1' \
  "$rust_dir/.dart_tool/build_runner_accelerator/builder-manifest.json" || \
  fail 'manifest did not expand the analyzer factory'

run_rust "$rust_dir" "$temporary_dir/no-op.rust.log" 1 || fail 'Rust no-op failed'
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || \
  fail 'Rust analyzer no-op was not reported'

# Exercise a Dart source change while keeping the library resolvable.
sed -i 's/class AppDatabase/class AppDatabaseV2/' \
  "$stock_dir/lib/database.dart" "$rust_dir/lib/database.dart"
run_stock "$stock_dir" "$temporary_dir/dart-change.stock.log" || \
  fail 'stock Dart change build failed'
run_rust "$rust_dir" "$temporary_dir/dart-change.rust.log" 2 || \
  fail 'Rust Dart change build failed'
compare_outputs dart-change

# Exercise a Drift source change and the generated type-helper output.
sed -i 's/name TEXT NOT NULL,/name TEXT NOT NULL, email TEXT NOT NULL,/' \
  "$stock_dir/lib/schema.drift" "$rust_dir/lib/schema.drift"
run_stock "$stock_dir" "$temporary_dir/drift-change.stock.log" || \
  fail 'stock Drift change build failed'
run_rust "$rust_dir" "$temporary_dir/drift-change.rust.log" 1 || \
  fail 'Rust Drift change build failed'
compare_outputs drift-change

# A rename must remove the old inventory and publish the new mapping.
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/schema.drift" "$directory/lib/schema_renamed.drift"
  sed -i "s/schema.drift/schema_renamed.drift/" "$directory/lib/database.dart"
done
run_stock "$stock_dir" "$temporary_dir/rename.stock.log" || fail 'stock rename build failed'
run_rust "$rust_dir" "$temporary_dir/rename.rust.log" 2 || fail 'Rust rename build failed'
compare_outputs rename schema_renamed
assert_missing \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib/schema.drift.drift_elements.json"

# Remove the include and the input together, so the deletion is valid and
# exercises stale cache/source output inventory instead of a dangling include.
for directory in "$stock_dir" "$rust_dir"; do
  sed -i "s/@DriftDatabase(include: {'schema_renamed.drift'})/@DriftDatabase()/" \
    "$directory/lib/database.dart"
  find "$directory/lib" -maxdepth 1 -type f -name 'schema_renamed.drift' -delete
done
run_stock "$stock_dir" "$temporary_dir/delete.stock.log" || fail 'stock deletion build failed'
run_rust "$rust_dir" "$temporary_dir/delete.rust.log" 1 || fail 'Rust deletion build failed'
assert_same_tree \
  "$stock_dir/.dart_tool/build/generated/drift_analyzer_app" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app"
assert_same_tree "$stock_dir/lib" "$rust_dir/lib"
assert_missing \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_analyzer_app/lib/schema_renamed.drift.drift_elements.json"
run_rust "$rust_dir" "$temporary_dir/delete-no-op.rust.log" 2 || \
  fail 'Rust deletion no-op failed'
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/delete-no-op.rust.log" || \
  fail 'Rust deletion no-op was not reported'

# Restore a valid analyzer input before exercising failure and recovery. The
# deletion case above intentionally leaves no type helper to compare.
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/lib/schema.drift" "$directory/lib/schema.drift"
  sed -i "s/@DriftDatabase()/@DriftDatabase(include: {'schema.drift'})/" \
    "$directory/lib/database.dart"
done
run_stock "$stock_dir" "$temporary_dir/failure-baseline.stock.log" || \
  fail 'stock failure baseline build failed'
run_rust "$rust_dir" "$temporary_dir/failure-baseline.rust.log" 1 || \
  fail 'Rust failure baseline build failed'
compare_outputs failure-baseline

# A failing later Builder must not commit its partial source output in the
# native transaction. Keep the successful inventory as the recovery oracle.
for file in "$rust_dir"/lib/*.drift_analyzer_probe.txt; do
  cp "$file" "$results_dir/$(basename "$file")"
done
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/build.failure.yaml" "$directory/build.yaml"
done
if run_stock "$stock_dir" "$temporary_dir/failure.stock.log"; then
  fail 'stock failure probe unexpectedly succeeded'
fi
if run_rust "$rust_dir" "$temporary_dir/failure.rust.log" 2; then
  fail 'Rust failure probe unexpectedly succeeded'
fi
for file in "$results_dir"/*.drift_analyzer_probe.txt; do
  assert_same_file "$file" "$rust_dir/lib/$(basename "$file")"
done

for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
done
run_stock "$stock_dir" "$temporary_dir/recovery.stock.log" || \
  fail 'stock recovery build failed'
run_rust "$rust_dir" "$temporary_dir/recovery.rust.log" 1 || \
  fail 'Rust recovery build failed'
compare_outputs recovery

printf 'drift-analyzer-compatibility: factories=2 input-mappings=2 required-input=prep cache-read=yes resolver-api=yes type-helper=yes source-cache=yes inventory=yes failure-atomic=yes jobs=1,2\n'
