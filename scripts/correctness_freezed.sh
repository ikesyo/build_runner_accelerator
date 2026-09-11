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
fixture_dir="$repo_root/fixtures/freezed_app"
results_dir=$(mktemp -d)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-freezed-root.XXXXXX")
test_fixtures_dir="$test_root/fixtures"
mkdir -p "$test_fixtures_dir"
ln -s "$repo_root/dart_worker" "$test_root/dart_worker"
case_filter=${CASE_FILTER:-all}
cleanup_paths=()
stock_dir=
rust_dir=
new_directory=
stock_package_name=
case_package_name=

remove_tree() {
  local path=$1
  [[ -e "$path" ]] || return 0
  find "$path" -depth -type f -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  if [[ "${KEEP_TEMP:-0}" == 1 ]]; then
    printf 'freezed-correctness: keeping temp workspace %s\n' "$test_root" >&2
    return 0
  fi
  for path in "${cleanup_paths[@]}"; do
    remove_tree "$path"
  done
  find "$test_root" -maxdepth 1 -type l -name dart_worker -delete
  remove_tree "$test_root"
  remove_tree "$results_dir"
}
trap cleanup EXIT

fail() {
  printf 'freezed-correctness: FAIL: %s\n' "$*" >&2
  exit 1
}

if [[ ! -x "$dart_bin" ]]; then
  fail "Dart executable not found: $dart_bin"
fi
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" && ! -x "$cargo_bin" ]]; then
  fail "Cargo executable not found: $cargo_bin"
fi

