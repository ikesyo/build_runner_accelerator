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
fixture_dir="$repo_root/fixtures/multi_mapping_builder_app"
lockfile_source="$repo_root/fixtures/arbitrary_builder_app/pubspec.lock"
temporary_dir=$(mktemp -d)
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
  printf 'multi-mapping-builder: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,220p' "$log" >&2
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
  [[ ! -e "$1" ]] || fail "unexpected file remains: $1"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  toolchain_bin=${RUST_TOOLCHAIN_BIN:-}
  rustc_bin=${RUSTC_BIN:-}
  if [[ -z "$rustc_bin" && -n "$toolchain_bin" ]]; then
    rustc_bin="$toolchain_bin/rustc"
  fi
  if [[ -z "$rustc_bin" ]]; then
    cargo_bin_dir=$(dirname -- "$cargo_bin")
    if [[ -x "$cargo_bin_dir/rustc" ]]; then
      rustc_bin="$cargo_bin_dir/rustc"
    else
      rustc_bin=$(command -v rustc || true)
    fi
  fi
  [[ -x "$rustc_bin" ]] || fail "rustc executable not found: $rustc_bin"
  if [[ -z "$toolchain_bin" ]]; then
    toolchain_bin=$(dirname -- "$rustc_bin")
  fi
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    RUSTC="$rustc_bin" "$cargo_bin" build --quiet \
    --manifest-path "$repo_root/rust/Cargo.toml" || fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

write_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/multi_mapping_builder.dart" \
    "$directory/lib/multi_mapping_builder.dart"
  printf 'ordinary input\n' >"$directory/lib/input.txt"
  printf 'special input\n' >"$directory/lib/special.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "${pub_get_args[@]}" >/dev/null)
}

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
    >"$log" 2>&1
}

mkdir -p "$fixture_root"
ln -s "$repo_root/dart_worker" "$workspace_root/dart_worker"
write_package "$stock_dir"
write_package "$rust_dir"

run_stock "$stock_dir" "$temporary_dir/initial.stock.log"
run_rust "$rust_dir" "$temporary_dir/initial.rust.log"
for output in \
  lib/input.multi \
  lib/special.multi \
  lib/special.generated.txt; do
  assert_same_file "$stock_dir/$output" "$rust_dir/$output"
done
assert_contains "$temporary_dir/initial.rust.log" 'Rust frontend: 2 build action(s)'

run_rust "$rust_dir" "$temporary_dir/no-op.rust.log"
assert_contains "$temporary_dir/no-op.rust.log" 'No work to do (Rust frontend)'

printf 'special changed\n' >"$stock_dir/lib/special.txt"
printf 'special changed\n' >"$rust_dir/lib/special.txt"
run_stock "$stock_dir" "$temporary_dir/change.stock.log"
run_rust "$rust_dir" "$temporary_dir/change.rust.log"
for output in lib/special.multi lib/special.generated.txt; do
  assert_same_file "$stock_dir/$output" "$rust_dir/$output"
done
assert_contains "$temporary_dir/change.rust.log" 'Rust frontend: 1 build action(s)'

mv "$stock_dir/lib/input.txt" "$stock_dir/lib/renamed.txt"
mv "$rust_dir/lib/input.txt" "$rust_dir/lib/renamed.txt"
run_stock "$stock_dir" "$temporary_dir/rename.stock.log"
run_rust "$rust_dir" "$temporary_dir/rename.rust.log"
assert_same_file "$stock_dir/lib/renamed.multi" "$rust_dir/lib/renamed.multi"
assert_no_file "$stock_dir/lib/input.multi"
assert_no_file "$rust_dir/lib/input.multi"

rm -f -- "$stock_dir/lib/special.txt" "$rust_dir/lib/special.txt"
run_stock "$stock_dir" "$temporary_dir/delete.stock.log"
run_rust "$rust_dir" "$temporary_dir/delete.rust.log"
assert_no_file "$stock_dir/lib/special.multi"
assert_no_file "$stock_dir/lib/special.generated.txt"
assert_no_file "$rust_dir/lib/special.multi"
assert_no_file "$rust_dir/lib/special.generated.txt"
assert_contains "$temporary_dir/delete.rust.log" 'Rust frontend: 0 build action(s)'

printf 'multi-mapping-builder: union=yes no-op=yes change=yes rename=yes delete=yes\n'
