#!/usr/bin/env bash
set -uo pipefail

# ADR 0056 stage 6 benchmark: the API cutoff on a wide fan-out.
#
# Generates the fan-out fixture (one shared library, COUNT consumer
# libraries, the whole-graph summary builder on every consumer) and
# runs six lanes for two variants of the native frontend: without
# --api-cutoff (off) and with the summary builder opted in (on).
# Lanes: clean (fresh accelerator cache and no prior outputs, so
# manifest and worker compilation are included), no-op, body-only
# edit to the shared library, doc-only edit, API edit, and a broad
# multi-file edit touching every consumer at once. The two
# variants' output trees must stay byte-identical after every lane.
#
# Following docs/development.md, elapsed times come from a timed
# pass with metrics disabled, and action counts from a separate
# counted pass that replays the same edit sequence with
# BUILD_RUNNER_ACCELERATOR_METRICS=1. The timed pass runs the
# sequence twice with opposite per-lane variant orders, so no
# lane's comparison has a fixed run order (shared OS cache
# warming would otherwise favor the second variant); the table
# reports the range across the two repetitions. Both passes pin
# BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 (kernel workers only), so
# no deferred AOT compilation can leak into a neighboring lane
# and every lane runs on the same worker mode.
#
# Environment: COUNT (default 200), JOBS (default 2),
# PUB_GET_OFFLINE=1 to resolve the fixture dependencies offline.

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
set +e
set +o pipefail

# Later steps change directory into the fixture workspaces, so
# relative overrides (DART_BIN, PUB_CACHE) must be absolutized
# against the caller's directory first.
absolutize() {
  local path=$1
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    */*) printf '%s/%s\n' \
      "$(CDPATH= cd -- "$(dirname -- "$path")" && pwd)" \
      "$(basename -- "$path")" ;;
    *) printf '%s\n' "$path" ;;
  esac
}
dart_bin=$(absolutize "$(resolve_toolchain_dart)")
case "$dart_bin" in
  */*) ;;
  *)
    # A bare command name depends on PATH lookup, which can
    # change meaning after changing directories (and can differ
    # per directory when PATH has relative entries). Resolve it
    # to an absolute path from the caller's directory.
    resolved=$(command -v "$dart_bin" || true)
    if [[ -n "$resolved" ]]; then
      dart_bin=$(absolutize "$resolved")
    fi
    ;;
