#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
cargo_bin=${CARGO_BIN:-"$repo_root/.toolchains/cargo/bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
fixture_dir="$repo_root/fixtures/json_serializable_app"
results_dir=$(mktemp -d)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/fast-build-correctness-root.XXXXXX")
test_fixtures_dir="$test_root/fixtures"
mkdir -p "$test_fixtures_dir"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
case_filter=${CASE_FILTER:-all}
cleanup_paths=()
stock_dir=
rust_dir=
new_directory=
case_package_name=

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  for path in "${cleanup_paths[@]}"; do
    remove_tree "$path"
  done
  find "$test_root" -maxdepth 1 -type l -name dart_worker -delete
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT

fail() {
  printf 'correctness: FAIL: %s\n' "$*" >&2
  exit 1
}

if [[ ! -x "$dart_bin" ]]; then
  fail "Dart executable not found: $dart_bin"
fi
if [[ -z "${FAST_BUILD_RUNNER_BIN:-}" && ! -x "$cargo_bin" ]]; then
  fail "Cargo executable not found: $cargo_bin"
fi

prepare_rust_binary() {
  if [[ -n "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
    [[ -x "$FAST_BUILD_RUNNER_BIN" ]] || \
      fail "FAST_BUILD_RUNNER_BIN is not executable: $FAST_BUILD_RUNNER_BIN"
    return 0
  fi
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  local binary="$repo_root/rust/target/debug/fast_build_runner"
  [[ -x "$binary" ]] || fail "Rust frontend binary was not built: $binary"
  export FAST_BUILD_RUNNER_BIN="$binary"
}

prepare_rust_binary

new_package_dir() {
  local role=$1
  # Keep generated package trees out of the synced repository workspace. A
  # workspace synchronizer can replay a deleted generated file while the
  # stock and Rust builds are being compared.
  new_directory=$(mktemp -d "$test_fixtures_dir/fast-build-correctness-${role}.XXXXXX")
  cleanup_paths+=("$new_directory")
}

prepare_package() {
  local directory=$1
  local package_name=$2
  mkdir -p "$directory/lib"
  sed "s/^name: .*/name: $package_name/" \
    "$fixture_dir/pubspec.yaml" >"$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/model.dart" "$directory/lib/model.dart"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get >/dev/null)
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
  (cd "$repo_root" && \
    PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$repo_root/scripts/run_rust_frontend.sh" \
      build --root "$directory" --dart "$dart_bin" >"$log" 2>&1)
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "$text" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,160p' "$file" >&2
    fail "${file##*/} does not contain: $text"
  }
}

assert_different_status() {
  local label=$1
  shift
  if "$@"; then
    fail "$label unexpectedly succeeded"
  fi
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

setup_case() {
  local name=$1
  local package_prefix="fast_build_correctness_${name//-/_}"
  local stock_package_name="${package_prefix}_stock"
  case_package_name="${package_prefix}_rust"
  new_package_dir "${name}-stock"
  stock_dir=$new_directory
  new_package_dir "${name}-rust"
  rust_dir=$new_directory
  prepare_package "$stock_dir" "$stock_package_name"
  prepare_package "$rust_dir" "$case_package_name"

  run_stock "$stock_dir" "$results_dir/$name.stock.initial.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.initial.log"
  assert_same_file \
    "$stock_dir/lib/model.g.dart" \
    "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.initial.log" \
    'Rust frontend: 2 build action(s)'
  cp "$rust_dir/.dart_tool/fast_build_runner/graph-v3.bin" \
    "$results_dir/$name.graph.before.bin"
  cp "$rust_dir/lib/model.g.dart" "$results_dir/$name.model.before.g.dart"
}

run_case_generated_output_delete() {
  local name=generated-output-delete
  setup_case "$name"
  rm -f -- "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 2 build action(s)'
  printf 'correctness: generated-output-delete: pass\n'
}

run_case_input_delete() {
  local name=input-delete
  setup_case "$name"
  rm -f -- "$stock_dir/lib/model.dart" "$rust_dir/lib/model.dart"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/model.g.dart"
  assert_no_file "$rust_dir/lib/model.g.dart"
  assert_no_file "$rust_dir/.dart_tool/fast_build_runner/cache/$case_package_name/lib/model.json_serializable.g.part"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 0 build action(s)'
  printf 'correctness: input-delete: pass\n'
}

rename_model() {
  local directory=$1
  sed -i "s/part 'model.g.dart'/part 'renamed.g.dart'/" \
    "$directory/lib/model.dart"
  mv "$directory/lib/model.dart" "$directory/lib/renamed.dart"
}

run_case_rename() {
  local name=rename
  setup_case "$name"
  rename_model "$stock_dir"
  rename_model "$rust_dir"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/renamed.g.dart" "$rust_dir/lib/renamed.g.dart"
  assert_no_file "$stock_dir/lib/model.g.dart"
  assert_no_file "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 2 build action(s)'
  printf 'correctness: rename: pass\n'
}

break_model_syntax() {
  local directory=$1
  sed -i 's/final int id;/final int id/' "$directory/lib/model.dart"
}

run_case_failure() {
  local name=failure
  setup_case "$name"
  break_model_syntax "$stock_dir"
  break_model_syntax "$rust_dir"

  assert_different_status stock-failure \
    run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  assert_different_status rust-failure \
    run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  cmp "$results_dir/$name.graph.before.bin" \
    "$rust_dir/.dart_tool/fast_build_runner/graph-v3.bin" || \
    fail 'Rust graph changed after failed build'
  # Rust keeps the last successful output because commits happen only after
  # every dirty action succeeds. Current build_runner removes this output on
  # the failed invocation, so compare the safety property explicitly here.
  assert_same_file "$results_dir/$name.model.before.g.dart" \
    "$rust_dir/lib/model.g.dart"
  grep -Eiq 'error|expected|syntax|invalid' \
    "$results_dir/$name.rust.change.log" || {
    printf '%s\n' "--- $results_dir/$name.rust.change.log ---" >&2
    sed -n '1,160p' "$results_dir/$name.rust.change.log" >&2
    fail 'Rust failure did not surface a diagnostic'
  }
  printf 'correctness: failure-rollback-and-diagnostic: pass\n'
}

add_second_model() {
  local directory=$1
  cp "$directory/lib/model.dart" "$directory/lib/other.dart"
  sed -i \
    -e 's/model.g.dart/other.g.dart/g' \
    -e 's/User/OtherUser/g' \
    "$directory/lib/other.dart"
}

run_case_affected_actions() {
  local name=affected-actions
  setup_case "$name"
  add_second_model "$stock_dir"
  add_second_model "$rust_dir"

  run_stock "$stock_dir" "$results_dir/$name.stock.initial-2.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.initial-2.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_same_file "$stock_dir/lib/other.g.dart" "$rust_dir/lib/other.g.dart"
  assert_contains "$results_dir/$name.rust.initial-2.log" \
    'Rust frontend: 2 build action(s)'

  sed -i 's/displayName/displayNameChanged/g' "$stock_dir/lib/model.dart"
  sed -i 's/displayName/displayNameChanged/g' "$rust_dir/lib/model.dart"
  cp "$rust_dir/lib/other.g.dart" "$results_dir/$name.other.before.g.dart"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_same_file "$stock_dir/lib/other.g.dart" "$rust_dir/lib/other.g.dart"
  assert_same_file "$results_dir/$name.other.before.g.dart" "$rust_dir/lib/other.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 2 build action(s)'
  printf 'correctness: affected-action-set: pass\n'
}

restrict_generate_for() {
  local directory=$1
  sed -i \
    -e 's/- lib\/\*\*\.dart/- lib\/model.dart\n          - lib\/missing\/\*\.dart/' \
    "$directory/build.yaml"
}

run_case_generate_for() {
  local name=generate-for
  setup_case "$name"
  add_second_model "$stock_dir"
  add_second_model "$rust_dir"
  restrict_generate_for "$stock_dir"
  restrict_generate_for "$rust_dir"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_no_file "$stock_dir/lib/other.g.dart"
  assert_no_file "$rust_dir/lib/other.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 2 build action(s)'
  printf 'correctness: generate-for: pass\n'
}

configure_builder_options() {
  local directory=$1
  printf '%s\n' \
    '        options:' \
    '          field_rename: snake' \
    '          include_if_null: false' \
    >>"$directory/build.yaml"
}

run_case_builder_options() {
  local name=builder-options
  setup_case "$name"
  configure_builder_options "$stock_dir"
  configure_builder_options "$rust_dir"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$stock_dir/lib/model.g.dart" "'display_name':"
  assert_contains "$rust_dir/lib/model.g.dart" "'display_name':"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 2 build action(s)'
  printf 'correctness: builder-options: pass\n'
}

add_matching_part() {
  local directory=$1
  printf '%s\n' '// extra source part' \
    >"$directory/lib/model.extra.json_serializable.g.part"
}

run_case_glob_membership() {
  local name=glob-membership
  setup_case "$name"
  add_matching_part "$stock_dir"
  add_matching_part "$rust_dir"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 1 build action(s)'
  printf 'correctness: glob-membership: pass\n'
}

setup_conditional_dependency_case() {
  local name=$1
  local package_prefix="fast_build_correctness_${name//-/_}"
  local stock_package_name="${package_prefix}_stock"
  case_package_name="${package_prefix}_rust"
  new_package_dir "${name}-stock"
  stock_dir=$new_directory
  new_package_dir "${name}-rust"
  rust_dir=$new_directory
  prepare_package "$stock_dir" "$stock_package_name"
  prepare_package "$rust_dir" "$case_package_name"

  for directory in "$stock_dir" "$rust_dir"; do
    sed -i 's/- lib\/\*\*\.dart/- lib\/model.dart/' \
      "$directory/build.yaml"
    sed -i "1i import 'conditional_base.dart' if (dart.library.io) 'conditional_io.dart' if (dart.library.html) 'conditional_html.dart';" \
      "$directory/lib/model.dart"
    printf '%s\n' "const conditionalValue = 'base';" \
      >"$directory/lib/conditional_base.dart"
    printf '%s\n' "const conditionalValue = 'io';" \
      >"$directory/lib/conditional_io.dart"
  done

  run_stock "$stock_dir" "$results_dir/$name.stock.initial.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.initial.log"
  assert_same_file \
    "$stock_dir/lib/model.g.dart" \
    "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.initial.log" \
    'Rust frontend: 2 build action(s)'
}

run_case_conditional_dependency() {
  local name=conditional-dependency
  setup_conditional_dependency_case "$name"
  printf '%s\n' "const conditionalValue = 'changed';" \
    >"$stock_dir/lib/conditional_html.dart"
  printf '%s\n' "const conditionalValue = 'changed';" \
    >"$rust_dir/lib/conditional_html.dart"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'Rust frontend: 1 build action(s)'
  printf 'correctness: conditional-dependency: pass\n'
}

run_case_fallback() {
  local name=fallback
  setup_case "$name"
  printf '        options: {}\n' >>"$stock_dir/build.yaml"
  printf '        options: {}\n' >>"$rust_dir/build.yaml"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/model.g.dart" "$rust_dir/lib/model.g.dart"
  assert_contains "$results_dir/$name.rust.change.log" \
    'using Dart fallback'
  printf 'correctness: dart-fallback: pass\n'
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
run_selected failure run_case_failure
run_selected affected-actions run_case_affected_actions
run_selected generate-for run_case_generate_for
run_selected builder-options run_case_builder_options
run_selected glob-membership run_case_glob_membership
run_selected conditional-dependency run_case_conditional_dependency
run_selected fallback run_case_fallback

printf 'correctness: cases=%s pass\n' "$case_filter"
