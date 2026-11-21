#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
fixture_dir="$repo_root/fixtures/api_cutoff_app"
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
  printf 'api-cutoff: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
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
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

stock_dir=
rust_dir=

write_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp -R "$fixture_dir/lib/." "$directory/lib/"
  verification_run_pub_get "$directory" "pub-get/$(basename "$directory")" \
    "$dart_bin" "$pub_cache" "${pub_get_args[@]}" || fail "pub get failed for $directory"
}

prepare_pair() {
  stock_dir="$fixture_root/app-stock"
  rust_dir="$fixture_root/app-rust"
  write_package "$stock_dir"
  write_package "$rust_dir"
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
  shift 2
  VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" worker_run_frontend build \
    --root "$directory" --dart "$dart_bin" --jobs 2 "$@"
}

run_rust_cutoff() {
  local directory=$1
  local log=$2
  run_rust "$directory" "$log" \
    --api-cutoff api_cutoff_app:summary --api-cutoff api_cutoff_app:echo --api-cutoff api_cutoff_app:probe --api-cutoff api_cutoff_app:ast
}

# Applies one scripted edit to a copy of lib/api.dart: "body" changes
# only a method body's string literal (the API signature is
# unchanged); "api" adds a method to Widget (the signature changes).
edit_api() {
  local directory=$1
  local mode=$2
  python3 - "$directory/lib/api.dart" "$mode" <<'PYEOF' || fail "edit $mode failed for $directory"
import re
import sys

path, mode = sys.argv[1], sys.argv[2]
source = open(path).read()
if mode == "body":
    source, count = re.subn(
        r"'widget-v(\d+)'",
        lambda match: "'widget-v%d'" % (int(match.group(1)) + 1),
        source,
        count=1,
    )
    if count != 1:
        raise SystemExit("body edit anchor not found")
elif mode == "api":
    anchor = "  /// Extra rendering.\n  String extra() => 'extra';\n}"
    if source.count(anchor) != 1:
        raise SystemExit("api edit anchor not found")
    source = source.replace(
        anchor,
        "  /// Extra rendering.\n  String extra() => 'extra';\n\n"
        "  /// Whether the widget is ready.\n  bool ready() => true;\n}",
    )
else:
    raise SystemExit(f"unknown edit mode: {mode}")
open(path, "w").write(source)
PYEOF
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -f "$fixture_dir/build.yaml" ]] || fail "fixture not found: $fixture_dir"
worker_ensure_frontend || fail 'Rust frontend build failed'
mkdir -p "$fixture_root"
worker_attach "$workspace_root" || fail 'unable to attach repository package'

prepare_pair

run_stock "$stock_dir" "$temporary_dir/initial.stock.log" || fail 'stock initial build failed'
run_rust_cutoff "$rust_dir" "$temporary_dir/initial.rust.log" || fail 'Rust initial build failed'
assert_contains "$temporary_dir/initial.rust.log" 'Rust frontend: 5 build action(s)'
assert_same_file "$stock_dir/lib/consumer.summary.txt" "$rust_dir/lib/consumer.summary.txt"
assert_same_file "$stock_dir/lib/consumer.echo.txt" "$rust_dir/lib/consumer.echo.txt"
assert_same_file "$stock_dir/lib/consumer.probe.txt" "$rust_dir/lib/consumer.probe.txt"
assert_same_file "$stock_dir/lib/consumer.ast.txt" "$rust_dir/lib/consumer.ast.txt"
assert_same_file "$stock_dir/lib/consumer.combined.txt" "$rust_dir/lib/consumer.combined.txt"

run_rust_cutoff "$rust_dir" "$temporary_dir/noop.rust.log" || fail 'Rust no-op build failed'
assert_contains "$temporary_dir/noop.rust.log" 'No work to do (Rust frontend)'

