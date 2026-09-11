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
fixture_dir="$repo_root/fixtures/riverpod_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-riverpod-benchmark-root.XXXXXX")
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
cleanup() { remove_tree "$test_root"; remove_tree "$results_dir"; }
trap cleanup EXIT

fail() { printf 'riverpod-benchmark: FAIL: %s\n' "$*" >&2; exit 1; }

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  (cd "$repo_root" && RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || fail 'Rust frontend binary is not executable'

prepare_package() {
  local directory=$1
  local package_name=$2
  mkdir -p "$directory/lib"
  sed "s/^name: .*/name: $package_name/" "$fixture_dir/pubspec.yaml" >"$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  cp "$fixture_dir/lib/secondary.dart" "$directory/lib/secondary.dart"
  (cd "$directory" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)
}

prepare_package "$stock_dir" riverpod_benchmark_stock
prepare_package "$rust_dir" riverpod_benchmark_rust

run_stock() {
  local directory=$1
  (cd "$directory" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
    build --delete-conflicting-outputs)
}
run_rust() {
  local directory=$1
  (cd "$repo_root" && PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" "$script_dir/run_rust_frontend.sh" \
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
  rg 'real=|maxrss_kb=' "$results_dir/$label.stderr" >>"$metrics_path" || \
    fail "timing output missing for $label"
  rg '^(Dart resolver metrics:|Dart metrics:|Rust (metrics|filesystem metrics|graph metrics|workspace metrics):)' \
    "$results_dir/$label.stderr" >>"$metrics_path" || true
}

assert_same_outputs() {
  cmp "$stock_dir/lib/model.freezed.dart" "$rust_dir/lib/model.freezed.dart" || \
    fail 'Freezed output differs'
  cmp "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart" || fail 'output differs'
  cmp "$stock_dir/lib/secondary.g.dart" "$rust_dir/lib/secondary.g.dart" || \
    fail 'secondary output differs'
  cmp "$stock_dir/.dart_tool/build/generated/riverpod_benchmark_stock/lib/secondary.riverpod.g.part" \
    "$rust_dir/.dart_tool/build_runner_accelerator/cache/riverpod_benchmark_rust/lib/secondary.riverpod.g.part" || \
    fail 'secondary Riverpod part differs'
}

measure stock_clean run_stock "$stock_dir"
measure rust_clean run_rust "$rust_dir"
assert_same_outputs
measure stock_noop run_stock "$stock_dir"
measure rust_noop run_rust "$rust_dir"
rg -Fq 'No work to do (Rust frontend)' "$results_dir/rust_noop.stdout" || fail 'Rust no-op was not reported'
for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/=> 42;/=> 43;/' "$directory/lib/model.dart"
done
measure stock_source_edit run_stock "$stock_dir"
measure rust_source_edit run_rust "$rust_dir"
assert_same_outputs

for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/=> 43;/=> 44;/' "$directory/lib/model.dart"
  sed -i "s/=> 'hello';/=> 'goodbye';/" "$directory/lib/secondary.dart"
done
measure stock_broad_incremental run_stock "$stock_dir"
measure rust_broad_incremental run_rust "$rust_dir"
assert_same_outputs

printf 'riverpod-benchmark: jobs=%s byte-identical=yes no-op=yes\n' "${JOBS:-1}"
cat "$metrics_path"
