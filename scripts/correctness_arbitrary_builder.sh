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
fixture_dir="$repo_root/fixtures/arbitrary_builder_app"
temporary_dir=$(mktemp -d)
test_root="$temporary_dir/workspace"
test_fixtures_dir="$test_root/fixtures"
case_filter=${CASE_FILTER:-all}
stock_dir=
rust_dir=
no_op_checked=0

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
  printf 'arbitrary-builder: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml"
  FAST_BUILD_RUNNER_BIN="$repo_root/rust/target/debug/fast_build_runner"
  export FAST_BUILD_RUNNER_BIN
fi
[[ -x "$FAST_BUILD_RUNNER_BIN" ]] || fail "Rust frontend binary is not executable"

(cd "$worker_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)

mkdir -p "$test_fixtures_dir"
ln -s "$worker_dir" "$test_root/dart_worker"

run_rust() {
  local directory=$1
  local log=$2
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$script_dir/run_rust_frontend.sh" \
    build --root "$directory" --dart "$dart_bin" >"$log" 2>&1
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs >"$log" 2>&1)
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_no_file() {
  local file=$1
  [[ ! -e "$file" ]] || fail "unexpected file remains: $file"
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

assert_failure_diagnostic() {
  local file=$1
  grep -Eiq 'error|exception|failed|invalid|type' "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,180p' "$file" >&2
    fail "${file##*/} does not contain a failure diagnostic"
  }
}

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/arbitrary_builder.dart" "$directory/lib/arbitrary_builder.dart"
  cp "$fixture_dir/lib/input.txt" "$directory/lib/input.txt"
  printf 'special\n' >"$directory/lib/special.txt"
  printf 'ignored\n' >"$directory/lib/ignored.txt"
  printf 'target ignored\n' >"$directory/lib/target-ignored.txt"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)
}

setup_case() {
  local name=$1
  stock_dir="$test_fixtures_dir/${name}-stock"
  rust_dir="$test_fixtures_dir/${name}-rust"
  prepare_package "$stock_dir"
  prepare_package "$rust_dir"

  run_stock "$stock_dir" "$temporary_dir/$name.stock.initial.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.initial.log"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$stock_dir/lib/input.meta.txt" "$rust_dir/lib/input.meta.txt"
  assert_same_file "$stock_dir/lib/special.generated.txt" \
    "$rust_dir/lib/special.generated.txt"
  assert_no_file "$stock_dir/lib/ignored.gen.txt"
  assert_no_file "$stock_dir/lib/ignored.meta.txt"
  assert_no_file "$rust_dir/lib/ignored.gen.txt"
  assert_no_file "$rust_dir/lib/ignored.meta.txt"
  assert_no_file "$stock_dir/lib/target-ignored.gen.txt"
  assert_no_file "$stock_dir/lib/target-ignored.meta.txt"
  assert_no_file "$rust_dir/lib/target-ignored.gen.txt"
  assert_no_file "$rust_dir/lib/target-ignored.meta.txt"
  assert_contains "$temporary_dir/$name.rust.initial.log" \
    'Rust frontend: 3 build action(s)'
  if (( no_op_checked == 0 )); then
    run_rust "$rust_dir" "$temporary_dir/$name.rust.no-op.log"
    assert_contains "$temporary_dir/$name.rust.no-op.log" \
      'No work to do (Rust frontend)'
    no_op_checked=1
  fi
}

run_case_generated_output_delete() {
  local name=generated-output-delete
  setup_case "$name"
  rm -f -- \
    "$stock_dir/lib/input.gen.txt" "$stock_dir/lib/input.meta.txt" \
    "$rust_dir/lib/input.gen.txt" "$rust_dir/lib/input.meta.txt"

  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$stock_dir/lib/input.meta.txt" "$rust_dir/lib/input.meta.txt"
  printf 'arbitrary-builder: generated-output-delete: pass\n'
}

run_case_input_delete() {
  local name=input-delete
  setup_case "$name"
  rm -f -- "$stock_dir/lib/input.txt" "$rust_dir/lib/input.txt"

  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/input.gen.txt"
  assert_no_file "$stock_dir/lib/input.meta.txt"
  assert_no_file "$rust_dir/lib/input.gen.txt"
  assert_no_file "$rust_dir/lib/input.meta.txt"
  assert_contains "$temporary_dir/$name.rust.change.log" \
    'Rust frontend: 0 build action(s)'
  printf 'arbitrary-builder: input-delete: pass\n'
}

