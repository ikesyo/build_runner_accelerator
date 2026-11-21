#!/usr/bin/env bash
set -euo pipefail

# ADR 0056 stage 5 differential harness: the same scripted edit
# sequence is applied stepwise to three isolated copies of
# fixtures/api_cutoff_app (stock build_runner, the native frontend
# with the API cutoff opted in, and the native frontend without the
# flag). After every step the generated output trees must match
# byte-for-byte across all three, and the cutoff copy must show the
# expected waive/rerun pattern per builder: fingerprint-covered
# edits (doc comments, const initializers, API changes in the
# library, its parts, and its import cycle) rerun the resolver-only
# actions, while edits outside the fingerprint (method bodies,
# plain comments, part bodies, cycle bodies) leave them waived.
# The AST builder is opted in but observes source through
# compilationUnitFor, so the safety net downgrades it and it reruns
# on any edit to the unit it reads. The combine builder consumes a
# generated asset: it holds while the summary action is waived and
# reruns whenever the summary action reruns, because the frontend
# propagates dirtiness from a rerun producer (stock build_runner
# skips that rerun by output digest; the outputs still match).

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
  printf 'api-cutoff-diff: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,240p' "$log" >&2
  done
  exit 1
}

stock_dir="$fixture_root/app-stock"
cutoff_dir="$fixture_root/app-cutoff"
plain_dir="$fixture_root/app-plain"

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

run_stock() {
  local directory=$1
  local log=$2
  verification_run_stock_build "$directory" "build/stock/$(basename "$directory")" "$log" \
    "$dart_bin" "$pub_cache" build --delete-conflicting-outputs
}

run_native() {
  local directory=$1
  local log=$2
  shift 2
  BUILD_RUNNER_ACCELERATOR_METRICS=1 VERIFY_COMMAND_LOG="$log" VERIFY_WORKSPACE="$directory" \
    worker_run_frontend build --root "$directory" --dart "$dart_bin" --jobs 2 "$@"
}

run_cutoff() {
  run_native "$cutoff_dir" "$1" \
    --api-cutoff api_cutoff_app:summary --api-cutoff api_cutoff_app:echo \
    --api-cutoff api_cutoff_app:probe --api-cutoff api_cutoff_app:ast
}

run_plain() {
  run_native "$plain_dir" "$1"
}

outputs=(
  lib/consumer.summary.txt
  lib/consumer.echo.txt
  lib/consumer.probe.txt
  lib/consumer.ast.txt
  lib/consumer.combined.txt
)

compare_outputs() {
  local step=$1
  local output
  for output in "${outputs[@]}"; do
    [[ -f "$stock_dir/$output" ]] || fail "step $step: missing stock output: $output"
    [[ -f "$cutoff_dir/$output" ]] || fail "step $step: missing cutoff output: $output"
    [[ -f "$plain_dir/$output" ]] || fail "step $step: missing plain output: $output"
    cmp "$stock_dir/$output" "$cutoff_dir/$output" ||
      fail "step $step: cutoff output differs from stock: $output"
    cmp "$stock_dir/$output" "$plain_dir/$output" ||
      fail "step $step: plain output differs from stock: $output"
  done
}

builder_runs() {
  local log=$1
  local builder=$2
  grep -Fc "Dart action metrics: {\"builder\":\"api_cutoff_app:$builder\"" "$log" || true
}

