#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
toolchain_bin=${RUST_TOOLCHAIN_BIN:-"$repo_root/.toolchains/rustup/toolchains/1.88.0-x86_64-unknown-linux-gnu/bin"}
cargo_bin=${CARGO_BIN:-"$toolchain_bin/cargo"}
rustc_bin=${RUSTC_BIN:-"$toolchain_bin/rustc"}
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
fixture_dir="$repo_root/fixtures/current_json_app"
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
  printf 'current-json: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
  done
  exit 1
}

assert_same_outputs() {
  local phase=$1
  local -a outputs=()
  mapfile -t outputs < <(find "$stock_dir/lib" -maxdepth 1 -type f \
    -name '*.g.dart' -printf '%f\n' | sort)
  [[ "${#outputs[@]}" -eq 10 ]] || \
    fail "$phase: expected 10 generated Dart files, found ${#outputs[@]}"
  local rust_output_count
  rust_output_count=$(find "$rust_dir/lib" -maxdepth 1 -type f \
    -name '*.g.dart' | wc -l | tr -d ' ')
  [[ "$rust_output_count" -eq 10 ]] || \
    fail "$phase: expected 10 Rust generated Dart files, found $rust_output_count"
  for output in "${outputs[@]}"; do
    [[ -f "$rust_dir/lib/$output" ]] || fail "$phase: missing Rust output $output"
    cmp "$stock_dir/lib/$output" "$rust_dir/lib/$output" || \
      fail "$phase: generated output differs: $output"
  done
}

assert_rust_frontend() {
  local log=$1
  ! grep -Fq 'using Dart fallback' "$log" || \
    fail "Rust frontend unexpectedly used Dart fallback"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  [[ -x "$rustc_bin" ]] || fail "rustc executable not found: $rustc_bin"
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" \
    CARGO_HOME="$cargo_home" RUSTC="$rustc_bin" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

write_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib"/*.dart "$directory/lib/"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null)
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build >"$log" 2>&1)
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

run_stock "$stock_dir" "$temporary_dir/initial.stock.log" || \
  fail 'initial stock build failed'
run_rust "$rust_dir" "$temporary_dir/initial.rust.log" || \
  fail 'initial Rust build failed'
assert_rust_frontend "$temporary_dir/initial.rust.log"
assert_same_outputs initial

run_stock "$stock_dir" "$temporary_dir/no-op.stock.log" || \
  fail 'no-op stock build failed'
run_rust "$rust_dir" "$temporary_dir/no-op.rust.log" || \
  fail 'no-op Rust build failed'
assert_rust_frontend "$temporary_dir/no-op.rust.log"
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || \
  fail 'no-op: Rust frontend did not report no work'
assert_same_outputs no-op

sed -i 's/baseline-marker: base/baseline-marker: one-file/' \
  "$stock_dir/lib/model_01.dart" "$rust_dir/lib/model_01.dart"
run_stock "$stock_dir" "$temporary_dir/one-file.stock.log" || \
  fail 'one-file stock build failed'
run_rust "$rust_dir" "$temporary_dir/one-file.rust.log" || \
  fail 'one-file Rust build failed'
assert_rust_frontend "$temporary_dir/one-file.rust.log"
assert_same_outputs one-file

sed -i 's/baseline-marker: one-file/baseline-marker: broad/' \
  "$stock_dir/lib"/*.dart "$rust_dir/lib"/*.dart
run_stock "$stock_dir" "$temporary_dir/broad.stock.log" || \
  fail 'broad stock build failed'
run_rust "$rust_dir" "$temporary_dir/broad.rust.log" || \
  fail 'broad Rust build failed'
assert_rust_frontend "$temporary_dir/broad.rust.log"
assert_same_outputs broad

printf 'current-json: clean=yes no-op=yes one-file=yes broad=yes stock-match=yes\n'
