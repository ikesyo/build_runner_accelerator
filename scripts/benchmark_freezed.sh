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
fixture_dir="$repo_root/fixtures/freezed_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-freezed-benchmark-root.XXXXXX")
results_dir=$(mktemp -d)
metrics_path="$results_dir/metrics.txt"
mkdir -p "$test_root/fixtures"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
stock_dir="$test_root/fixtures/stock"
rust_dir="$test_root/fixtures/rust"

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT

fail() {
  printf 'freezed-benchmark: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend binary is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

prepare_package() {
  local directory=$1
  local package_name=$2
  mkdir -p "$directory/lib"
  sed "s/^name: .*/name: $package_name/" \
    "$fixture_dir/pubspec.yaml" >"$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  cp "$fixture_dir/lib/serializable.dart" "$directory/lib/serializable.dart"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)
}

prepare_package "$stock_dir" freezed_benchmark_stock
prepare_package "$rust_dir" freezed_benchmark_rust

run_stock() {
  local directory=$1
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs)
}

run_rust() {
  local directory=$1
  (cd "$repo_root" && \
    PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
      "$script_dir/run_rust_frontend.sh" \
      build --root "$directory" --dart "$dart_bin" --jobs "${JOBS:-1}")
}

measure() {
  local label=$1
  shift
  if [[ -x /usr/bin/time ]]; then
    /usr/bin/time -f "$label real=%e user=%U sys=%S maxrss_kb=%M" \
      "$@" >"$results_dir/$label.stdout" 2>"$results_dir/$label.stderr"
  else
    TIMEFORMAT="$label real=%3R user=%3U sys=%3S maxrss_kb=unavailable"
    { time "$@"; } >"$results_dir/$label.stdout" 2>"$results_dir/$label.stderr"
  fi
  cat "$results_dir/$label.stderr" >>"$metrics_path"
}

assert_same_outputs() {
  for output in model.freezed.dart serializable.freezed.dart serializable.g.dart; do
    cmp "$stock_dir/lib/$output" "$rust_dir/lib/$output" || \
      fail "output differs: $output"
  done
}

measure stock_clean run_stock "$stock_dir"
measure rust_clean run_rust "$rust_dir"
assert_same_outputs

measure stock_noop run_stock "$stock_dir"
measure rust_noop run_rust "$rust_dir"
grep -Fq 'No work to do (Rust frontend)' "$results_dir/rust_noop.stdout" || \
  fail 'Rust no-op was not reported'

for directory in "$stock_dir" "$rust_dir"; do
  sed -i '1i // benchmark one-file marker: 1' "$directory/lib/model.dart"
done
measure stock_1_file run_stock "$stock_dir"
measure rust_1_file run_rust "$rust_dir"
assert_same_outputs

for directory in "$stock_dir" "$rust_dir"; do
  sed -i '1i // benchmark broad marker: 1' "$directory/lib/model.dart"
  sed -i '1i // benchmark broad marker: 1' "$directory/lib/serializable.dart"
done
measure stock_all_file run_stock "$stock_dir"
measure rust_all_file run_rust "$rust_dir"
assert_same_outputs

printf 'freezed-benchmark: jobs=%s byte-identical=yes no-op=yes\n' "${JOBS:-1}"
cat "$metrics_path"
