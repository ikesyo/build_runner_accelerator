#!/usr/bin/env bash
set -euo pipefail

# Correctness for the API cutoff (ADR 0056) on an app whose shared
# library has a generated part: the fan-out fixture generated with
# GENERATED_PART=1, where a partgen builder emits lib/shared.g.dart
# and every consumer's summary action observes the shared library
# through the resolver. The generated part sits in every candidate's
# observed closure, and generated assets carry no fingerprints, so
# every candidate is disqualified by the generated-asset rule: a
# body-only edit to the shared library reruns every action, exactly
# as with the cutoff off, and the outputs stay byte-identical. The
# cutoff metrics lines (BUILD_RUNNER_ACCELERATOR_METRICS=1) must
# attribute the outcome: candidates=3 at assess and
# generated_asset=3 at evaluate. This is the production shape from
# the stage 6 field report (generated parts in nearly every
# library), kept as a regression harness for follow-up work on
# generated assets.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
lockfile_source="$repo_root/pubspec.lock"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
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
  local cleanup_status=$?
  if ((cleanup_status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'verification: retaining failure workspace(s) and logs\n' >&2
    return 0
  fi
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'api-cutoff-generated-part: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
  done
  exit 1
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_metrics_line() {
  local file=$1
  local stage=$2
  local fragment=$3
  local line
  line=$(grep -F "Rust cutoff metrics: stage=$stage builder=api_cutoff_fanout_app:summary" "$file" | head -1) \
    || fail "${file##*/} has no stage=$stage cutoff metrics line"
  [[ "$line" == *"$fragment"* ]] \
    || fail "${file##*/} stage=$stage line lacks '$fragment': $line"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'
mkdir -p "$fixture_root"
worker_attach "$workspace_root" || fail 'unable to attach repository package'

GENERATED_PART=1 bash "$script_dir/generate_api_cutoff_fanout_fixture.sh" 3 \
  "$fixture_root/app-src" >"$temporary_dir/generate.log" 2>&1 \
  || fail 'fixture generation failed'

prepare_copy() {
  local directory=$1
  cp -R "$fixture_root/app-src" "$directory"
  cp "$lockfile_source" "$directory/pubspec.lock"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}" || fail "pub get failed for $directory"
}

stock_dir="$fixture_root/app-stock"
on_dir="$fixture_root/app-on"
off_dir="$fixture_root/app-off"
prepare_copy "$stock_dir"
prepare_copy "$on_dir"
prepare_copy "$off_dir"

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
}

run_rust() {
  local directory=$1
  local log=$2
  shift 2
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend build \
    --root "$directory" --dart "$dart_bin" --jobs 2 "$@"
}

run_on() {
  run_rust "$on_dir" "$1" --api-cutoff api_cutoff_fanout_app:summary
}

run_off() {
  run_rust "$off_dir" "$1"
}

edit_body() {
  local directory=$1
  python3 - "$directory/lib/shared.dart" <<'PYEOF' || fail "body edit failed for $directory"
import sys

path = sys.argv[1]
source = open(path).read()
if source.count("'shared-v1'") != 1:
    raise SystemExit("body edit anchor not found")
open(path, "w").write(source.replace("'shared-v1'", "'shared-v2'"))
PYEOF
}

compare_outputs() {
  local left=$1
  local right=$2
  local index
  for index in 001 002 003; do
    assert_same_file "$left/lib/consumer_$index.summary.txt" \
      "$right/lib/consumer_$index.summary.txt"
  done
  assert_same_file "$left/lib/shared.g.dart" "$right/lib/shared.g.dart"
}

# Initial builds: stock proves the byte-parity baseline for this
# shape; the cutoff-on build learns fingerprint evidence.
run_stock "$stock_dir" "$temporary_dir/initial.stock.log" || fail 'stock initial build failed'
run_on "$temporary_dir/initial.on.log" || fail 'cutoff-on initial build failed'
run_off "$temporary_dir/initial.off.log" || fail 'cutoff-off initial build failed'
assert_contains "$temporary_dir/initial.on.log" 'Rust frontend: 4 build action(s)'
compare_outputs "$stock_dir" "$on_dir"
compare_outputs "$stock_dir" "$off_dir"

# No-op builds learn nothing and run nothing.
run_on "$temporary_dir/noop.on.log" || fail 'cutoff-on no-op build failed'
assert_contains "$temporary_dir/noop.on.log" 'No work to do (Rust frontend)'

# A body-only edit to the shared library: every summary candidate's
# closure reaches the generated part, so the cutoff waives nothing
# and all four actions rerun, on and off alike.
edit_body "$stock_dir"
edit_body "$on_dir"
edit_body "$off_dir"
run_stock "$stock_dir" "$temporary_dir/body.stock.log" || fail 'stock body build failed'
BUILD_RUNNER_ACCELERATOR_METRICS=1 run_on "$temporary_dir/body.on.log" \
  || fail 'cutoff-on body build failed'
run_off "$temporary_dir/body.off.log" || fail 'cutoff-off body build failed'
assert_contains "$temporary_dir/body.on.log" 'Rust frontend: 4 build action(s)'
assert_contains "$temporary_dir/body.off.log" 'Rust frontend: 4 build action(s)'
assert_metrics_line "$temporary_dir/body.on.log" assess 'candidates=3'
assert_metrics_line "$temporary_dir/body.on.log" evaluate 'generated_asset=3'
assert_metrics_line "$temporary_dir/body.on.log" evaluate 'signature_unchanged=0'
compare_outputs "$on_dir" "$off_dir"
compare_outputs "$stock_dir" "$on_dir"

printf 'api-cutoff-generated-part: PASS\n'