run_case_rename() {
  local name=rename
  setup_case "$name"
  mv "$stock_dir/lib/input.txt" "$stock_dir/lib/renamed.txt"
  mv "$rust_dir/lib/input.txt" "$rust_dir/lib/renamed.txt"

  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/renamed.gen.txt" "$rust_dir/lib/renamed.gen.txt"
  assert_same_file "$stock_dir/lib/renamed.meta.txt" "$rust_dir/lib/renamed.meta.txt"
  assert_no_file "$stock_dir/lib/input.gen.txt"
  assert_no_file "$stock_dir/lib/input.meta.txt"
  assert_no_file "$rust_dir/lib/input.gen.txt"
  assert_no_file "$rust_dir/lib/input.meta.txt"
  printf 'arbitrary-builder: rename: pass\n'
}

run_case_failure_recovery() {
  local name=failure-recovery
  setup_case "$name"
  cp "$stock_dir/lib/input.gen.txt" "$temporary_dir/$name.baseline.gen.txt"
  cp "$stock_dir/lib/input.meta.txt" "$temporary_dir/$name.baseline.meta.txt"

  sed -i 's/suffix: " generated"/suffix: 123/' \
    "$stock_dir/build.yaml" "$rust_dir/build.yaml"
  if run_stock "$stock_dir" "$temporary_dir/$name.stock.failure.log"; then
    fail 'stock build unexpectedly succeeded with invalid builder options'
  fi
  if run_rust "$rust_dir" "$temporary_dir/$name.rust.failure.log"; then
    fail 'Rust build unexpectedly succeeded with invalid builder options'
  fi
  assert_failure_diagnostic "$temporary_dir/$name.stock.failure.log"
  assert_failure_diagnostic "$temporary_dir/$name.rust.failure.log"

  local stock_output_state=absent
  local rust_output_state=absent
  [[ -e "$stock_dir/lib/input.gen.txt" ]] && stock_output_state=present
  [[ -e "$rust_dir/lib/input.gen.txt" ]] && rust_output_state=present
  [[ "$stock_output_state" == "$rust_output_state" ]] || \
    fail "failure output state differs: stock=$stock_output_state rust=$rust_output_state"

  sed -i 's/suffix: 123/suffix: " generated"/' \
    "$stock_dir/build.yaml" "$rust_dir/build.yaml"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.recovery.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.recovery.log"
  assert_same_file "$temporary_dir/$name.baseline.gen.txt" \
    "$stock_dir/lib/input.gen.txt"
  assert_same_file "$temporary_dir/$name.baseline.gen.txt" \
    "$rust_dir/lib/input.gen.txt"
  assert_same_file "$temporary_dir/$name.baseline.meta.txt" \
    "$stock_dir/lib/input.meta.txt"
  assert_same_file "$temporary_dir/$name.baseline.meta.txt" \
    "$rust_dir/lib/input.meta.txt"
  printf 'arbitrary-builder: failure-recovery: pass\n'
}

run_case_affected_actions() {
  local name=affected-actions
  setup_case "$name"
  printf 'other\n' >"$stock_dir/lib/other.txt"
  printf 'other\n' >"$rust_dir/lib/other.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.add.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.add.log"
  assert_same_file "$stock_dir/lib/other.gen.txt" "$rust_dir/lib/other.gen.txt"
  assert_same_file "$stock_dir/lib/other.meta.txt" "$rust_dir/lib/other.meta.txt"
  assert_contains "$temporary_dir/$name.rust.add.log" \
    'Rust frontend: 1 build action(s)'
  cp "$rust_dir/lib/other.gen.txt" "$temporary_dir/$name.other.before.gen.txt"
  cp "$rust_dir/lib/other.meta.txt" "$temporary_dir/$name.other.before.meta.txt"

  printf 'changed\n' >"$stock_dir/lib/input.txt"
  printf 'changed\n' >"$rust_dir/lib/input.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/input.gen.txt" "$rust_dir/lib/input.gen.txt"
  assert_same_file "$stock_dir/lib/input.meta.txt" "$rust_dir/lib/input.meta.txt"
  assert_same_file "$temporary_dir/$name.other.before.gen.txt" \
    "$rust_dir/lib/other.gen.txt"
  assert_same_file "$temporary_dir/$name.other.before.meta.txt" \
    "$rust_dir/lib/other.meta.txt"
  assert_contains "$temporary_dir/$name.rust.change.log" \
    'Rust frontend: 1 build action(s)'
  printf 'arbitrary-builder: affected-actions: pass\n'
}

