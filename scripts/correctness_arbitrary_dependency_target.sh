#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"

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
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'arbitrary-dependency-target: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,220p' "$log" >&2
    fi
  done
  exit 1
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,180p' "$file" >&2
    fail "${file##*/} does not contain: $expected"
  }
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

worker_ensure_frontend || fail 'Rust frontend build failed'

worker_prepare >/dev/null || fail 'worker pub get failed'

mkdir -p "$fixture_root"
worker_attach "$workspace_root"

write_root_pubspec() {
  local directory=$1
  mkdir -p "$directory/lib" "$directory/packages/dependency_target_package"
  cat >"$directory/pubspec.yaml" <<'EOF'
name: arbitrary_dependency_target_app
publish_to: none

environment:
  sdk: ">=3.13.0 <4.0.0"

dependencies:
  build: 4.0.10
  dependency_target_package:
    path: packages/dependency_target_package

dev_dependencies:
  build_runner: 2.16.1
  build_runner_accelerator:
    path: ../..
EOF
  cat >"$directory/build.yaml" <<'EOF'
targets:
  $default:
    sources:
      include:
        - lib/**
    builders:
      dependency_target_package:package_target_seed:
        generate_for:
          - lib/root.txt
EOF
  cat >"$directory/lib/root.dart" <<'EOF'
void main() {}
EOF
  printf 'hello root\n' >"$directory/lib/root.txt"
}

write_dependency_package() {
  local directory=$1
  local package_directory="$directory/packages/dependency_target_package"
  mkdir -p "$package_directory/lib"
  cat >"$package_directory/pubspec.yaml" <<'EOF'
name: dependency_target_package
publish_to: none

environment:
  sdk: ">=3.13.0 <4.0.0"

dependencies:
  build: 4.0.10
EOF
  cat >"$package_directory/build.yaml" <<'EOF'
builders:
  package_target_seed:
    import: "package:dependency_target_package/dependency_builder.dart"
    builder_factories:
      - seedBuilder
    build_extensions:
      ".txt":
        - ".seed.txt"
    auto_apply: none
    build_to: cache

targets:
  $default:
    sources:
      include:
        - lib/**
    builders:
      dependency_target_package:package_target_seed:
        generate_for:
          - lib/input.txt
EOF
  cp "$repo_root/fixtures/arbitrary_dependency_app/lib/dependency_builder.dart" \
    "$package_directory/lib/dependency_builder.dart"
  printf 'hello dependency\n' >"$package_directory/lib/input.txt"
}

prepare_package() {
  local directory=$1
  write_root_pubspec "$directory"
  write_dependency_package "$directory"
  cp "$repo_root/fixtures/arbitrary_dependency_app/pubspec.lock" "$directory/pubspec.lock"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" || \
    fail "pub get failed for $directory"
}

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
}
run_rust() {
  local directory=$1
  local log=$2
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend \
    build --root "$directory" --dart "$dart_bin" --mode rust
}
prepare_package "$stock_dir"
prepare_package "$rust_dir"
if ! run_stock "$stock_dir" "$temporary_dir/stock.initial.log"; then
  fail 'stock initial build failed'
fi
if ! run_rust "$rust_dir" "$temporary_dir/rust.initial.log"; then
  fail 'Rust initial build failed'
fi

stock_cache=$(find "$stock_dir/.dart_tool/build" -type f -name 'input.seed.txt' -print -quit)
[[ -n "$stock_cache" ]] || fail 'stock dependency target did not produce a cache output'
rust_cache="$rust_dir/.dart_tool/build_runner_accelerator/cache/dependency_target_package/lib/input.seed.txt"
assert_same_file "$stock_cache" "$rust_cache"
stock_root_cache=$(find "$stock_dir/.dart_tool/build" -type f -name 'root.seed.txt' -print -quit)
[[ -n "$stock_root_cache" ]] || fail 'stock root target did not produce a cache output'
rust_root_cache="$rust_dir/.dart_tool/build_runner_accelerator/cache/arbitrary_dependency_target_app/lib/root.seed.txt"
assert_same_file "$stock_root_cache" "$rust_root_cache"
assert_contains "$temporary_dir/rust.initial.log" 'Rust frontend: 2 build action(s)'

if ! VERIFY_COMMAND_LOG="$temporary_dir/rust.no-op.log" VERIFY_WORKSPACE="$rust_dir" worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" \
    --mode rust; then
  fail 'Rust no-op build failed'
fi
assert_contains "$temporary_dir/rust.no-op.log" 'No work to do (Rust frontend)'

printf 'changed dependency\n' >"$stock_dir/packages/dependency_target_package/lib/input.txt"
printf 'changed dependency\n' >"$rust_dir/packages/dependency_target_package/lib/input.txt"
if ! run_stock "$stock_dir" "$temporary_dir/stock.dependency-change.log"; then
  fail 'stock dependency input-change build failed'
fi
if ! VERIFY_COMMAND_LOG="$temporary_dir/rust.dependency-change.log" VERIFY_WORKSPACE="$rust_dir" worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" \
    --mode rust; then
  fail 'Rust dependency input-change build failed'
fi
assert_same_file "$stock_cache" "$rust_cache"
assert_same_file "$stock_root_cache" "$rust_root_cache"
assert_contains "$temporary_dir/rust.dependency-change.log" 'Rust frontend: 1 build action(s)'

printf 'changed root\n' >"$stock_dir/lib/root.txt"
printf 'changed root\n' >"$rust_dir/lib/root.txt"
if ! run_stock "$stock_dir" "$temporary_dir/stock.root-change.log"; then
  fail 'stock root input-change build failed'
fi
if ! VERIFY_COMMAND_LOG="$temporary_dir/rust.root-change.log" VERIFY_WORKSPACE="$rust_dir" worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" \
    --mode rust; then
  fail 'Rust root input-change build failed'
fi
assert_same_file "$stock_root_cache" "$rust_root_cache"
assert_contains "$temporary_dir/rust.root-change.log" 'Rust frontend: 1 build action(s)'

printf 'arbitrary-dependency-target: dependency-owned-target=yes multiple-targets=yes cache-output=yes incremental=yes\n'
