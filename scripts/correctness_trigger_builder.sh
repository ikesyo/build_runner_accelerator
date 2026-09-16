#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/trigger_builder_app"
temporary_dir=$(mktemp -d)
test_root="$temporary_dir/workspace"
test_fixtures_dir="$test_root/fixtures"
stock_dir=
rust_dir=
case_group=${TRIGGER_CASE_GROUP:-all}
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

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
  printf 'trigger-builder: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,260p' "$log" >&2
  done
  exit 1
}

case "$case_group" in
  all|core|lifecycle|recovery)
    ;;
  *)
    fail "unknown TRIGGER_CASE_GROUP: $case_group"
    ;;
esac

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
  local expected_sha actual_sha
  expected_sha=$(sha256sum "$expected" | awk '{print $1}')
  actual_sha=$(sha256sum "$actual" | awk '{print $1}')
  [[ "$expected_sha" == "$actual_sha" ]] || fail "SHA mismatch: $expected vs $actual"
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected file remains: $1"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || {
    printf '%s\n' "--- $file ---" >&2
    sed -n '1,260p' "$file" >&2
    fail "${file##*/} does not contain: $expected"
  }
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
  BUILD_RUNNER_ACCELERATOR_METRICS=1 worker_run_frontend \
    build --root "$directory" --dart "$dart_bin" \
    --mode rust --jobs 2 >"$log" 2>&1
}

prepare_package() {
  local directory=$1
  local variant=${2:-default}
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib"/* "$directory/lib/"
  if [[ "$variant" == no-demand ]]; then
    sed -i \
      '/^      trigger_builder_app:optional_consumer:$/a\        enabled: false' \
      "$directory/build.yaml"
  elif [[ "$variant" == failure ]]; then
    sed -i \
      -e '/^      trigger_builder_app:trigger_builder:$/a\        options:\n          failAfterWrite: true' \
      -e '/^      trigger_builder_app:optional_trigger_builder:$/a\        enabled: false' \
      -e '/^      trigger_builder_app:producer:$/a\        enabled: false' \
      -e '/^      trigger_builder_app:generated_consumer:$/a\        enabled: false' \
      -e '/^      trigger_builder_app:optional_consumer:$/a\        enabled: false' \
      "$directory/build.yaml"
  fi
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get \
      --enforce-lockfile "${pub_get_args[@]}" >/dev/null) || \
    fail "pub get failed for $directory"
}

setup_pair() {
  local name=$1
  local variant=${2:-default}
  stock_dir="$test_fixtures_dir/${name}-stock"
  rust_dir="$test_fixtures_dir/${name}-rust"
  prepare_package "$stock_dir" "$variant"
  prepare_package "$rust_dir" "$variant"
}

run_pair() {
  local name=$1
  run_stock "$stock_dir" "$temporary_dir/$name.stock.log"
  run_rust "$rust_dir" "$temporary_dir/$name.rust.log"
}

assert_pair_outputs() {
  local relative
  for relative in "$@"; do
    assert_same_file "$stock_dir/$relative" "$rust_dir/$relative"
  done
}

assert_native_not_triggered() {
  local input=$1
  local log=$2
  local line
  line=$(grep -F '"input":"trigger_builder_app|lib/'"$input"'"' "$log" | \
    grep -F '"status":"not_triggered"' | head -n 1 || true)
  [[ -n "$line" ]] || fail "native trigger skip was not recorded for $input"
  [[ "$line" == *'"resolver_get_calls":0'* ]] || \
    fail "native trigger skip acquired a resolver for $input"
}

