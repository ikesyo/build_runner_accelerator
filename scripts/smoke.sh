#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
cargo_bin=$(resolve_toolchain_cargo)
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
fixture_dir="$repo_root/fixtures/json_serializable_app"
state_path="$fixture_dir/.dart_tool/build_runner_accelerator/graph-v3.bin"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-smoke.XXXXXX")
fail() {
  printf 'smoke: FAIL: %s\n' "$*" >&2
  printf 'smoke: temporary_results=%s\n' "$temporary_dir" >&2
  exit 1
}
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

worker_prepare "${pub_get_args[@]}" >/dev/null || fail 'worker pub get failed'
(cd "$root_package_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics format \
    --output=none --set-exit-if-changed lib bin)
verification_run_pub_get "$fixture_dir" "pub-get/fixture" "$dart_bin" "$pub_cache" "${pub_get_args[@]}"

if [[ "${SMOKE_SKIP_RUST_TESTS:-0}" == 1 ]]; then
  printf 'smoke: rust-unit-tests=covered-by-rust-job\n'
else
  rust_test_timeout=$(verification_timeout_seconds VERIFY_COMMAND_TIMEOUT_SECONDS 600) || fail 'invalid Rust test timeout'
  verification_run_command "rust-tests" "$rust_test_timeout" "$temporary_dir/rust-tests.log" env RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" "$cargo_bin" test --manifest-path "$repo_root/rust/Cargo.toml" || fail 'Rust unit tests failed'
fi

worker_ensure_frontend || fail 'Rust frontend build failed'

if [[ -f "$state_path" ]]; then
  mv "$state_path" "$temporary_dir/graph-v3.plan-only-before.bin"
fi
plan_only_log="$temporary_dir/plan-only.log"
if ! (
  export BUILD_RUNNER_ACCELERATOR_PLAN_ONLY=1
  export VERIFY_COMMAND_LOG="$plan_only_log"
  export VERIFY_WORKSPACE="$fixture_dir"
  worker_run_frontend build --root "$fixture_dir" --dart "$dart_bin"
); then
  fail 'Plan-only run failed'
fi
grep -Fq 'Rust plan metrics: stage=action-plan' "$plan_only_log" || \
  fail 'Plan-only action metrics were not printed'
grep -Fq 'Rust plan metrics: stage=workspace-scan' "$plan_only_log" || \
  fail 'Plan-only workspace-scan metrics were not printed'
grep -Fq 'Rust plan metrics: stage=visibility' "$plan_only_log" || \
  fail 'Plan-only visibility metrics were not printed'
grep -Fq 'Rust plan only: worker startup and output commit skipped' "$plan_only_log" || \
  fail 'Plan-only run did not report that worker startup was skipped'
if grep -Fq 'Rust frontend:' "$plan_only_log"; then
  fail 'Plan-only run started normal action execution'
fi
[[ ! -e "$state_path" ]] || fail 'Plan-only run wrote the action graph'

baseline_output="$temporary_dir/model.g.dart.baseline"
verification_run_stock_build "$fixture_dir" "build/stock" "$temporary_dir/stock.log" "$dart_bin" "$pub_cache" build --delete-conflicting-outputs --log-performance .dart_tool/build_runner_accelerator/stock-performance || \
  fail 'Stock build failed'
cp "$fixture_dir/lib/model.g.dart" "$baseline_output" || \
  fail 'Could not save stock build output'

if [[ -f "$state_path" ]]; then
  mv "$state_path" "$temporary_dir/graph-v3.before.bin"
fi

run_frontend() {
  local frontend_log="$temporary_dir/frontend.log"
  VERIFY_COMMAND_LOG="$frontend_log" VERIFY_WORKSPACE="$fixture_dir" worker_run_frontend build --root "$fixture_dir" --dart "$dart_bin"
}

run_frontend
second_output="$temporary_dir/second-run.log"
run_frontend >"$second_output" 2>&1
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/frontend.log"
cmp "$baseline_output" "$fixture_dir/lib/model.g.dart"

printf 'smoke: byte-identical=yes no-op=yes\n'
printf 'temporary_results=%s\n' "$temporary_dir"
