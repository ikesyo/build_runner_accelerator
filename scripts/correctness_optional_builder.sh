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
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/optional_builder_app"
lockfile_source="$fixture_dir/pubspec.lock"
temporary_dir=$(mktemp -d)
test_root="$temporary_dir/workspace"
test_fixtures_dir="$test_root/fixtures"
stock_dir=
rust_dir=
case_filter=${CASE_FILTER:-all}

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
  printf 'optional-builder: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,220p' "$log" >&2
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -f "$fixture_dir/build.yaml" ]] || fail "fixture not found: $fixture_dir"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" || \
    fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$test_fixtures_dir"
ln -s "$worker_dir" "$test_root/dart_worker"

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
  PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$script_dir/run_rust_frontend.sh" build --root "$directory" --dart "$dart_bin" \
    --mode rust >"$log" 2>&1
}

prepare_package() {
  local directory=$1
  local config=$2
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/$config" "$directory/build.yaml"
  cp "$fixture_dir/lib/optional_builder.dart" "$directory/lib/optional_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null) || \
    fail "pub get failed for $directory"
}

setup_pair() {
  local name=$1
  local config=$2
  stock_dir="$test_fixtures_dir/${name}-stock"
  rust_dir="$test_fixtures_dir/${name}-rust"
  prepare_package "$stock_dir" "$config"
  prepare_package "$rust_dir" "$config"
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_same_outputs() {
  local relative
  for relative in "$@"; do
    assert_same_file "$stock_dir/$relative" "$rust_dir/$relative"
  done
}

assert_no_outputs() {
  local directory=$1
  shift
  local relative
  for relative in "$@"; do
    [[ ! -e "$directory/$relative" ]] || \
      fail "unexpected output remains: $directory/$relative"
  done
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,220p' "$file" >&2
    fail "${file##*/} does not contain: $expected"
  }
}

should_run() {
  [[ "$case_filter" == all || "$case_filter" == "$1" ]]
}

if should_run demand; then
  setup_pair demand build.yaml
  run_stock "$stock_dir" "$temporary_dir/demand.stock.initial.log" || \
    fail 'stock demand-driven build failed'
  run_rust "$rust_dir" "$temporary_dir/demand.rust.initial.log" || \
    fail 'Rust demand-driven build failed'
  assert_same_outputs \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt
  assert_contains "$temporary_dir/demand.rust.initial.log" \
    'Rust frontend: 3 build action(s)'

  run_rust "$rust_dir" "$temporary_dir/demand.rust.no-op.log" || \
    fail 'Rust optional-builder no-op failed'
  assert_contains "$temporary_dir/demand.rust.no-op.log" \
    'No work to do (Rust frontend)'
  printf 'optional-builder: demand: primary=yes secondary=yes no-op=yes\n'
fi

if should_run no-demand; then
  setup_pair no-demand build.no_consumer.yaml
  run_stock "$stock_dir" "$temporary_dir/no-demand.stock.log" || \
    fail 'stock no-demand build failed'
  run_rust "$rust_dir" "$temporary_dir/no-demand.rust.log" || \
    fail 'Rust no-demand build failed'
  assert_no_outputs "$stock_dir" lib/input.optional.txt
  assert_no_outputs "$rust_dir" lib/input.optional.txt
  assert_contains "$temporary_dir/no-demand.rust.log" \
    'No work to do (Rust frontend)'
  printf 'optional-builder: no-demand: skipped=yes\n'
fi

if should_run incremental; then
  setup_pair incremental build.yaml
  run_stock "$stock_dir" "$temporary_dir/incremental.stock.initial.log" || \
    fail 'stock incremental setup failed'
  run_rust "$rust_dir" "$temporary_dir/incremental.rust.initial.log" || \
    fail 'Rust incremental setup failed'
  printf 'changed optional\n' >"$stock_dir/lib/input.txt"
  printf 'changed optional\n' >"$rust_dir/lib/input.txt"
  run_stock "$stock_dir" "$temporary_dir/incremental.stock.change.log" || \
    fail 'stock optional incremental build failed'
  run_rust "$rust_dir" "$temporary_dir/incremental.rust.change.log" || \
    fail 'Rust optional incremental build failed'
  assert_same_outputs \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt
  printf 'optional-builder: incremental: input-change=yes\n'
fi

if should_run failure; then
  setup_pair failure build.failure.yaml
  if run_stock "$stock_dir" "$temporary_dir/failure.stock.log"; then
    fail 'stock optional failure unexpectedly succeeded'
  fi
  if run_rust "$rust_dir" "$temporary_dir/failure.rust.log"; then
    fail 'Rust optional failure unexpectedly succeeded'
  fi
  assert_contains "$temporary_dir/failure.stock.log" 'optional builder failure'
  assert_contains "$temporary_dir/failure.rust.log" 'optional builder failure'
  assert_no_outputs "$stock_dir" \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt
  assert_no_outputs "$rust_dir" \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt

  cp "$fixture_dir/build.yaml" "$stock_dir/build.yaml"
  cp "$fixture_dir/build.yaml" "$rust_dir/build.yaml"
  run_stock "$stock_dir" "$temporary_dir/failure.stock.recovery.log" || \
    fail 'stock optional failure recovery failed'
  run_rust "$rust_dir" "$temporary_dir/failure.rust.recovery.log" || \
    fail 'Rust optional failure recovery failed'
  assert_same_outputs \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt
  printf 'optional-builder: failure-recovery: atomic=yes\n'
fi

if should_run delete; then
  setup_pair delete build.yaml
  run_stock "$stock_dir" "$temporary_dir/delete.stock.initial.log" || \
    fail 'stock delete setup failed'
  run_rust "$rust_dir" "$temporary_dir/delete.rust.initial.log" || \
    fail 'Rust delete setup failed'
  rm -f -- "$stock_dir/lib/input.txt" "$rust_dir/lib/input.txt"
  run_stock "$stock_dir" "$temporary_dir/delete.stock.change.log" || \
    fail 'stock optional input deletion failed'
  run_rust "$rust_dir" "$temporary_dir/delete.rust.change.log" || \
    fail 'Rust optional input deletion failed'
  assert_no_outputs "$stock_dir" \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt
  assert_no_outputs "$rust_dir" \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt \
    lib/input.glob.txt
  printf 'optional-builder: delete: generated-chain-removed=yes\n'
fi

if should_run rename; then
  setup_pair rename build.yaml
  run_stock "$stock_dir" "$temporary_dir/rename.stock.initial.log" || \
    fail 'stock rename setup failed'
  run_rust "$rust_dir" "$temporary_dir/rename.rust.initial.log" || \
    fail 'Rust rename setup failed'
  mv "$stock_dir/lib/input.txt" "$stock_dir/lib/renamed.txt"
  mv "$rust_dir/lib/input.txt" "$rust_dir/lib/renamed.txt"
  run_stock "$stock_dir" "$temporary_dir/rename.stock.change.log" || \
    fail 'stock optional rename failed'
  run_rust "$rust_dir" "$temporary_dir/rename.rust.change.log" || \
    fail 'Rust optional rename failed'
  assert_same_outputs lib/renamed.optional.txt lib/renamed.primary.txt
  assert_no_outputs "$stock_dir" \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt
  assert_no_outputs "$rust_dir" \
    lib/input.optional.txt lib/input.final.txt lib/input.primary.txt
  printf 'optional-builder: rename: primary-rebuilt=yes stale-chain-removed=yes\n'
fi

printf 'optional-builder: PASS\n'