run_case_exclude_glob() {
  local name=exclude-glob
  setup_case "$name"
  printf 'ignored changed\n' >"$stock_dir/lib/ignored.txt"
  printf 'ignored changed\n' >"$rust_dir/lib/ignored.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/ignored.gen.txt"
  assert_no_file "$stock_dir/lib/ignored.meta.txt"
  assert_no_file "$rust_dir/lib/ignored.gen.txt"
  assert_no_file "$rust_dir/lib/ignored.meta.txt"
  assert_contains "$temporary_dir/$name.rust.change.log" \
    'No work to do (Rust frontend)'
  printf 'arbitrary-builder: exclude-glob: pass\n'
}

run_case_target_sources() {
  local name=target-sources
  setup_case "$name"
  printf 'target ignored changed\n' >"$stock_dir/lib/target-ignored.txt"
  printf 'target ignored changed\n' >"$rust_dir/lib/target-ignored.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/target-ignored.gen.txt"
  assert_no_file "$stock_dir/lib/target-ignored.meta.txt"
  assert_no_file "$rust_dir/lib/target-ignored.gen.txt"
  assert_no_file "$rust_dir/lib/target-ignored.meta.txt"
  assert_contains "$temporary_dir/$name.rust.change.log" \
    'No work to do (Rust frontend)'
  printf 'arbitrary-builder: target-sources: pass\n'
}

run_case_exact_extension() {
  local name=exact-extension
  setup_case "$name"
  printf 'special changed\n' >"$stock_dir/lib/special.txt"
  printf 'special changed\n' >"$rust_dir/lib/special.txt"
  run_stock "$stock_dir" "$temporary_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/special.generated.txt" \
    "$rust_dir/lib/special.generated.txt"
  assert_contains "$temporary_dir/$name.rust.change.log" \
    'Rust frontend: 2 build action(s)'
  printf 'arbitrary-builder: exact-extension: pass\n'
}

write_conflict_build_yaml() {
  local directory=$1
  printf '%s\n' \
    'builders:' \
    '  exact_one:' \
    '    import: "package:arbitrary_builder_app/arbitrary_builder.dart"' \
    '    builder_factories:' \
    '      - exactBuilder' \
    '    build_extensions:' \
    '      "^lib/special.txt":' \
    '        - "lib/special.generated.txt"' \
    '    auto_apply: none' \
    '    build_to: source' \
    '  exact_two:' \
    '    import: "package:arbitrary_builder_app/arbitrary_builder.dart"' \
    '    builder_factories:' \
    '      - exactBuilder' \
    '    build_extensions:' \
    '      "^lib/special.txt":' \
    '        - "lib/special.generated.txt"' \
    '    auto_apply: none' \
    '    build_to: source' \
    '' \
    'targets:' \
    '  $default:' \
    '    sources:' \
    '      include:' \
    '        - lib/**' \
    '    builders:' \
    '      arbitrary_builder_app:exact_one:' \
    '        generate_for:' \
    '          - lib/special.txt' \
    '      arbitrary_builder_app:exact_two:' \
    '        generate_for:' \
    '          - lib/special.txt' >"$directory/build.yaml"
}

run_case_output_conflict() {
  local name=output-conflict
  stock_dir="$test_fixtures_dir/${name}-stock"
  rust_dir="$test_fixtures_dir/${name}-rust"
  prepare_package "$stock_dir"
  prepare_package "$rust_dir"
  write_conflict_build_yaml "$stock_dir"
  write_conflict_build_yaml "$rust_dir"

  if run_stock "$stock_dir" "$temporary_dir/$name.stock.log"; then
    fail 'stock build unexpectedly accepted colliding outputs'
  fi
  if run_rust "$rust_dir" "$temporary_dir/$name.rust.log"; then
    fail 'Rust build unexpectedly accepted colliding outputs'
  fi
  assert_contains "$temporary_dir/$name.stock.log" \
    'outputs collide'
  assert_contains "$temporary_dir/$name.rust.log" \
    'builder outputs collide'
  printf 'arbitrary-builder: output-conflict: pass\n'
}

run_selected() {
  local name=$1
  shift
  if [[ "$case_filter" == all || "$case_filter" == "$name" ]]; then
    "$@"
  fi
}

run_selected generated-output-delete run_case_generated_output_delete
run_selected input-delete run_case_input_delete
run_selected rename run_case_rename
run_selected failure-recovery run_case_failure_recovery
run_selected affected-actions run_case_affected_actions
run_selected exclude-glob run_case_exclude_glob
run_selected target-sources run_case_target_sources
run_selected exact-extension run_case_exact_extension
run_selected output-conflict run_case_output_conflict

printf 'arbitrary-builder: cases=%s pass\n' "$case_filter"