worker_ensure_frontend || fail 'Rust frontend build failed'
[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"

mkdir -p "$test_fixtures_dir"
worker_attach "$test_root"

if [[ "$case_group" == all || "$case_group" == core ]]; then
  setup_pair initial
  run_pair initial
  assert_pair_outputs \
    lib/import_input.triggered.dart \
    lib/annotation_input.triggered.dart \
    lib/both_input.triggered.dart \
    lib/part_host.triggered.dart \
    lib/generated_input.trigger.dart \
    lib/generated_input.consumer.dart \
    lib/optional_input.optional.triggered.dart \
    lib/optional_input.consumer.txt
  assert_no_file "$stock_dir/lib/plain_input.triggered.dart"
  assert_no_file "$rust_dir/lib/plain_input.triggered.dart"
  assert_native_not_triggered plain_input.dart "$temporary_dir/initial.rust.log"
  assert_contains "$temporary_dir/initial.rust.log" '"status":"not_triggered"'
  printf 'trigger-builder: initial: import=yes annotation=yes both=yes part=yes generated-chain=yes optional=yes plain-skip=yes jobs=2\n'

for directory in "$stock_dir" "$rust_dir"; do
  rm -f -- "$directory/lib/part_host.part"
done
run_pair part-annotation-missing
assert_no_file "$stock_dir/lib/part_host.triggered.dart"
assert_no_file "$rust_dir/lib/part_host.triggered.dart"
assert_native_not_triggered part_host.dart "$temporary_dir/part-annotation-missing.rust.log"
printf 'trigger-builder: missing-part: skipped-while-missing=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  printf "part of 'part_host.dart';\n@Deprecated('part annotation trigger')\nclass PartInput {}\n" \
    >"$directory/lib/part_host.part"
done
run_pair part-annotation-appears
assert_no_file "$stock_dir/lib/part_host.triggered.dart"
assert_contains "$rust_dir/lib/part_host.triggered.dart" "triggered:part 'part_host.part';"
printf 'trigger-builder: missing-part-reappears: stock-skip=yes native-recovered=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  sed -i '/package:trigger_builder_app\/trigger_marker.dart/d' \
    "$directory/lib/import_input.dart"
done
run_pair import-disabled
assert_no_file "$stock_dir/lib/import_input.triggered.dart"
assert_no_file "$rust_dir/lib/import_input.triggered.dart"
assert_native_not_triggered import_input.dart "$temporary_dir/import-disabled.rust.log"
printf 'trigger-builder: incremental-trigger-disable: stale-output-removed=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  printf 'class AnnotationInput {}\n' >"$directory/lib/annotation_input.dart"
done
run_pair annotation-disabled
assert_no_file "$stock_dir/lib/annotation_input.triggered.dart"
assert_no_file "$rust_dir/lib/annotation_input.triggered.dart"
assert_native_not_triggered annotation_input.dart "$temporary_dir/annotation-disabled.rust.log"
printf 'trigger-builder: annotation-disable: stale-output-removed=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  printf "part of 'part_host.dart';\nclass PartInput {}\n" \
    >"$directory/lib/part_host.part"
done
run_pair part-annotation-disabled
assert_no_file "$stock_dir/lib/part_host.triggered.dart"
assert_no_file "$rust_dir/lib/part_host.triggered.dart"
assert_native_not_triggered part_host.dart "$temporary_dir/part-annotation-disabled.rust.log"
printf 'trigger-builder: part-annotation-disable: dependency-tracked=yes stale-output-removed=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  sed -i '/package:trigger_builder_app\/trigger_marker.dart/d' \
    "$directory/lib/optional_input.dart"
done
run_pair optional-trigger-disabled
assert_no_file "$stock_dir/lib/optional_input.optional.triggered.dart"
assert_no_file "$rust_dir/lib/optional_input.optional.triggered.dart"
assert_pair_outputs lib/optional_input.consumer.txt
assert_contains "$rust_dir/lib/optional_input.consumer.txt" 'optional-present:false'
printf 'trigger-builder: optional-and-trigger: independent-skip-state=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  printf '// seed-v2\nclass Seed {}\n' >"$directory/lib/seed.dart"
done
run_pair generated-input-change
assert_pair_outputs \
  lib/generated_input.trigger.dart lib/generated_input.consumer.dart
assert_contains "$rust_dir/lib/generated_input.trigger.dart" 'seed-v2'
printf 'trigger-builder: generated-input-change: downstream-retriggered=yes\n'

for directory in "$stock_dir" "$rust_dir"; do
  rm -f -- "$directory/lib/generated_input.trigger.dart"
done
run_pair generated-output-delete
assert_pair_outputs \
  lib/generated_input.trigger.dart lib/generated_input.consumer.dart
  printf 'trigger-builder: generated-output-delete: restored=yes\n'
fi

if [[ "$case_group" == all || "$case_group" == lifecycle ]]; then
  setup_pair no-demand no-demand
  run_pair no-demand
  assert_no_file "$stock_dir/lib/optional_input.optional.triggered.dart"
  assert_no_file "$rust_dir/lib/optional_input.optional.triggered.dart"
  assert_no_file "$stock_dir/lib/optional_input.consumer.txt"
  assert_no_file "$rust_dir/lib/optional_input.consumer.txt"
  printf 'trigger-builder: optional-undemanded: skipped=yes\n'

setup_pair delete
run_pair delete-initial
for directory in "$stock_dir" "$rust_dir"; do
  rm -f -- "$directory/lib/seed.dart"
done
run_pair delete
assert_no_file "$stock_dir/lib/generated_input.trigger.dart"
assert_no_file "$stock_dir/lib/generated_input.consumer.dart"
assert_no_file "$rust_dir/lib/generated_input.trigger.dart"
assert_no_file "$rust_dir/lib/generated_input.consumer.dart"
printf 'trigger-builder: deletion: generated-chain-removed=yes\n'

setup_pair rename
run_pair rename-initial
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/import_input.dart" "$directory/lib/renamed_input.dart"
  sed -i 's/lib\/import_input.dart/lib\/renamed_input.dart/g' \
    "$directory/build.yaml"
done
run_pair rename
assert_pair_outputs lib/renamed_input.triggered.dart
assert_no_file "$stock_dir/lib/import_input.triggered.dart"
assert_no_file "$rust_dir/lib/import_input.triggered.dart"
  printf 'trigger-builder: rename: new-output=yes stale-output-removed=yes\n'
fi

if [[ "$case_group" == all || "$case_group" == recovery ]]; then
  setup_pair trigger-config
  run_pair trigger-config-initial
  for directory in "$stock_dir" "$rust_dir"; do
    sed -i 's/annotation Deprecated$/annotation TriggerMarker/' \
      "$directory/build.yaml"
  done
  run_pair trigger-config-changed
  assert_no_file "$stock_dir/lib/annotation_input.triggered.dart"
  assert_no_file "$rust_dir/lib/annotation_input.triggered.dart"
  assert_native_not_triggered annotation_input.dart \
    "$temporary_dir/trigger-config-changed.rust.log"
  printf 'trigger-builder: trigger-config-digest: incremental-invalidated=yes\n'

setup_pair failure failure
if run_stock "$stock_dir" "$temporary_dir/failure.stock.log"; then
  fail 'stock trigger failure unexpectedly succeeded'
fi
if run_rust "$rust_dir" "$temporary_dir/failure.rust.log"; then
  fail 'Rust trigger failure unexpectedly succeeded'
fi
assert_contains "$temporary_dir/failure.stock.log" 'trigger builder failure'
assert_contains "$temporary_dir/failure.rust.log" 'trigger builder failure'
assert_contains "$stock_dir/lib/annotation_input.triggered.dart" 'triggered:@Deprecated'
assert_no_file "$rust_dir/lib/annotation_input.triggered.dart"
assert_no_file "$stock_dir/lib/optional_input.optional.triggered.dart"
assert_no_file "$rust_dir/lib/optional_input.optional.triggered.dart"
assert_no_file "$stock_dir/lib/optional_input.consumer.txt"
assert_no_file "$rust_dir/lib/optional_input.consumer.txt"
for directory in "$stock_dir" "$rust_dir"; do
  sed -i \
    -e '/^        options:$/,+1d' \
    -e '/^        enabled: false$/d' \
    "$directory/build.yaml"
done
run_pair failure-recovery
assert_pair_outputs \
  lib/optional_input.optional.triggered.dart lib/optional_input.consumer.txt
  printf 'trigger-builder: failure-recovery: atomic=yes\n'
fi

printf 'trigger-builder: PASS\n'
