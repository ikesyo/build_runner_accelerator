#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/json_serializable_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-package-smoke.XXXXXX")
workspace_dir="$test_root/fixtures"
stock_dir="$workspace_dir/stock"
accelerator_dir="$workspace_dir/accelerator"
accelerator_pubspec="$test_root/accelerator-pubspec.yaml"
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

cleanup() {
  local status=$?
  if ((status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'package-smoke: retaining failure logs: %s\n' "$test_root" >&2
    return 0
  fi
  [[ -e "$test_root" ]] || return 0
  find "$test_root" -depth -type f -delete
  find "$test_root" -depth -type l -delete
  find "$test_root" -depth -type d -empty -delete
}
trap cleanup EXIT

fail() {
  printf 'package-smoke: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'

# Keep the published-package path dependency in a temporary target project.
mkdir -p "$workspace_dir"
worker_attach "$test_root"
sed \
  -e "s|path: \.\./\.\.|path: $repo_root|" \
  "$fixture_dir/pubspec.yaml" >"$accelerator_pubspec"

prepare_package() {
  local directory=$1
  local pubspec=$2
  mkdir -p "$directory/lib"
  cp "$pubspec" "$directory/pubspec.yaml"
  # Compare the supported fixture solution; fresh resolution can select an
  # incompatible transitive generator release in only this smoke test.
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  worker_pub_get "$directory" "${pub_get_args[@]}"
}

prepare_package "$stock_dir" "$fixture_dir/pubspec.yaml"
prepare_package "$accelerator_dir" "$accelerator_pubspec"

verification_run_stock_build "$stock_dir" 'package-smoke/stock' \
  "$test_root/stock.log" "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
cp "$stock_dir/lib/model.g.dart" "$test_root/model.g.dart.stock"

build_timeout=$(verification_timeout_seconds VERIFY_BUILD_TIMEOUT_SECONDS 300)
verification_run_command_in_dir "$accelerator_dir" 'package-smoke/launcher' \
  "$test_root/accelerator.log" "$build_timeout" env PUB_CACHE="$pub_cache" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 \
  "$dart_bin" --suppress-analytics run build_runner_accelerator \
    build

cmp "$test_root/model.g.dart.stock" "$accelerator_dir/lib/model.g.dart" || \
  fail 'published-package launcher output differs from stock build_runner'

printf 'package-smoke: published-package-path=yes byte-identical=yes\n'
