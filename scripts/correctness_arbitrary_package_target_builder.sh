#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
toolchain_bin=${RUST_TOOLCHAIN_BIN:-"$repo_root/.toolchains/rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin"}
cargo_bin=${CARGO_BIN:-"$toolchain_bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
worker_dir="$repo_root/dart_worker"
builder_source="$repo_root/fixtures/arbitrary_dependency_app/lib/dependency_builder.dart"
lock_source="$repo_root/fixtures/arbitrary_dependency_app/pubspec.lock"
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
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'arbitrary-package-target: FAIL: %s\n' "$*" >&2
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

assert_no_file() {
  local path=$1
  [[ ! -e "$path" ]] || fail "unexpected file: $path"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"

if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" || \
    fail 'Rust frontend build failed'
  FAST_BUILD_RUNNER_BIN="$repo_root/rust/target/debug/fast_build_runner"
  export FAST_BUILD_RUNNER_BIN
fi
[[ -x "$FAST_BUILD_RUNNER_BIN" ]] || \
  fail "Rust frontend binary is not executable: $FAST_BUILD_RUNNER_BIN"

(cd "$worker_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null) || \
  fail 'worker pub get failed'

mkdir -p "$fixture_root"
ln -s "$worker_dir" "$workspace_root/dart_worker"

write_package_pubspec() {
  local directory=$1
  printf '%s\n' \
    'name: arbitrary_package_target_app' \
    'publish_to: none' \
    '' \
    'environment:' \
    '  sdk: ">=3.13.0 <4.0.0"' \
    '' \
    'dependencies:' \
    '  build: 4.0.0' \
    '  dependency_builder_package:' \
    '    path: packages/dependency_builder_package' \
    '' \
    'dev_dependencies:' \
    '  build_runner: 2.7.2' \
    '  fast_build_runner_worker:' \
    '    path: ../../dart_worker' >"$directory/pubspec.yaml"
}

write_dependency_pubspec() {
  local directory=$1
  printf '%s\n' \
    'name: dependency_builder_package' \
    'publish_to: none' \
    '' \
    'environment:' \
    '  sdk: ">=3.13.0 <4.0.0"' \
    '' \
    'dependencies:' \
    '  build: 4.0.0' >"$directory/pubspec.yaml"
}

write_dependency_build_yaml() {
  local directory=$1
  printf '%s\n' \
    'builders:' \
    '  package_seed_builder:' \
    '    import: "package:dependency_builder_package/dependency_builder.dart"' \
    '    builder_factories:' \
    '      - seedBuilder' \
    '    build_extensions:' \
    '      ".txt":' \
    '        - ".seed.txt"' \
    '    defaults:' \
    '      generate_for:' \
    '        include:' \
    '          - lib/**/*.txt' \
    '        exclude:' \
    '          - lib/**/*.seed.txt' \
    '          - lib/**/*.summary.txt' \
    '    auto_apply: dependents' \
    '    build_to: cache' \
    '  package_summary_builder:' \
    '    import: "package:dependency_builder_package/dependency_builder.dart"' \
    '    builder_factories:' \
    '      - summaryBuilder' \
    '    build_extensions:' \
    '      ".txt":' \
    '        - ".summary.txt"' \
    '    required_inputs:' \
    '      - ".seed.txt"' \
    '    defaults:' \
    '      generate_for:' \
    '        include:' \
    '          - lib/**/*.txt' \
    '        exclude:' \
    '          - lib/**/*.seed.txt' \
    '          - lib/**/*.summary.txt' \
    '    auto_apply: dependents' \
    '    build_to: source' >"$directory/build.yaml"
}

write_root_build_yaml() {
  local directory=$1
  printf '%s\n' \
    'targets:' \
    '  $default:' \
    '    sources:' \
    '      include:' \
    '        - lib/**' \
    '      exclude:' \
    '        - lib/ignored.txt' >"$directory/build.yaml"
}

prepare_package() {
  local directory=$1
  local dependency_directory="$directory/packages/dependency_builder_package"
  mkdir -p "$directory/lib" "$dependency_directory/lib"
  write_package_pubspec "$directory"
  write_dependency_pubspec "$dependency_directory"
  write_dependency_build_yaml "$dependency_directory"
  write_root_build_yaml "$directory"
  cp "$builder_source" "$dependency_directory/lib/dependency_builder.dart"
  cp "$lock_source" "$directory/pubspec.lock"
  printf 'hello\n' >"$directory/lib/input.txt"
  printf 'ignored\n' >"$directory/lib/ignored.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null) || \
    fail "pub get failed for $directory"
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs >"$log" 2>&1)
}

run_rust() {
  local directory=$1
  local log=$2
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$script_dir/run_rust_frontend.sh" \
    build --root "$directory" --dart "$dart_bin" >"$log" 2>&1
}

run_required() {
  local label=$1
  shift
  if ! "$@"; then
    fail "$label failed"
  fi
}

prepare_package "$stock_dir"
prepare_package "$rust_dir"
run_required 'stock initial build' \
  run_stock "$stock_dir" "$temporary_dir/stock.initial.log"
run_required 'Rust initial build' \
  run_rust "$rust_dir" "$temporary_dir/rust.initial.log"
assert_same_file "$stock_dir/lib/input.summary.txt" \
  "$rust_dir/lib/input.summary.txt"
assert_contains "$stock_dir/lib/input.summary.txt" 'hello seed summary'
assert_no_file "$stock_dir/lib/ignored.summary.txt"
assert_no_file "$rust_dir/lib/ignored.summary.txt"
assert_contains "$temporary_dir/rust.initial.log" \
  'Rust frontend: 2 build action(s)'

run_required 'Rust no-op build' \
  run_rust "$rust_dir" "$temporary_dir/rust.no-op.log"
assert_contains "$temporary_dir/rust.no-op.log" \
  'No work to do (Rust frontend)'

printf 'changed\n' >"$stock_dir/lib/input.txt"
printf 'changed\n' >"$rust_dir/lib/input.txt"
run_required 'stock input-change build' \
  run_stock "$stock_dir" "$temporary_dir/stock.change.log"
run_required 'Rust input-change build' \
  run_rust "$rust_dir" "$temporary_dir/rust.change.log"
assert_same_file "$stock_dir/lib/input.summary.txt" \
  "$rust_dir/lib/input.summary.txt"
assert_contains "$stock_dir/lib/input.summary.txt" 'changed seed summary'
assert_contains "$temporary_dir/rust.change.log" \
  'Rust frontend: 2 build action(s)'

printf 'arbitrary-package-target: auto-apply=yes target-boundary=yes phase-order=yes\n'
