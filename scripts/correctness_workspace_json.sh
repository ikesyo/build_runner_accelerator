#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary=$(mktemp -d)
workspace="$temporary/workspace"
stock="$workspace/fixtures/stock"
native="$workspace/fixtures/native"
cleanup() {
  local status=$?
  if ((status != 0)); then
    printf 'workspace-json: retained failure files: %s\n' "$temporary" >&2
  else
    rm -rf -- "$temporary"
  fi
}
trap cleanup EXIT
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then pub_get_args+=(--offline); fi
fail() { printf 'workspace-json: FAIL: %s\n' "$*" >&2; exit 1; }
worker_ensure_frontend
worker_prepare "${pub_get_args[@]}"
mkdir -p "$workspace/fixtures"
worker_attach "$workspace"
cp -R "$repo_root/fixtures/workspace_json_app" "$stock"
cp -R "$repo_root/fixtures/workspace_json_app" "$native"
worker_pub_get "$stock" "${pub_get_args[@]}"
worker_pub_get "$native" "${pub_get_args[@]}"
run_stock() {
  verification_run_stock_build "$stock" "workspace-json/stock/$1" "$temporary/stock-$1.log" "$dart_bin" "$pub_cache" build --workspace
}
run_native() {
  VERIFY_COMMAND_LOG="$temporary/native-$1.log" VERIFY_WORKSPACE="$native/a" \
    BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
    build --root "$native/a" --dart "$dart_bin" --workspace --force-jit --jobs 2
}
compare() {
  diff -r "$stock/a/lib" "$native/a/lib" || fail "member a differs: $1"
  diff -r "$stock/b/lib" "$native/b/lib" || fail "member b differs: $1"
}
for step in clean noop edit delete rename failure recovery; do
  case "$step" in
    edit)
      for base in "$stock" "$native"; do
        sed -i 's/final int value;/final double value;/' "$base/a/lib/model.dart"
      done ;;
    delete)
      rm "$stock/b/lib/model.dart" "$native/b/lib/model.dart" ;;
    rename)
      for base in "$stock" "$native"; do
        mv "$base/a/lib/model.dart" "$base/a/lib/renamed.dart"
        sed -i 's/model.g.dart/renamed.g.dart/' "$base/a/lib/renamed.dart"
      done ;;
    failure)
      cp "$native/a/lib/renamed.g.dart" "$temporary/before.g.dart"
      cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/before.graph"
      cp "$native/a/lib/renamed.dart" "$temporary/good.dart"
      printf '\nthis is invalid dart\n' >> "$native/a/lib/renamed.dart"
      if run_native failure; then fail 'invalid input succeeded'; fi
      cmp "$temporary/before.g.dart" "$native/a/lib/renamed.g.dart" || fail 'failure changed output'
      cmp "$temporary/before.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'failure changed graph'
      continue ;;
    recovery)
      cp "$temporary/good.dart" "$native/a/lib/renamed.dart" ;;
  esac
  run_stock "$step"
  run_native "$step"
  compare "$step"
  if [[ "$step" == noop ]]; then
    grep -Fq 'No work to do (Rust frontend)' "$temporary/native-noop.log" || fail 'no-op performed work'
  fi
done
printf 'workspace-json: PASS stock/native=yes clean=yes noop=yes edit=yes delete=yes rename=yes failure-recovery=yes\n'