# A body-only edit leaves the API signature unchanged. The summary
# action is waived by the cutoff and keeps its previous output, and
# so is the probe action, which resolves api.dart by asset id: the
# resolver's internal readability probe must not turn that library
# into a direct read. Two actions rerun: echo, whose read of
# api.dart is a direct content read through the builder step and
# stays content-keyed even though the same library is also
# resolver-observed, and ast, which is opted in but observes the
# dependency through its AST, so the safety net downgrades it to a
# content key. The combine action holds: the waived summary leaves
# its previous output in place, so the generated input is unchanged.
edit_api "$stock_dir" body
edit_api "$rust_dir" body
run_stock "$stock_dir" "$temporary_dir/body.stock.log" || fail 'stock body-edit build failed'
run_rust_cutoff "$rust_dir" "$temporary_dir/body.rust.log" || fail 'Rust body-edit build failed'
assert_contains "$temporary_dir/body.rust.log" 'Rust frontend: 2 build action(s)'
assert_contains "$rust_dir/lib/consumer.echo.txt" 'widget-v2'
assert_same_file "$stock_dir/lib/consumer.summary.txt" "$rust_dir/lib/consumer.summary.txt"
assert_same_file "$stock_dir/lib/consumer.echo.txt" "$rust_dir/lib/consumer.echo.txt"
assert_same_file "$stock_dir/lib/consumer.probe.txt" "$rust_dir/lib/consumer.probe.txt"
assert_same_file "$stock_dir/lib/consumer.ast.txt" "$rust_dir/lib/consumer.ast.txt"
assert_same_file "$stock_dir/lib/consumer.combined.txt" "$rust_dir/lib/consumer.combined.txt"

# An API edit changes the effective signature: both actions rerun
# and the summary stays byte-identical to stock.
edit_api "$stock_dir" api
edit_api "$rust_dir" api
run_stock "$stock_dir" "$temporary_dir/api.stock.log" || fail 'stock api-edit build failed'
run_rust_cutoff "$rust_dir" "$temporary_dir/api.rust.log" || fail 'Rust api-edit build failed'
assert_contains "$temporary_dir/api.rust.log" 'Rust frontend: 5 build action(s)'
assert_contains "$rust_dir/lib/consumer.summary.txt" 'ready'
assert_contains "$rust_dir/lib/consumer.echo.txt" 'ready'
assert_contains "$rust_dir/lib/consumer.probe.txt" 'ready'
assert_same_file "$stock_dir/lib/consumer.summary.txt" "$rust_dir/lib/consumer.summary.txt"
assert_same_file "$stock_dir/lib/consumer.echo.txt" "$rust_dir/lib/consumer.echo.txt"
assert_same_file "$stock_dir/lib/consumer.probe.txt" "$rust_dir/lib/consumer.probe.txt"
assert_same_file "$stock_dir/lib/consumer.ast.txt" "$rust_dir/lib/consumer.ast.txt"
assert_same_file "$stock_dir/lib/consumer.combined.txt" "$rust_dir/lib/consumer.combined.txt"

# Without the flag the same kind of body-only edit is content-keyed
# and reruns every action observing api.dart, so the skip above
# comes from the cutoff rather than from generally weaker
# invalidation. The combine action reruns as well: the native
# frontend propagates dirtiness from a rerun producer to its
# downstream actions even when the produced output is unchanged
# (stock build_runner skips it by digest in this case).
edit_api "$stock_dir" body
edit_api "$rust_dir" body
run_stock "$stock_dir" "$temporary_dir/unflagged.stock.log" || fail 'stock unflagged build failed'
run_rust "$rust_dir" "$temporary_dir/unflagged.rust.log" || fail 'Rust unflagged build failed'
assert_contains "$temporary_dir/unflagged.rust.log" 'Rust frontend: 5 build action(s)'
assert_contains "$rust_dir/lib/consumer.echo.txt" 'widget-v3'
assert_same_file "$stock_dir/lib/consumer.summary.txt" "$rust_dir/lib/consumer.summary.txt"
assert_same_file "$stock_dir/lib/consumer.echo.txt" "$rust_dir/lib/consumer.echo.txt"
assert_same_file "$stock_dir/lib/consumer.probe.txt" "$rust_dir/lib/consumer.probe.txt"
assert_same_file "$stock_dir/lib/consumer.ast.txt" "$rust_dir/lib/consumer.ast.txt"
assert_same_file "$stock_dir/lib/consumer.combined.txt" "$rust_dir/lib/consumer.combined.txt"

printf 'api-cutoff: PASS body-only-skip=yes probe-skip=yes direct-read-rerun=yes ast-downgrade-rerun=yes chain-hold=yes api-rerun=yes unflagged-rerun=yes stock-identical=yes\n'
