#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/empty_input_mapping_app"
lockfile_source="$repo_root/pubspec.lock"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir=
rust_dir=
mapping_jobs=${EMPTY_INPUT_MAPPING_JOBS:-2}
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

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
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'empty-input-mapping: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
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

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected output remains: $1"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

source_outputs=(
  lib/input.dart.empty_mapping.out
  lib/input.regular.out
  lib/input.dart.consumed.out
  lib/second.dart.empty_mapping.out
  lib/second.regular.out
  lib/second.dart.consumed.out
  lib/schema.drift.empty_mapping.out
  lib/schema.drift.consumed.out
  lib/plain.empty_mapping.out
  lib/plain.consumed.out
)

assert_same_source_outputs() {
  local relative
  for relative in "${source_outputs[@]}"; do
    assert_same_file "$stock_dir/$relative" "$rust_dir/$relative"
  done
}

assert_source_inventory_matches() {
  local stock_inventory
  local rust_inventory
  stock_inventory=$(find "$stock_dir/lib" -type f \( \
    -name '*.empty_mapping.out' -o -name '*.regular.out' -o -name '*.consumed.out' \
  \) -printf '%P\n' | sort)
  rust_inventory=$(find "$rust_dir/lib" -type f \( \
    -name '*.empty_mapping.out' -o -name '*.regular.out' -o -name '*.consumed.out' \
  \) -printf '%P\n' | sort)
  [[ "$stock_inventory" == "$rust_inventory" ]] || \
    fail "source output inventory differs:\nstock:\n$stock_inventory\nrust:\n$rust_inventory"
}

assert_filtered_inputs_absent() {
  local directory
  for directory in "$stock_dir" "$rust_dir"; do
    assert_no_file "$directory/lib/generate-excluded/ignored.drift.empty_mapping.out"
    assert_no_file "$directory/lib/target-excluded/ignored.dart.empty_mapping.out"
    assert_no_file "$directory/assets/outside.txt.empty_mapping.out"
  done
}

write_package() {
  local directory=$1
  local config=$2
  mkdir -p "$directory/lib" "$directory/assets"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/$config" "$directory/build.yaml"
  cp -R "$fixture_dir/lib/." "$directory/lib/"
  cp -R "$fixture_dir/assets/." "$directory/assets/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}" || fail "pub get failed for $directory"
}

prepare_pair() {
  local name=$1
  local config=$2
  stock_dir="$fixture_root/${name}-stock"
  rust_dir="$fixture_root/${name}-rust"
  write_package "$stock_dir" "$config"
  write_package "$rust_dir" "$config"
}

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
}

run_rust() {
  local directory=$1
  local log=$2
  local jobs=${3:-$mapping_jobs}
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend build \
    --root "$directory" --dart "$dart_bin" --mode rust --jobs "$jobs"
}

stock_cache_asset() {
  local relative=$1
  find "$stock_dir/.dart_tool/build" -type f \
    -path "*/empty_input_mapping_app/$relative" -print -quit
}

