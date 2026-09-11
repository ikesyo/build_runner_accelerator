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
fixture_dir="$repo_root/fixtures/built_value_app"
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
  printf 'built-value-correctness: FAIL: %s\n' "$*" >&2
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
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp -R "$fixture_dir/lib" "$directory/"
  cp -R "$fixture_dir/bin" "$directory/"
  (cd "$directory" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics \
    pub get >/dev/null) || fail "pub get failed in $directory"
done

(cd "$stock_dir" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics \
  run build_runner build >"$temporary_dir/stock.log" 2>&1) || fail 'stock build failed'
(cd "$repo_root" && PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" \
  CARGO_HOME="$cargo_home" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  "$script_dir/run_rust_frontend.sh" build --root "$rust_dir" --dart "$dart_bin" \
  --jobs 1 >"$temporary_dir/rust.log" 2>&1) || fail 'Rust build failed'

assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
assert_same_file \
  "$stock_dir/.dart_tool/build/generated/built_value_app/lib/model.built_value.g.part" \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/lib/model.built_value.g.part"
assert_no_file "$stock_dir/.dart_tool/build/generated/built_value_app/bin/example.built_value.g.part"
assert_no_file "$stock_dir/.dart_tool/build/generated/built_value_app/lib/plain.built_value.g.part"
assert_no_file "$stock_dir/bin/example.g.dart"
assert_no_file "$stock_dir/lib/plain.g.dart"
assert_no_file "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/bin/example.built_value.g.part"
assert_no_file "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/lib/plain.built_value.g.part"
assert_no_file "$rust_dir/bin/example.g.dart"
assert_no_file "$rust_dir/lib/plain.g.dart"
assert_contains "$temporary_dir/rust.log" 'Build completed (Rust frontend)'

# A normal builder may stop emitting an output after an input changes. The
# native frontend must remove the previous part and combined source output.
for directory in "$stock_dir" "$rust_dir"; do
  printf '// no longer a built_value library\nvoid model() {}\n' >"$directory/lib/model.dart"
done
(cd "$stock_dir" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics \
  run build_runner build >"$temporary_dir/stock-change.log" 2>&1) || \
  fail 'stock changed-input build failed'
(cd "$repo_root" && PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" \
  CARGO_HOME="$cargo_home" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  "$script_dir/run_rust_frontend.sh" build --root "$rust_dir" --dart "$dart_bin" \
  --jobs 1 >"$temporary_dir/rust-change.log" 2>&1) || \
  fail 'Rust changed-input build failed'
assert_no_file "$stock_dir/lib/model.g.dart"
assert_no_file "$rust_dir/lib/model.g.dart"
assert_no_file \
  "$stock_dir/.dart_tool/build/generated/built_value_app/lib/model.built_value.g.part"
assert_no_file \
  "$rust_dir/.dart_tool/build_runner_accelerator/cache/built_value_app/lib/model.built_value.g.part"

printf 'built-value-correctness: non-triggered-input=yes output-match=yes\n'