# assert_pattern <step> <summary> <probe> <echo> <ast> <combine>
# with 0 = waived, 1 = ran exactly once, - = do not assert.
assert_pattern() {
  local step=$1
  local log="$temporary_dir/$step.cutoff.log"
  local expected_summary=$2 expected_probe=$3 expected_echo=$4 expected_ast=$5 expected_combine=$6
  local pair
  for pair in "summary:$expected_summary" "probe:$expected_probe" "echo:$expected_echo" \
      "ast:$expected_ast" "combine:$expected_combine"; do
    local builder=${pair%%:*}
    local expected=${pair##*:}
    [[ "$expected" == "-" ]] && continue
    local actual
    actual=$(builder_runs "$log" "$builder")
    [[ "$actual" == "$expected" ]] ||
      fail "step $step: builder $builder ran $actual time(s), expected $expected"
  done
}

assert_no_work() {
  local step=$1
  local log="$temporary_dir/$step.cutoff.log"
  if grep -Fq 'No work to do (Rust frontend)' "$log" ||
     grep -Fq 'Rust frontend: 0 build action(s)' "$log"; then
    return 0
  fi
  fail "step $step: expected no cutoff work, log shows: $(grep -F 'build action' "$log" || true)"
}

assert_total() {
  local step=$1
  local expected=$2
  grep -Fq "Rust frontend: $expected build action(s)" "$temporary_dir/$step.cutoff.log" ||
    fail "step $step: expected $expected cutoff action(s)"
}

assert_cutoff_output_contains() {
  local step=$1
  local output=$2
  local expected=$3
  grep -Fq -- "$expected" "$cutoff_dir/$output" ||
    fail "step $step: $output does not contain: $expected"
}

# Applies one named edit inside a package copy. Anchors are unique
# in the fixture sources and account for earlier steps' edits.
apply_edit() {
  local directory=$1
  local mode=$2
  python3 - "$directory" "$mode" <<'PYEOF' || fail "edit $mode failed for $directory"
import sys

root, mode = sys.argv[1], sys.argv[2]

def edit(relpath, old, new):
    path = f"{root}/lib/{relpath}"
    source = open(path).read()
    if source.count(old) != 1:
        raise SystemExit(f"edit anchor not unique in {relpath}: {old!r}")
    open(path, "w").write(source.replace(old, new))

if mode == "body":
    edit("api.dart", "'widget-v1'", "'widget-v2'")
elif mode == "doc":
    edit("api.dart", "/// Renders the widget.", "/// Renders the widget nicely.")
elif mode == "comment":
    edit("api.dart",
         "// A plain comment: not documentation, so it is outside the API",
         "// A plain comment: still not documentation, outside the API")
elif mode == "const":
    edit("api.dart", "this.maxItems = 10", "this.maxItems = 20")
elif mode == "api":
    edit("api.dart",
         "  /// Extra rendering.\n  String extra() => 'extra';\n}",
         "  /// Extra rendering.\n  String extra() => 'extra';\n\n"
         "  /// Whether the widget is ready.\n  bool ready() => true;\n}")
elif mode == "part-body":
    edit("api_part.dart", "'part-v1'", "'part-v2'")
elif mode == "part-api":
    edit("api_part.dart",
         "  String renderPart() => 'part-v2';\n}",
         "  String renderPart() => 'part-v2';\n\n"
         "  /// Whether the part widget is ready.\n  bool partReady() => true;\n}")
elif mode == "cycle-body":
    edit("cycle_b.dart", "'cycle-b-v1'", "'cycle-b-v2'")
elif mode == "cycle-api":
    edit("cycle_b.dart",
         "  int valueB() => CycleA().valueA();\n}",
         "  int valueB() => CycleA().valueA();\n\n"
         "  /// An extra value from this side.\n  int extraB() => 2;\n}")
else:
    raise SystemExit(f"unknown edit mode: {mode}")
PYEOF
}

build_all() {
  local step=$1
  run_stock "$stock_dir" "$temporary_dir/$step.stock.log" || fail "step $step: stock build failed"
  run_cutoff "$temporary_dir/$step.cutoff.log" || fail "step $step: cutoff build failed"
  run_plain "$temporary_dir/$step.plain.log" || fail "step $step: plain build failed"
  compare_outputs "$step"
}

edit_all() {
  local mode=$1
  apply_edit "$stock_dir" "$mode"
  apply_edit "$cutoff_dir" "$mode"
  apply_edit "$plain_dir" "$mode"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -f "$fixture_dir/build.yaml" ]] || fail "fixture not found: $fixture_dir"
worker_ensure_frontend || fail 'Rust frontend build failed'
mkdir -p "$fixture_root"
worker_attach "$workspace_root" || fail 'unable to attach repository package'

write_package "$stock_dir"
write_package "$cutoff_dir"
write_package "$plain_dir"

build_all initial
assert_pattern initial 1 1 1 1 1
assert_total initial 5

build_all noop
assert_no_work noop

edit_all body
build_all body
assert_pattern body 0 0 1 1 0
assert_total body 2

edit_all doc
build_all doc
assert_pattern doc 1 1 1 1 1
assert_total doc 5

edit_all comment
build_all comment
assert_pattern comment 0 0 1 1 0
assert_total comment 2

edit_all const
build_all const
assert_pattern const 1 1 1 1 1
assert_total const 5

edit_all api
build_all api
assert_pattern api 1 1 1 1 1
assert_total api 5
assert_cutoff_output_contains api lib/consumer.summary.txt 'ready'

edit_all part-body
build_all part-body
assert_no_work part-body

edit_all part-api
build_all part-api
assert_pattern part-api 1 1 1 0 1
assert_total part-api 4
assert_cutoff_output_contains part-api lib/consumer.summary.txt 'partReady'

edit_all cycle-body
build_all cycle-body
assert_no_work cycle-body

edit_all cycle-api
build_all cycle-api
assert_pattern cycle-api 1 - - 0 1
assert_cutoff_output_contains cycle-api lib/consumer.summary.txt 'extraB'

printf 'api-cutoff-diff: PASS steps=11 stock-identical=yes plain-identical=yes\n'