prepare_rust_binary() {
  if [[ -n "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
    [[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
      fail "BUILD_RUNNER_ACCELERATOR_BIN is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"
    return 0
  fi
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  local binary="$repo_root/rust/target/debug/build_runner_accelerator"
  [[ -x "$binary" ]] || fail "Rust frontend binary was not built: $binary"
  export BUILD_RUNNER_ACCELERATOR_BIN="$binary"
}

prepare_rust_binary

new_package_dir() {
  local role=$1
  new_directory=$(mktemp -d "$test_fixtures_dir/build-runner-accelerator-freezed-${role}.XXXXXX")
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
  cp "$fixture_dir/lib/serializable.dart" "$directory/lib/serializable.dart"
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
      BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
      "$repo_root/scripts/run_rust_frontend.sh" \
      build --root "$directory" --dart "$dart_bin" --jobs 1 >"$log" 2>&1)
}

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq -- "$text" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,180p' "$file" >&2
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

assert_source_outputs() {
  local left=$1
  local right=$2
  for output in model.freezed.dart serializable.freezed.dart serializable.g.dart; do
    assert_same_file "$left/lib/$output" "$right/lib/$output"
  done
}

assert_combining_part() {
  assert_same_file \
    "$1/.dart_tool/build/generated/$stock_package_name/lib/serializable.json_serializable.g.part" \
    "$2/.dart_tool/build_runner_accelerator/cache/$case_package_name/lib/serializable.json_serializable.g.part"
}

assert_rust_actions() {
  local log=$1
  local count=$2
  assert_contains "$log" "Rust frontend: $count build action(s)"
}

setup_case() {
  local name=$1
  local package_prefix="fast_build_freezed_${name//-/_}"
  stock_package_name="${package_prefix}_stock"
  case_package_name="${package_prefix}_rust"
  new_package_dir "${name}-stock"
  stock_dir=$new_directory
  new_package_dir "${name}-rust"
  rust_dir=$new_directory
  prepare_package "$stock_dir" "$stock_package_name"
  prepare_package "$rust_dir" "$case_package_name"

  run_stock "$stock_dir" "$results_dir/$name.stock.initial.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.initial.log"
  assert_source_outputs "$stock_dir" "$rust_dir"
  assert_combining_part "$stock_dir" "$rust_dir"
  assert_rust_actions "$results_dir/$name.rust.initial.log" 4
  cp "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" \
    "$results_dir/$name.graph.before.bin"
  cp "$rust_dir/lib/model.freezed.dart" \
    "$results_dir/$name.model.before.freezed.dart"
}

run_case_generated_output_delete() {
  local name=generated-output-delete
  setup_case "$name"
  for directory in "$stock_dir" "$rust_dir"; do
    rm -f -- "$directory/lib/model.freezed.dart" \
      "$directory/lib/serializable.freezed.dart" \
      "$directory/lib/serializable.g.dart" \
      "$directory/.dart_tool/build_runner_accelerator/cache/$case_package_name/lib/serializable.json_serializable.g.part"
  done

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_source_outputs "$stock_dir" "$rust_dir"
  assert_combining_part "$stock_dir" "$rust_dir"
  assert_rust_actions "$results_dir/$name.rust.change.log" 4
  printf 'freezed-correctness: generated-output-delete: pass\n'
}

run_case_noop() {
  local name=noop
  setup_case "$name"
  run_rust "$rust_dir" "$results_dir/$name.rust.noop.log"
  assert_contains "$results_dir/$name.rust.noop.log" 'No work to do (Rust frontend)'
  printf 'freezed-correctness: no-op: pass\n'
}

run_case_input_delete() {
  local name=input-delete
  setup_case "$name"
  rm -f -- "$stock_dir/lib/model.dart" "$rust_dir/lib/model.dart"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/model.freezed.dart"
  assert_no_file "$rust_dir/lib/model.freezed.dart"
  for output in serializable.freezed.dart serializable.g.dart; do
    assert_same_file "$stock_dir/lib/$output" "$rust_dir/lib/$output"
  done
  assert_combining_part "$stock_dir" "$rust_dir"
  assert_rust_actions "$results_dir/$name.rust.change.log" 0
  printf 'freezed-correctness: input-delete: pass\n'
}

rename_model() {
  local directory=$1
  sed -i "s/part 'model.freezed.dart'/part 'renamed.freezed.dart'/" \
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
  assert_same_file "$stock_dir/lib/renamed.freezed.dart" \
    "$rust_dir/lib/renamed.freezed.dart"
  assert_no_file "$stock_dir/lib/model.freezed.dart"
  assert_no_file "$rust_dir/lib/model.freezed.dart"
  assert_rust_actions "$results_dir/$name.rust.change.log" 1
  printf 'freezed-correctness: rename: pass\n'
}

break_model_syntax() {
  local directory=$1
  sed -i 's/required int id,/required int id/' "$directory/lib/model.dart"
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
    "$rust_dir/.dart_tool/build_runner_accelerator/graph-v3.bin" || \
    fail 'Rust graph changed after failed Freezed build'
  assert_same_file "$results_dir/$name.model.before.freezed.dart" \
    "$rust_dir/lib/model.freezed.dart"
  grep -Eiq 'error|expected|syntax|invalid' \
    "$results_dir/$name.rust.change.log" || fail 'Rust failure did not surface a diagnostic'
  printf 'freezed-correctness: failure-rollback-and-diagnostic: pass\n'
}

add_second_model() {
  local directory=$1
  cp "$directory/lib/model.dart" "$directory/lib/other.dart"
  sed -i \
    -e 's/model.freezed.dart/other.freezed.dart/g' \
    -e 's/User/OtherUser/g' \
    "$directory/lib/other.dart"
}

run_case_affected_actions() {
  local name=affected-actions
  setup_case "$name"
  add_second_model "$stock_dir"
  add_second_model "$rust_dir"
  run_stock "$stock_dir" "$results_dir/$name.stock.add.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.add.log"
  assert_same_file "$stock_dir/lib/other.freezed.dart" \
    "$rust_dir/lib/other.freezed.dart"
  cp "$rust_dir/lib/other.freezed.dart" \
    "$results_dir/$name.other.before.freezed.dart"

  sed -i 's/displayName/displayNameChanged/g' "$stock_dir/lib/model.dart"
  sed -i 's/displayName/displayNameChanged/g' "$rust_dir/lib/model.dart"
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_source_outputs "$stock_dir" "$rust_dir"
  assert_combining_part "$stock_dir" "$rust_dir"
  assert_same_file "$results_dir/$name.other.before.freezed.dart" \
    "$rust_dir/lib/other.freezed.dart"
  assert_rust_actions "$results_dir/$name.rust.change.log" 1
  printf 'freezed-correctness: affected-action-set: pass\n'
}

run_case_dependency() {
  local name=dependency
  setup_case "$name"
  for directory in "$stock_dir" "$rust_dir"; do
    printf '%s\n' 'class Dependency { const Dependency({this.value = 0}); final int value; }' \
      >"$directory/lib/dependency.dart"
    sed -i "1i import 'dependency.dart';" "$directory/lib/model.dart"
    sed -i 's/required int id,/required int id,\n    required Dependency dependency,/' \
      "$directory/lib/model.dart"
  done
  run_stock "$stock_dir" "$results_dir/$name.stock.add.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.add.log"
  assert_same_file "$stock_dir/lib/model.freezed.dart" \
    "$rust_dir/lib/model.freezed.dart"

  for directory in "$stock_dir" "$rust_dir"; do
    sed -i 's/value = 0/value = 1/' "$directory/lib/dependency.dart"
  done
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_source_outputs "$stock_dir" "$rust_dir"
  assert_combining_part "$stock_dir" "$rust_dir"
  # The changed dependency is itself a matching Freezed input and therefore
  # contributes a successful no-output action in addition to the model.
  assert_rust_actions "$results_dir/$name.rust.change.log" 2
  printf 'freezed-correctness: resolver-dependency: pass\n'
}

run_case_annotation_removal() {
  local name=annotation-removal
  setup_case "$name"
  for directory in "$stock_dir" "$rust_dir"; do
    sed -i 's/^@freezed$/@Deprecated("not-freezed")/' "$directory/lib/model.dart"
  done
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/model.freezed.dart"
  assert_no_file "$rust_dir/lib/model.freezed.dart"
  for output in serializable.freezed.dart serializable.g.dart; do
    assert_same_file "$stock_dir/lib/$output" "$rust_dir/lib/$output"
  done
  assert_rust_actions "$results_dir/$name.rust.change.log" 1
  printf 'freezed-correctness: optional-output-removal: pass\n'
}

replace_serializable_with_json() {
  local directory=$1
  cat >"$directory/lib/serializable.dart" <<'EOF'
import 'package:json_annotation/json_annotation.dart';

part 'serializable.g.dart';

@JsonSerializable()
class SerializableUser {
  const SerializableUser({required this.id, required this.displayName});

  final int id;
  final String displayName;

  factory SerializableUser.fromJson(Map<String, Object?> json) =>
      _$SerializableUserFromJson(json);

  Map<String, Object?> toJson() => _$SerializableUserToJson(this);
}
EOF
}

run_case_combined_output_removal() {
  local name=combined-output-removal
  setup_case "$name"
  replace_serializable_with_json "$stock_dir"
  replace_serializable_with_json "$rust_dir"

  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_no_file "$stock_dir/lib/serializable.freezed.dart"
  assert_no_file "$rust_dir/lib/serializable.freezed.dart"
  assert_same_file "$stock_dir/lib/serializable.g.dart" \
    "$rust_dir/lib/serializable.g.dart"
  assert_combining_part "$stock_dir" "$rust_dir"
  assert_rust_actions "$results_dir/$name.rust.change.log" 3
  printf 'freezed-correctness: combined-output-removal: pass\n'
}

run_case_builder_options() {
  local name=builder-options
  setup_case "$name"
  for directory in "$stock_dir" "$rust_dir"; do
    sed -i '/          - lib\/\*\*\.dart/a\        options:\n          format: true' \
      "$directory/build.yaml"
  done
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_source_outputs "$stock_dir" "$rust_dir"
  assert_combining_part "$stock_dir" "$rust_dir"
  assert_rust_actions "$results_dir/$name.rust.change.log" 4
  printf 'freezed-correctness: builder-options: pass\n'
}

run_case_glob_membership() {
  local name=glob-membership
  setup_case "$name"
  add_second_model "$stock_dir"
  add_second_model "$rust_dir"
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_same_file "$stock_dir/lib/other.freezed.dart" \
    "$rust_dir/lib/other.freezed.dart"
  assert_rust_actions "$results_dir/$name.rust.change.log" 1
  printf 'freezed-correctness: glob-membership: pass\n'
}

run_case_fallback() {
  local name=fallback
  setup_case "$name"
  for directory in "$stock_dir" "$rust_dir"; do
    sed -i '/      freezed:/a\        options: {}' "$directory/build.yaml"
  done
  run_stock "$stock_dir" "$results_dir/$name.stock.change.log"
  run_rust "$rust_dir" "$results_dir/$name.rust.change.log"
  assert_source_outputs "$stock_dir" "$rust_dir"
  assert_contains "$results_dir/$name.rust.change.log" 'using Dart fallback'
  printf 'freezed-correctness: dart-fallback: pass\n'
}

run_selected() {
  local name=$1
  shift
  if [[ "$case_filter" == all || "$case_filter" == "$name" ]]; then
    "$@"
  fi
}

run_selected generated-output-delete run_case_generated_output_delete
run_selected no-op run_case_noop
run_selected input-delete run_case_input_delete
run_selected rename run_case_rename
run_selected failure run_case_failure
run_selected affected-actions run_case_affected_actions
run_selected dependency run_case_dependency
run_selected annotation-removal run_case_annotation_removal
run_selected combined-output-removal run_case_combined_output_removal
run_selected builder-options run_case_builder_options
run_selected glob-membership run_case_glob_membership
run_selected fallback run_case_fallback

printf 'freezed-correctness: cases=%s pass\n' "$case_filter"
