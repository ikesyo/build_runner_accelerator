#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
jobs=${JOBS:-1}
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
cargo_bin=$(resolve_toolchain_cargo)
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/optional_builder_app"
lockfile_source="$fixture_dir/pubspec.lock"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/rust"

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
  printf 'optional-builder-benchmark: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$workspace_root/fixtures"
ln -s "$worker_dir" "$workspace_root/dart_worker"

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/optional_builder.dart" "$directory/lib/optional_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null) || \
    fail "pub get failed for $directory"
}

prepare_package "$stock_dir"
prepare_package "$rust_dir"

run_stock() {
  local directory=$1
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs)
}

run_rust() {
  local directory=$1
  PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$script_dir/run_rust_frontend.sh" build --root "$directory" --dart "$dart_bin" \
    --mode rust --jobs "$jobs"
}

measure() {
  local label=$1
  shift
  local output="$temporary_dir/$label.stdout"
  local error="$temporary_dir/$label.stderr"
  TIMEFORMAT="$label real=%3R user=%3U sys=%3S"
  { time "$@"; } >"$output" 2>"$error" || {
    cat "$error" >&2
    return 1
  }
  cat "$error"
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_same_outputs() {
  local relative
  for relative in \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt; do
    assert_same_file "$stock_dir/$relative" "$rust_dir/$relative"
  done
}

measure stock_clean run_stock "$stock_dir"
measure rust_clean run_rust "$rust_dir"
assert_same_outputs

measure stock_noop run_stock "$stock_dir"
measure rust_noop run_rust "$rust_dir"
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/rust_noop.stdout" || \
  fail 'Rust no-op did not report no work'

printf 'benchmark optional\n' >"$stock_dir/lib/input.txt"
printf 'benchmark optional\n' >"$rust_dir/lib/input.txt"
measure stock_incremental run_stock "$stock_dir"
measure rust_incremental run_rust "$rust_dir"
assert_same_outputs

printf 'optional-builder-benchmark: clean=no-op=yes incremental=yes byte-identical=yes\n'