assert_same_cache_asset() {
  local relative=$1
  local stock_asset
  stock_asset=$(stock_cache_asset "$relative")
  [[ -n "$stock_asset" ]] || fail "stock cache output not found: $relative"
  assert_same_file "$stock_asset" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/empty_input_mapping_app/$relative"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -f "$fixture_dir/build.yaml" ]] || fail "fixture not found: $fixture_dir"
worker_ensure_frontend || fail 'Rust frontend build failed'
mkdir -p "$fixture_root"
worker_attach "$workspace_root" || fail 'unable to attach repository package'

prepare_pair source build.yaml
run_stock "$stock_dir" "$temporary_dir/source.initial.stock.log" || fail 'stock source build failed'
run_rust "$rust_dir" "$temporary_dir/source.initial.rust.log" || fail 'Rust source build failed'
assert_same_source_outputs
assert_source_inventory_matches
assert_filtered_inputs_absent
assert_contains "$temporary_dir/source.initial.rust.log" 'Rust frontend: 8 build action(s)'

run_rust "$rust_dir" "$temporary_dir/source.no-op.rust.log" || fail 'Rust no-op build failed'
assert_contains "$temporary_dir/source.no-op.rust.log" 'No work to do (Rust frontend)'

printf 'changed drift\n' >"$stock_dir/lib/schema.drift"
printf 'changed drift\n' >"$rust_dir/lib/schema.drift"
run_stock "$stock_dir" "$temporary_dir/source.drift-change.stock.log" || fail 'stock drift change failed'
run_rust "$rust_dir" "$temporary_dir/source.drift-change.rust.log" || fail 'Rust drift change failed'
assert_same_source_outputs
assert_contains "$temporary_dir/source.drift-change.rust.log" 'Rust frontend: 2 build action(s)'

printf 'changed outside target\n' >"$stock_dir/assets/outside.txt"
printf 'changed outside target\n' >"$rust_dir/assets/outside.txt"
run_stock "$stock_dir" "$temporary_dir/source.non-target-change.stock.log" || fail 'stock non-target change failed'
run_rust "$rust_dir" "$temporary_dir/source.non-target-change.rust.log" || fail 'Rust non-target change failed'
assert_same_source_outputs
assert_contains "$temporary_dir/source.non-target-change.rust.log" 'No work to do (Rust frontend)'

printf 'changed dart\n' >"$stock_dir/lib/input.dart"
printf 'changed dart\n' >"$rust_dir/lib/input.dart"
printf 'changed plain\n' >"$stock_dir/lib/plain"
printf 'changed plain\n' >"$rust_dir/lib/plain"
run_stock "$stock_dir" "$temporary_dir/source-multi-change.stock.log" || fail 'stock multiple input change failed'
run_rust "$rust_dir" "$temporary_dir/source-multi-change.rust.log" || fail 'Rust multiple input change failed'
assert_same_source_outputs
assert_contains "$temporary_dir/source-multi-change.rust.log" 'Rust frontend: 4 build action(s)'

mv "$stock_dir/lib/plain" "$stock_dir/lib/renamed"
mv "$rust_dir/lib/plain" "$rust_dir/lib/renamed"
run_stock "$stock_dir" "$temporary_dir/source.rename.stock.log" || fail 'stock rename failed'
run_rust "$rust_dir" "$temporary_dir/source.rename.rust.log" || fail 'Rust rename failed'
for directory in "$stock_dir" "$rust_dir"; do
  assert_no_file "$directory/lib/plain.empty_mapping.out"
  assert_no_file "$directory/lib/plain.consumed.out"
  [[ -f "$directory/lib/renamed.empty_mapping.out" ]] || fail "renamed empty mapping output missing"
  [[ -f "$directory/lib/renamed.consumed.out" ]] || fail "renamed consumer output missing"
done
assert_same_file "$stock_dir/lib/renamed.empty_mapping.out" "$rust_dir/lib/renamed.empty_mapping.out"
assert_same_file "$stock_dir/lib/renamed.consumed.out" "$rust_dir/lib/renamed.consumed.out"

rm -f -- "$stock_dir/lib/schema.drift" "$rust_dir/lib/schema.drift"
run_stock "$stock_dir" "$temporary_dir/source.delete.stock.log" || fail 'stock delete failed'
run_rust "$rust_dir" "$temporary_dir/source.delete.rust.log" || fail 'Rust delete failed'
for directory in "$stock_dir" "$rust_dir"; do
  assert_no_file "$directory/lib/schema.drift.empty_mapping.out"
  assert_no_file "$directory/lib/schema.drift.consumed.out"
done
assert_contains "$temporary_dir/source.delete.rust.log" 'Rust frontend: 0 build action(s)'

prepare_pair jobs1 build.yaml
run_stock "$stock_dir" "$temporary_dir/jobs1.stock.log" || fail 'stock jobs=1 comparison failed'
run_rust "$rust_dir" "$temporary_dir/jobs1.rust.log" 1 || fail 'Rust jobs=1 comparison failed'
assert_same_source_outputs

prepare_pair cache build.cache.yaml
run_stock "$stock_dir" "$temporary_dir/cache.stock.log" || fail 'stock cache build failed'
run_rust "$rust_dir" "$temporary_dir/cache.rust.log" || fail 'Rust cache build failed'
for relative in \
  lib/input.dart.empty_mapping.out \
  lib/input.regular.out \
  lib/second.dart.empty_mapping.out \
  lib/second.regular.out \
  lib/schema.drift.empty_mapping.out \
  lib/plain.empty_mapping.out; do
  assert_same_cache_asset "$relative"
done
for relative in \
  lib/input.dart.consumed.out \
  lib/second.dart.consumed.out \
  lib/schema.drift.consumed.out \
  lib/plain.consumed.out; do
  assert_same_file "$stock_dir/$relative" "$rust_dir/$relative"
done

prepare_pair failure build.failure.yaml
if run_stock "$stock_dir" "$temporary_dir/failure.stock.log"; then
  fail 'stock failure fixture unexpectedly succeeded'
fi
if run_rust "$rust_dir" "$temporary_dir/failure.rust.log"; then
  fail 'Rust failure fixture unexpectedly succeeded'
fi
for directory in "$stock_dir" "$rust_dir"; do
  assert_no_file "$directory/lib/input.dart.empty_mapping.out"
  assert_no_file "$directory/lib/input.regular.out"
  assert_no_file "$directory/lib/input.dart.consumed.out"
done
cp "$fixture_dir/build.yaml" "$stock_dir/build.yaml"
cp "$fixture_dir/build.yaml" "$rust_dir/build.yaml"
run_stock "$stock_dir" "$temporary_dir/failure.recovery.stock.log" || fail 'stock failure recovery failed'
run_rust "$rust_dir" "$temporary_dir/failure.recovery.rust.log" || fail 'Rust failure recovery failed'
assert_same_source_outputs

prepare_pair collision build.collision.yaml
if run_stock "$stock_dir" "$temporary_dir/collision.stock.log"; then
  fail 'stock collision fixture unexpectedly succeeded'
fi
if run_rust "$rust_dir" "$temporary_dir/collision.rust.log"; then
  fail 'Rust collision fixture unexpectedly succeeded'
fi
assert_no_file "$stock_dir/lib/input.dart.empty_mapping.out"
assert_no_file "$rust_dir/lib/input.dart.empty_mapping.out"
assert_contains "$temporary_dir/collision.rust.log" 'builder outputs collide'

printf 'empty-input-mapping: all-assets=yes extensionless=yes dart=yes drift=yes regular-union=yes generated-consumer=yes source-cache=yes filtering=yes stale-cleanup=yes collision=yes failure-recovery=yes jobs=1,2 performance=unmeasured\n'
