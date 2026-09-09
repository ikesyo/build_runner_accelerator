#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/current_json_app"
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
stock_log="$temporary_dir/stock-watch.log"
rust_log="$temporary_dir/rust-watch.log"
stock_pid=
rust_pid=

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

stop_process_group() {
  local pid=$1
  [[ -n "$pid" ]] || return 0
  kill -- -"$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_process_group "$stock_pid"
  stop_process_group "$rust_pid"
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'current-json-watch: FAIL: %s\n' "$*" >&2
  for log in "$stock_log" "$rust_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,260p' "$log" >&2
    fi
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  fail 'BUILD_RUNNER_ACCELERATOR_BIN is required for the Rust watch smoke test'
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

prepare_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib"/*.dart "$directory/lib/"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null) || \
    fail "pub get failed for $directory"
}

mkdir -p "$fixture_root"
ln -s "$worker_dir" "$workspace_root/dart_worker"
prepare_package "$stock_dir"
prepare_package "$rust_dir"

(
  cd "$stock_dir"
  exec setsid env PUB_CACHE="$pub_cache" \
    "$dart_bin" --suppress-analytics run build_runner watch
) >"$stock_log" 2>&1 &
stock_pid=$!

setsid env BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  PUB_CACHE="$pub_cache" \
  "$script_dir/run_rust_frontend.sh" \
  watch --root "$rust_dir" --dart "$dart_bin" --interval-ms 200 --mode rust \
  >"$rust_log" 2>&1 &
rust_pid=$!

wait_for_path() {
  local path=$1
  local pid=$2
  for _ in $(seq 1 240); do
    [[ -f "$path" ]] && return 0
    kill -0 "$pid" 2>/dev/null || fail "watch exited before creating $path"
    sleep 0.25
  done
  fail "timed out waiting for $path"
}

wait_for_text() {
  local path=$1
  local expected=$2
  local pid=$3
  for _ in $(seq 1 240); do
    if [[ -f "$path" ]] && grep -Fq -- "$expected" "$path"; then
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || fail "watch exited before writing $expected"
    sleep 0.25
  done
  fail "timed out waiting for $expected in $path"
}

assert_same_outputs() {
  local phase=$1
  local -a stock_outputs=()
  local -a rust_outputs=()
  mapfile -t stock_outputs < <(find "$stock_dir/lib" -maxdepth 1 -type f \
    -name '*.g.dart' -printf '%f\n' | sort)
  mapfile -t rust_outputs < <(find "$rust_dir/lib" -maxdepth 1 -type f \
    -name '*.g.dart' -printf '%f\n' | sort)
  [[ "${#stock_outputs[@]}" -eq "${#rust_outputs[@]}" ]] || \
    fail "$phase: generated output counts differ"
  for output in "${stock_outputs[@]}"; do
    [[ -f "$rust_dir/lib/$output" ]] || fail "$phase: missing Rust output $output"
    cmp "$stock_dir/lib/$output" "$rust_dir/lib/$output" || \
      fail "$phase: generated output differs: $output"
  done
}

assert_no_file() {
  [[ ! -e "$1" ]] || fail "unexpected stale output: $1"
}

atomic_write() {
  local path=$1
  local temporary_path="${path}.tmp"
  printf '%s\n' "${2:-changed}" >"$temporary_path"
  mv -- "$temporary_path" "$path"
}

wait_for_path "$stock_dir/lib/model_01.g.dart" "$stock_pid"
wait_for_path "$rust_dir/lib/model_01.g.dart" "$rust_pid"
assert_same_outputs initial

sed -i 's/displayName/title/g' \
  "$stock_dir/lib/model_01.dart" "$rust_dir/lib/model_01.dart"
wait_for_text "$stock_dir/lib/model_01.g.dart" title "$stock_pid"
wait_for_text "$rust_dir/lib/model_01.g.dart" title "$rust_pid"
assert_same_outputs input-change

rm -f -- "$stock_dir/lib/model_02.g.dart" "$rust_dir/lib/model_02.g.dart"
wait_for_path "$stock_dir/lib/model_02.g.dart" "$stock_pid"
wait_for_path "$rust_dir/lib/model_02.g.dart" "$rust_pid"
assert_same_outputs output-delete

mv "$stock_dir/lib/model_03.dart" "$stock_dir/lib/model_03_renamed.dart"
mv "$rust_dir/lib/model_03.dart" "$rust_dir/lib/model_03_renamed.dart"
sed -i "s/model_03.g.dart/model_03_renamed.g.dart/" \
  "$stock_dir/lib/model_03_renamed.dart" "$rust_dir/lib/model_03_renamed.dart"
wait_for_path "$stock_dir/lib/model_03_renamed.g.dart" "$stock_pid"
wait_for_path "$rust_dir/lib/model_03_renamed.g.dart" "$rust_pid"
sleep 1
assert_same_outputs rename
assert_no_file "$stock_dir/lib/model_03.g.dart"
assert_no_file "$rust_dir/lib/model_03.g.dart"

rust_rebuilds=$(grep -Fc 'Change detected; rebuilding' "$rust_log" || true)
(( rust_rebuilds >= 3 )) || \
  fail "Rust watch emitted only $rust_rebuilds rebuild events"

printf 'current-json-watch: input-change=yes output-delete=yes rename=yes stock-match=yes\n'
