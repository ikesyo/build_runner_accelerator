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
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/post_process_builder_app"
temporary_dir=$(mktemp -d)
test_root="$temporary_dir/workspace"
test_fixtures_dir="$test_root/fixtures"
no_op_checked=0

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
  printf 'post-process-builder: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml"
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || fail "Rust frontend binary is not executable"

(cd "$worker_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null)

mkdir -p "$test_fixtures_dir"
ln -s "$worker_dir" "$test_root/dart_worker"

run_rust() {
  local directory=$1
  local log=$2
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$script_dir/run_rust_frontend.sh" \
    build --root "$directory" --dart "$dart_bin" >"$log" 2>&1
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs >"$log" 2>&1)
}

run_stock_clean() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      clean >"$log.clean" 2>&1)
  run_stock "$directory" "$log"
}

post_output() {
  local directory=$1
  printf '%s\n' "$directory/.dart_tool/build_runner_accelerator/cache/post_process_builder_app/lib/input.gen.txt.post.txt"
}

stock_post_output() {
  local directory=$1
  printf '%s\n' "$directory/.dart_tool/build/generated/post_process_builder_app/lib/input.gen.txt.post.txt"
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_no_file() {
  local file=$1
  [[ ! -e "$file" ]] || fail "unexpected file remains: $file"
}

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/post_process_builder.dart" \
    "$directory/lib/post_process_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null)
}

setup_case() {
  local name=$1
  stock_dir="$test_fixtures_dir/${name}-stock"
  rust_dir="$test_fixtures_dir/${name}-rust"
  prepare_package "$stock_dir"
  prepare_package "$rust_dir"

  run_stock "$stock_dir" "$temporary_dir/$name.stock.initial.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.initial.log"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$(stock_post_output "$stock_dir")" "$(post_output "$rust_dir")"
  grep -Fq 'Rust frontend: 2 build action(s)' \
    "$temporary_dir/$name.rust.initial.log" || fail 'expected normal and post actions'
  if (( no_op_checked == 0 )); then
    run_rust "$rust_dir" "$temporary_dir/$name.rust.no-op.log"
    grep -Fq 'No work to do (Rust frontend)' \
      "$temporary_dir/$name.rust.no-op.log" || fail 'Rust no-op failed'
    no_op_checked=1
  fi
}

run_case_output_delete() {
  local name=output-delete
  setup_case "$name"
  rm -f -- "$(stock_post_output "$stock_dir")" "$(post_output "$rust_dir")"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  # build_runner 2.7.2 keeps a successful post-process step successful even
  # when its hidden cache output is removed externally. A clean stock build
  # gives us the reference bytes while the Rust run above remains an
  # incremental output-recovery check.
  if [[ ! -f "$(stock_post_output "$stock_dir")" ]]; then
    run_stock_clean "$stock_dir" "$temporary_dir/$name.stock.change.log"
  fi
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$(stock_post_output "$stock_dir")" "$(post_output "$rust_dir")"
  printf 'post-process-builder: output-delete: pass\n'
}

run_case_input_change() {
  local name=input-change
  setup_case "$name"
  printf 'changed\n' >"$stock_dir/lib/input.txt"
  printf 'changed\n' >"$rust_dir/lib/input.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$(stock_post_output "$stock_dir")" "$(post_output "$rust_dir")"
  printf 'post-process-builder: input-change: pass\n'
}

run_case_rename() {
  local name=rename
  setup_case "$name"
  mv "$stock_dir/lib/input.txt" "$stock_dir/lib/renamed.txt"
  mv "$rust_dir/lib/input.txt" "$rust_dir/lib/renamed.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/renamed.gen.txt" "$rust_dir/lib/renamed.gen.txt"
  assert_same_file \
    "$stock_dir/.dart_tool/build/generated/post_process_builder_app/lib/renamed.gen.txt.post.txt" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/post_process_builder_app/lib/renamed.gen.txt.post.txt"
  assert_no_file "$rust_dir/lib/input.gen.txt"
  assert_no_file "$rust_dir/.dart_tool/build_runner_accelerator/cache/post_process_builder_app/lib/input.gen.txt.post.txt"
  printf 'post-process-builder: rename: pass\n'
}

run_case_input_delete() {
  local name=input-delete
  setup_case "$name"
  rm -f -- "$stock_dir/lib/input.txt" "$rust_dir/lib/input.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/input.gen.txt"
  assert_no_file "$rust_dir/lib/input.gen.txt"
  assert_no_file "$(stock_post_output "$stock_dir")"
  assert_no_file "$(post_output "$rust_dir")"
  printf 'post-process-builder: input-delete: pass\n'
}

run_case_stale_output() {
  local name=stale-output
  setup_case "$name"
  sed -i 's/emit: true/emit: false/' "$stock_dir/build.yaml" "$rust_dir/build.yaml"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_no_file "$(stock_post_output "$stock_dir")"
  assert_no_file "$(post_output "$rust_dir")"
  printf 'post-process-builder: stale-output: pass\n'
}

run_case_output_delete
run_case_input_change
run_case_rename
run_case_input_delete
run_case_stale_output
printf 'post-process-builder: all cases passed\n'
