#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/optional_cleanup_app"
# Run both demand states by default; individual configurations remain selectable.
if [[ -z "${CONFIG:-}" && "${STOCK_ONLY:-0}" != 1 ]]; then
  CONFIG=build.no_demand.yaml bash "$0"
  CONFIG=build.cache.yaml bash "$0"
  CONFIG=build.yaml exec bash "$0"
fi
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/rust"
fail() { printf 'optional-cleanup: FAIL: %s (logs: %s)\n' "$*" "$temporary_dir" >&2; exit 1; }
cleanup() {
  local status=$?
  if ((status == 0)) && [[ "${KEEP_TEMP:-0}" == 0 ]]; then rm -rf -- "$temporary_dir"; fi
}
trap cleanup EXIT
worker_attach "$workspace_root"
prepare() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$fixture_dir/pubspec.lock" "$directory/"
  cp "$fixture_dir/${CONFIG:-build.yaml}" "$directory/build.yaml"
  cp "$fixture_dir/lib/"* "$directory/lib/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" "$dart_bin" "$pub_cache"
}
run_stock() {
  verification_run_stock_build "$stock_dir" stock "$temporary_dir/$1.stock.log" \
    "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
}
run_rust() {
  VERIFY_COMMAND_LOG="$temporary_dir/$1.rust.log" VERIFY_WORKSPACE="$rust_dir" worker_run_frontend \
    build --root "$rust_dir" --dart "$dart_bin" --jobs 1
}

compare() {
  diff -ru "$stock_dir/lib" "$rust_dir/lib" || fail "$1 output mismatch"
  local empty="$temporary_dir/empty" stock_cache rust_cache
  mkdir -p "$empty"
  stock_cache="$stock_dir/.dart_tool/build/generated/optional_cleanup_app"
  rust_cache="$rust_dir/.dart_tool/build_runner_accelerator/cache/optional_cleanup_app"
  [[ -d "$stock_cache" ]] || stock_cache=$empty
  [[ -d "$rust_cache" ]] || rust_cache=$empty
  (cd "$stock_cache" && find . -type f | sort) >"$temporary_dir/stock-cache-files"
  (cd "$rust_cache" && find . -type f | sort) >"$temporary_dir/rust-cache-files"
  diff -u "$temporary_dir/stock-cache-files" "$temporary_dir/rust-cache-files" || fail "$1 cache asset mismatch"
  local asset
  while IFS= read -r asset; do
    cmp "$stock_cache/$asset" "$rust_cache/$asset" || fail "$1 cache bytes: $asset"
  done <"$temporary_dir/stock-cache-files"
}
check_absent() {
  local directory=$1
  local suffix
  for suffix in stage ready final stage.receipt ready.receipt; do
    [[ ! -e "$directory/lib/input.$suffix" ]] || fail "unexpected output: input.$suffix"
  done
}
prepare "$stock_dir"
run_stock initial
if [[ "${STOCK_ONLY:-0}" == 1 ]]; then
  find "$stock_dir/lib" -type f | sort
  printf 'stock observation: %s\n' "$temporary_dir"
  exit 0
fi
worker_ensure_frontend
prepare "$rust_dir"
run_rust initial
compare initial
run_stock no-op
run_rust no-op
compare no-op
if [[ "${CONFIG:-build.yaml}" == build.no_demand.yaml ]]; then
  check_absent "$stock_dir"
  check_absent "$rust_dir"
  printf 'optional-cleanup: no-demand PASS\n'
  exit 0
fi
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.rust.log" || fail 'native no-op dispatched actions'
# Removing normal demand must not let cleanup resurrect an optional chain.
for directory in "$stock_dir" "$rust_dir"; do
  sed -i '/optional_cleanup_app:consumer:/{n;s/generate_for: .*/enabled: false/;}' "$directory/build.yaml"
done
run_stock remove-demand
run_rust remove-demand
compare remove-demand
for directory in "$stock_dir" "$rust_dir"; do
  cp "$fixture_dir/${CONFIG:-build.yaml}" "$directory/build.yaml"
done
run_stock restore-demand
run_rust restore-demand
compare restore-demand
# A missing normal output reuses optional inputs and preserves cleanup bytes.
rm "$stock_dir/lib/input.final" "$rust_dir/lib/input.final"
run_stock output-delete
run_rust output-delete
compare output-delete
for directory in "$stock_dir" "$rust_dir"; do
  printf 'changed\n' >"$directory/lib/input.seed"
done
run_stock change
run_rust change
compare change
for directory in "$stock_dir" "$rust_dir"; do
  printf 'OMIT\n' >"$directory/lib/input.seed"
done
run_stock omit
run_rust omit
compare omit
run_stock omit-no-op
run_rust omit-no-op
compare omit-no-op
check_absent "$stock_dir"
check_absent "$rust_dir"
for directory in "$stock_dir" "$rust_dir"; do
  printf 'restored\n' >"$directory/lib/input.seed"
done
run_stock restore
run_rust restore
compare restore
for failure_marker in FAIL CLEANUP_ERROR; do
  # Failure must retain the native graph and every previously committed byte.
  cp "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary_dir/graph.before"
  rm -rf "$temporary_dir/lib.before"
  cp -R "$rust_dir/lib" "$temporary_dir/lib.before"
  native_cache="$rust_dir/.dart_tool/build_runner_accelerator/cache"
  rm -rf "$temporary_dir/cache.before"
  if [[ -d "$native_cache" ]]; then cp -R "$native_cache" "$temporary_dir/cache.before"; fi
  for directory in "$stock_dir" "$rust_dir"; do
    printf '%s\n' "$failure_marker" >"$directory/lib/input.seed"
  done
  if run_stock "$failure_marker-failure"; then fail 'stock failure succeeded'; fi
  if run_rust "$failure_marker-failure"; then fail 'native failure succeeded'; fi
  cmp "$temporary_dir/graph.before" "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'graph published on failure'
  cp "$rust_dir/lib/input.seed" "$temporary_dir/lib.before/input.seed"
  diff -ru "$temporary_dir/lib.before" "$rust_dir/lib" || fail 'outputs published on failure'
  if [[ -d "$temporary_dir/cache.before" ]]; then
    diff -ru "$temporary_dir/cache.before" "$native_cache" || fail 'cache published on failure'
  fi
  for directory in "$stock_dir" "$rust_dir"; do
    printf 'recovered\n' >"$directory/lib/input.seed"
  done
  run_stock "$failure_marker-recovery"
  run_rust "$failure_marker-recovery"
  compare recovery
done
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/input.seed" "$directory/lib/renamed.seed"
done
run_stock rename
run_rust rename
compare rename
check_absent "$stock_dir"
check_absent "$rust_dir"
for directory in "$stock_dir" "$rust_dir"; do
  rm "$directory/lib/renamed.seed"
done
run_stock delete
run_rust delete
compare delete
printf 'optional-cleanup: PASS\n'
