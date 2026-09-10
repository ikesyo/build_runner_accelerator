#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/json_serializable_app"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-package-smoke.XXXXXX")
workspace_dir="$test_root/fixtures"
stock_dir="$workspace_dir/stock"
accelerator_dir="$workspace_dir/accelerator"
accelerator_pubspec="$test_root/accelerator-pubspec.yaml"

cleanup() {
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
[[ -n "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]] || \
  fail 'BUILD_RUNNER_ACCELERATOR_BIN is required'
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend binary is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

# Keep the published-package path dependency in a temporary target project.
mkdir -p "$workspace_dir"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
sed \
  -e 's/build_runner_accelerator_worker/build_runner_accelerator/' \
  -e "s|path: ../../dart_worker|path: $repo_root|" \
  "$fixture_dir/pubspec.yaml" >"$accelerator_pubspec"

prepare_package() {
  local directory=$1
  local pubspec=$2
  mkdir -p "$directory/lib"
  cp "$pubspec" "$directory/pubspec.yaml"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)
}

prepare_package "$stock_dir" "$fixture_dir/pubspec.yaml"
prepare_package "$accelerator_dir" "$accelerator_pubspec"

(cd "$stock_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
    build --delete-conflicting-outputs >/dev/null)
cp "$stock_dir/lib/model.g.dart" "$test_root/model.g.dart.stock"

(cd "$accelerator_dir" && \
  PUB_CACHE="$pub_cache" \
  BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 \
  "$dart_bin" --suppress-analytics run build_runner_accelerator \
    build --mode rust >/dev/null)

cmp "$test_root/model.g.dart.stock" "$accelerator_dir/lib/model.g.dart" || \
  fail 'published-package launcher output differs from stock build_runner'

printf 'package-smoke: published-package-path=yes byte-identical=yes\n'
