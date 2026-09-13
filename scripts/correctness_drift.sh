#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
cargo_bin=$(resolve_toolchain_cargo)
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
fixture_dir="$repo_root/fixtures/drift_app"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-drift.XXXXXX")
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
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
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'drift-compatibility: FAIL: %s\n' "$*" >&2
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

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  (cd "$repo_root" && RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml") || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$fixture_root"
ln -s "$repo_root/dart_worker" "$workspace_root/dart_worker"
mkdir -p "$stock_dir" "$rust_dir"
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp -R "$fixture_dir/lib" "$directory/"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get \
      "${pub_get_args[@]}" >"$temporary_dir/$(basename "$directory").pub-get.log" 2>&1) || \
    fail "pub get failed in $directory"
done

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs >"$log" 2>&1)
}

run_rust() {
  local directory=$1
  local log=$2
  PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
    "$script_dir/run_rust_frontend.sh" build --root "$directory" --dart "$dart_bin" \
    --jobs 1 >"$log" 2>&1
}

run_stock "$stock_dir" "$temporary_dir/initial.stock.log" || fail 'stock build failed'
run_rust "$rust_dir" "$temporary_dir/initial.rust.log" || fail 'Rust build failed'

assert_same_tree \
  "$stock_dir/.dart_tool/build/generated/drift_app" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app"
assert_same_tree "$stock_dir/lib" "$rust_dir/lib"
assert_same_file "$stock_dir/lib/database.g.dart" "$rust_dir/lib/database.g.dart"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/drift_app/lib/database.drift.g.part" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app/lib/database.drift.g.part"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/drift_app/lib/schema.drift.drift_elements.json" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app/lib/schema.drift.drift_elements.json"
grep -Fq 'Rust frontend:' "$temporary_dir/initial.rust.log" || \
  fail 'Rust drift build did not execute actions'

run_rust "$rust_dir" "$temporary_dir/no-op.rust.log" || fail 'Rust no-op failed'
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || \
  fail 'Rust drift no-op was not reported'

printf 'CREATE TABLE users (\n  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,\n  name TEXT NOT NULL,\n  email TEXT NOT NULL\n);\n' >"$stock_dir/lib/schema.drift"
printf 'CREATE TABLE users (\n  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,\n  name TEXT NOT NULL,\n  email TEXT NOT NULL\n);\n' >"$rust_dir/lib/schema.drift"
run_stock "$stock_dir" "$temporary_dir/change.stock.log" || fail 'stock changed build failed'
run_rust "$rust_dir" "$temporary_dir/change.rust.log" || fail 'Rust changed build failed'
assert_same_tree \
  "$stock_dir/.dart_tool/build/generated/drift_app" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app"
assert_same_tree "$stock_dir/lib" "$rust_dir/lib"
assert_same_file "$stock_dir/lib/database.g.dart" "$rust_dir/lib/database.g.dart"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/drift_app/lib/database.drift.g.part" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app/lib/database.drift.g.part"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/drift_app/lib/schema.drift.drift_elements.json" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app/lib/schema.drift.drift_elements.json"

# Remove the schema and its include together so both runners exercise stale
# generated-output cleanup without turning the source into an invalid Drift
# program. This is the valid deletion path; a dangling include is expected to
# fail in both implementations and is covered by the failure probes.
sed -i "s/@DriftDatabase(include: {'schema.drift'})/@DriftDatabase()/" \
  "$stock_dir/lib/database.dart" "$rust_dir/lib/database.dart"
rm -f -- "$stock_dir/lib/schema.drift" "$rust_dir/lib/schema.drift"
run_stock "$stock_dir" "$temporary_dir/delete.stock.log" || fail 'stock delete build failed'
run_rust "$rust_dir" "$temporary_dir/delete.rust.log" || fail 'Rust delete build failed'
assert_same_tree \
  "$stock_dir/.dart_tool/build/generated/drift_app" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/drift_app"
assert_same_tree "$stock_dir/lib" "$rust_dir/lib"
assert_same_file "$stock_dir/lib/database.g.dart" "$rust_dir/lib/database.g.dart"

printf 'drift-compatibility: multi-factory=yes per-factory-mapping=yes drift-input=yes cleanup=yes\n'
