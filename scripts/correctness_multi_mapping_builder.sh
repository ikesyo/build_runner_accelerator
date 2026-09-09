#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
toolchain_bin=${RUST_TOOLCHAIN_BIN:-"$repo_root/.toolchains/rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin"}
cargo_bin=${CARGO_BIN:-"$toolchain_bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
fixture_dir="$repo_root/fixtures/multi_mapping_builder_app"
lockfile_source="$repo_root/fixtures/arbitrary_builder_app/pubspec.lock"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"

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
[[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"

if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    RUSTUP_TOOLCHAIN=1.98.1 "$cargo_bin" build --quiet \
    --manifest-path "$repo_root/rust/Cargo.toml" || fail 'Rust frontend build failed'
  FAST_BUILD_RUNNER_BIN="$repo_root/rust/target/debug/fast_build_runner"
  export FAST_BUILD_RUNNER_BIN
fi
[[ -x "$FAST_BUILD_RUNNER_BIN" ]] || fail "Rust frontend is not executable: $FAST_BUILD_RUNNER_BIN"

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
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null)
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
  PUB_CACHE="$pub_cache" FAST_BUILD_RUNNER_BIN="$FAST_BUILD_RUNNER_BIN" \
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