esac
pub_cache=$(resolve_toolchain_pub_cache)
case "$pub_cache" in
  /*) ;;
  # A cache path is never a command name: every relative value,
  # including a single component like .pub-cache, is relative to
  # the caller's directory.
  *) pub_cache="$PWD/$pub_cache" ;;
esac
count=${COUNT:-200}
jobs=${JOBS:-2}

work=$(mktemp -d) || {
  printf 'api-cutoff-bench: FAIL: mktemp failed for the workspace\n' >&2
  exit 1
}
results_dir=$(mktemp -d) || {
  printf 'api-cutoff-bench: FAIL: mktemp failed for the results\n' >&2
  exit 1
}
# Check for empty results before any normalization: an empty
# path absolutized against $PWD would name the caller's own
# directory, which the cleanup trap must never see.
if [[ -z "$work" || -z "$results_dir" ]]; then
  printf 'api-cutoff-bench: FAIL: could not create temporary directories\n' >&2
  exit 1
fi
# A relative TMPDIR makes mktemp return relative paths; later
# steps change directory, so absolutize both immediately.
case "$work" in
  /*) ;;
  *) work="$PWD/$work" ;;
esac
case "$results_dir" in
  /*) ;;
  *) results_dir="$PWD/$results_dir" ;;
esac
if [[ ! -d "$work" || ! -d "$results_dir" ]]; then
  printf 'api-cutoff-bench: FAIL: temporary directories are missing\n' >&2
  exit 1
fi
# Subprocesses change directory too, and some create their own
# temporary files: export an absolute TMPDIR for them as well.
if [[ -n "${TMPDIR:-}" ]]; then
  case "$TMPDIR" in
    /*) ;;
    *) TMPDIR="$PWD/$TMPDIR"; export TMPDIR ;;
  esac
fi
printf 'benchmark workspace: %s\n' "$work"
# The fixture workspaces and worker artifacts are bulky; remove
# them on exit. The results directory (logs and lane results) is
# kept and named in the final line.
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'api-cutoff-bench: FAIL: %s\n' "$*" >&2
  exit 1
}

worker_ensure_frontend || fail 'frontend build failed'

GENERATED_PART=0 bash "$script_dir/generate_api_cutoff_fanout_fixture.sh" "$count" \
  "$work/template" >/dev/null || fail 'fixture generation failed'

pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

# Resolve once in the template so both variants measure the same
# dependency set; each variant then materializes its package
# configuration from the shared lockfile.
(cd "$work/template" &&
  PUB_CACHE="$pub_cache" "$dart_bin" pub get "${pub_get_args[@]}" \
    >"$results_dir/pubget.template.log" 2>&1) ||
  fail 'pub get failed for the template'

prepare_variant() {
  local dir=$1
  # Plain cp -R: attribute preservation (cp -a / -p) fails on
  # filesystems with mapped uids, and the fixture needs only
  # file contents.
  cp -R "$work/template" "$dir" || fail "could not copy the template to $dir"
  (cd "$dir" &&
    PUB_CACHE="$pub_cache" "$dart_bin" pub get --enforce-lockfile \
      "${pub_get_args[@]}" \
      >"$results_dir/pubget.$(basename "$dir").log" 2>&1) ||
    fail "pub get failed for $dir"
}

# Lane timer: one Python process samples a monotonic clock on
# both sides of the frontend subprocess and prints the elapsed
# seconds. Sampling through two separate interpreter launches
# would put the second launch's startup inside the measurement,
# which matters for the subsecond lanes.
timer_py='
import subprocess, sys, time
log = open(sys.argv[1], "wb")
start = time.monotonic()
rc = subprocess.call(sys.argv[2:], stdout=log, stderr=subprocess.STDOUT)
sys.stdout.write("%.2f" % (time.monotonic() - start))
sys.exit(rc)
'

# run_lane <mode> <variant> <lane>: builds one variant once. The
# timed mode records elapsed seconds with metrics disabled; the
# counted mode records the summary action count from the metrics
# lines.
run_lane() {
  local mode=$1 variant=$2 lane=$3 rep=${4:-0}
  local app="$work/$mode-$variant"
  local cache="$work/$mode-$variant-cache"
  local log="$results_dir/$mode.$rep.$variant.$lane.log"
  local -a args=(build --root "$app" --dart "$dart_bin" --jobs "$jobs")
  if [[ "$variant" == "on" ]]; then
    args+=(--api-cutoff 'api_cutoff_fanout_app:summary')
  fi
  local elapsed rc
  # Both passes clear inherited worker artifact overrides, which
  # would bypass the pinned kernel-only setup. Timed runs also
  # clear diagnostics from the caller's environment
  # (docs/development.md: keep diagnostic runs separate from
  # timed runs).
  if [[ "$mode" == "counted" ]]; then
    elapsed=$(env -u BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH \
      -u BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL \
      -u BUILD_RUNNER_ACCELERATOR_PLAN_ONLY \
      BUILD_RUNNER_ACCELERATOR_CACHE="$cache" \
      BUILD_RUNNER_ACCELERATOR_METRICS=1 \
      BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 \
      BUILD_RUNNER_ACCELERATOR_DEP_CACHE=1 \
      PUB_CACHE="$pub_cache" \
      python3 -c "$timer_py" "$log" \
        bash "$script_dir/run_rust_frontend.sh" "${args[@]}")
  else
    elapsed=$(env -u BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH \
      -u BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL \
      -u BUILD_RUNNER_ACCELERATOR_PLAN_ONLY \
      -u BUILD_RUNNER_ACCELERATOR_METRICS \
      -u BUILD_RUNNER_ACCELERATOR_WALL_TRACE \
      -u BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE \
      -u BUILD_RUNNER_ACCELERATOR_OTEL_FILE \
      BUILD_RUNNER_ACCELERATOR_CACHE="$cache" \
      BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 \
      BUILD_RUNNER_ACCELERATOR_DEP_CACHE=1 \
      PUB_CACHE="$pub_cache" \
      python3 -c "$timer_py" "$log" \
        bash "$script_dir/run_rust_frontend.sh" "${args[@]}")
  fi
  rc=$?
  [[ "$elapsed" =~ ^[0-9]+\.[0-9]+$ ]] ||
    fail "could not record the timing for variant=$variant lane=$lane"
  ((rc == 0)) ||
    fail "build failed: mode=$mode variant=$variant lane=$lane (log: $log)"
  if [[ "$mode" == "timed" ]]; then
    printf '%s' "$elapsed" >"$results_dir/timed.$rep.$variant.$lane.result" ||
      fail "could not write the timing for variant=$variant lane=$lane"
  else
    local actions
    actions=$(grep -Fc \
      'Dart action metrics: {"builder":"api_cutoff_fanout_app:summary"' \
      "$log" || true)
    printf '%s' "$actions" >"$results_dir/counted.$variant.$lane.result"
  fi
}

outputs_identical() {
  local mode=$1
  diff -r --brief "$work/$mode-off/lib" "$work/$mode-on/lib" \
    >/dev/null 2>&1
}

wipe_for_clean() {
  local app=$1 cache=$2
  rm -rf "$app/.dart_tool/build_runner_accelerator" "$cache" ||
    fail "clean lane could not remove prior state under $app"
  find "$app/lib" -name '*.summary.txt' -delete ||
    fail "clean lane could not remove generated outputs under $app"
}

apply_body_edit() {
  local file=$1
  # Portable in-place edit: BSD sed requires a suffix after -i.
  sed "s/'shared-v1'/'shared-v2'/" "$file" >"$file.tmp" ||
    fail "body edit failed ($file)"
  mv "$file.tmp" "$file"
  grep -q "'shared-v2'" "$file" ||
    fail "body edit did not apply ($file)"
}

apply_doc_edit() {
  local file=$1
  # Edit the doc comment on greet: describeClass emits method
  # docs, so the summaries themselves change, and the fingerprint
  # covers doc comments, so both variants must rerun everything
  # and stay byte-identical.
  sed 's/Greets with the current revision/Greets with the updated revision/' \
      "$file" >"$file.tmp" ||
    fail "doc edit failed ($file)"
  mv "$file.tmp" "$file"
  grep -q 'Greets with the updated revision' "$file" ||
    fail "doc edit did not apply ($file)"
}

apply_api_edit() {
  local file=$1
  if ! python3 - "$file" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "  int compute(int input) => input * 2;\n"
new = old + "\n  String extra() => 'extra';\n"
assert text.count(old) == 1
open(path, 'w').write(text.replace(old, new))
PY
  then
    fail "api edit failed ($file)"
  fi
  grep -q "String extra()" "$file" ||
    fail "api edit did not apply ($file)"
}

apply_multi_edit() {
  local dir=$1 consumer
  # Broad incremental lane: touch every consumer's own input at
  # once. Every action reruns in both variants; the lane measures
  # the cost of handling many changed primary inputs together.
  for consumer in "$dir"/lib/consumer_*.dart; do
    printf '\n// Broad incremental touch.\n' >> "$consumer" ||
      fail "multi edit failed ($consumer)"
  done
}

# Parity between variants is not enough for the doc and API
# lanes: both variants could in principle regenerate stale
# summaries together. Assert the new content actually landed in
# every summary.
assert_summaries_contain() {
  local app=$1 pattern=$2 lane=$3 mode=$4 variant=$5 matched
  matched=$(grep -rl --include='*.summary.txt' -- "$pattern" \
    "$app/lib" | wc -l)
  [[ "$matched" -eq "$count" ]] ||
    fail "summaries containing '$pattern' after the $lane lane: $matched/$count (mode=$mode variant=$variant)"
}

# Parity alone would also pass if both variants lost the same
# outputs; every lane must still hold every summary.
assert_all_summaries() {
  local mode=$1 lane=$2 variant summaries
  for variant in off on; do
    summaries=$(find "$work/$mode-$variant/lib" \
      -name '*.summary.txt' | wc -l)
    [[ "$summaries" -eq "$count" ]] ||
      fail "lane $lane left $summaries summaries, want $count (mode=$mode variant=$variant)"
  done
}

run_sequence() {
  local mode=$1 rep=${2:-0} variant app cache summaries
  local -a order
  local lane_index=$rep
  # Counterbalance: alternate which variant runs first per lane,
  # starting from this repetition's parity, so the two timed
  # repetitions give every lane both run orders.
  next_order() {
    if (( lane_index % 2 == 0 )); then
      order=(off on)
    else
      order=(on off)
    fi
    lane_index=$((lane_index + 1))
  }
  next_order
  for variant in "${order[@]}"; do
    app="$work/$mode-$variant"
    cache="$work/$mode-$variant-cache"
    rm -rf "$app"
    prepare_variant "$app"
    # Clean lane: drop the graph, the generated outputs, and the
    # whole accelerator cache (worker binaries included).
    wipe_for_clean "$app" "$cache"
    run_lane "$mode" "$variant" clean "$rep"
    summaries=$(find "$app/lib" -name '*.summary.txt' | wc -l)
    [[ "$summaries" -eq "$count" ]] ||
      fail "clean lane produced $summaries summaries, want $count (mode=$mode variant=$variant)"
  done
  outputs_identical "$mode" ||
    fail "outputs differ after the clean lane (mode=$mode)"
  assert_all_summaries "$mode" clean

  next_order
  for variant in "${order[@]}"; do
    run_lane "$mode" "$variant" noop "$rep"
  done
  outputs_identical "$mode" ||
    fail "outputs differ after the noop lane (mode=$mode)"
  assert_all_summaries "$mode" noop

  next_order
  for variant in "${order[@]}"; do
    apply_body_edit "$work/$mode-$variant/lib/shared.dart"
    run_lane "$mode" "$variant" body "$rep"
  done
  outputs_identical "$mode" ||
    fail "outputs differ after the body lane (mode=$mode)"
  assert_all_summaries "$mode" body

  next_order
  for variant in "${order[@]}"; do
    apply_doc_edit "$work/$mode-$variant/lib/shared.dart"
    run_lane "$mode" "$variant" doc "$rep"
    assert_summaries_contain "$work/$mode-$variant" \
      'Greets with the updated revision' doc "$mode" "$variant"
  done
  outputs_identical "$mode" ||
    fail "outputs differ after the doc lane (mode=$mode)"
  assert_all_summaries "$mode" doc

  next_order
  for variant in "${order[@]}"; do
    apply_api_edit "$work/$mode-$variant/lib/shared.dart"
    run_lane "$mode" "$variant" api "$rep"
    assert_summaries_contain "$work/$mode-$variant" \
      'Shared.extra doc=' api "$mode" "$variant"
  done
  outputs_identical "$mode" ||
    fail "outputs differ after the api lane (mode=$mode)"
  assert_all_summaries "$mode" api

  next_order
  for variant in "${order[@]}"; do
    apply_multi_edit "$work/$mode-$variant"
    run_lane "$mode" "$variant" multi "$rep"
  done
  outputs_identical "$mode" ||
    fail "outputs differ after the multi lane (mode=$mode)"
  assert_all_summaries "$mode" multi
}

run_sequence timed 0
run_sequence timed 1
run_sequence counted 0

# The lanes only demonstrate the cutoff if the action counts match
# the design: everything runs except the no-op lane and the cutoff
# variant of the body lane.
expect_runs() {
  local variant=$1 lane=$2 want=$3 got
  got=$(cat "$results_dir/counted.$variant.$lane.result")
  [[ "$got" == "$want" ]] ||
    fail "action count: variant=$variant lane=$lane got=$got want=$want"
}
expect_runs off clean "$count"
expect_runs on clean "$count"
expect_runs off noop 0
expect_runs on noop 0
expect_runs off body "$count"
expect_runs on body 0
expect_runs off doc "$count"
expect_runs on doc "$count"
expect_runs off api "$count"
expect_runs on api "$count"
expect_runs off multi "$count"
expect_runs on multi "$count"

printf '\napi-cutoff bench: fixture=fanout count=%s jobs=%s dart=%s\n' \
  "$count" "$jobs" "$("$dart_bin" --version 2>&1 | awk '{print $4}')"
timing_range() {
  awk 'NR == 1 { lo = hi = $1 }
       { if ($1 < lo) lo = $1; if ($1 > hi) hi = $1 }
       END { if (lo == hi) printf "%s", lo;
             else printf "%s-%s", lo, hi }' \
    "$results_dir/timed.0.$1.$2.result" \
    "$results_dir/timed.1.$1.$2.result"
}

printf '%-6s %12s %12s %10s %10s\n' lane off_s on_s off_runs on_runs
for lane in clean noop body doc api multi; do
  for rep in 0 1; do
    for variant in off on; do
      value=$(cat "$results_dir/timed.$rep.$variant.$lane.result")
      [[ "$value" =~ ^[0-9]+\.[0-9]+$ ]] ||
        fail "missing timing result for lane $lane (rep $rep variant $variant)"
    done
  done
  printf '%-6s %12s %12s %10s %10s\n' "$lane" \
    "$(timing_range off "$lane")" \
    "$(timing_range on "$lane")" \
    "$(cat "$results_dir/counted.off.$lane.result")" \
    "$(cat "$results_dir/counted.on.$lane.result")"
done
printf 'api-cutoff-bench: PASS outputs-identical=yes logs=%s\n' "$results_dir"
