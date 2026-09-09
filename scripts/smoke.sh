#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
cargo_bin=${CARGO_BIN:-"$repo_root/.toolchains/cargo/bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/json_serializable_app"
state_path="$fixture_dir/.dart_tool/build_runner_accelerator/graph-v3.bin"
temporary_dir=$(mktemp -d)
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

if [[ ! -x "$dart_bin" ]]; then
  printf 'Dart executable not found: %s\n' "$dart_bin" >&2
  exit 1
fi
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" && ! -x "$cargo_bin" ]]; then
  printf 'Cargo executable not found: %s\n' "$cargo_bin" >&2
  exit 1
fi

(cd "$worker_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "${pub_get_args[@]}" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics format \
    --output=none --set-exit-if-changed lib bin)
(cd "$fixture_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "${pub_get_args[@]}")

RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$cargo_bin" test --manifest-path "$repo_root/rust/Cargo.toml"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml"
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || {
  printf 'Rust frontend binary is not executable: %s\n' "$BUILD_RUNNER_ACCELERATOR_BIN" >&2
  exit 1
}

baseline_output="$temporary_dir/model.g.dart.baseline"
(cd "$fixture_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner build --delete-conflicting-outputs \
    --log-performance .dart_tool/build_runner_accelerator/stock-performance && \
  cp lib/model.g.dart "$baseline_output")

if [[ -f "$state_path" ]]; then
  mv "$state_path" "$temporary_dir/graph-v3.before.bin"
fi

run_frontend() {
  PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$script_dir/run_rust_frontend.sh" \
    build --root "$fixture_dir" --dart "$dart_bin"
}

run_frontend
second_output="$temporary_dir/second-run.log"
run_frontend >"$second_output"
grep -Fq 'No work to do (Rust frontend)' "$second_output"
cmp "$baseline_output" "$fixture_dir/lib/model.g.dart"

printf 'smoke: byte-identical=yes no-op=yes\n'
printf 'temporary_results=%s\n' "$temporary_dir"
