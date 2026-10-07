#!/usr/bin/env bash
set -euo pipefail

# Verify the public `prewarm` contract: foreground and --background runs,
# single-flight compile sharing with a concurrent build, idempotent second
# invocations, and the no-op fallback modes.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
fixture_dir="$repo_root/fixtures/current_json_app"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d)
# Keep the machine-wide accelerator cache hermetic: these scenarios assert
# on whether a workspace compiles or reuses its AOT worker.
export BUILD_RUNNER_ACCELERATOR_CACHE="$temporary_dir/shared-cache"
workspace_parent="$temporary_dir/workspaces"
workspace_a="$workspace_parent/a"
workspace_b="$workspace_parent/b"

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
trap cleanup EXIT INT TERM

fail() {
  printf 'prewarm: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log "$workspace_a/.dart_tool/build_runner_accelerator/prewarm.log" \
    "$workspace_b/.dart_tool/build_runner_accelerator/prewarm.log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,260p' "$log" >&2
    fi
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
worker_ensure_frontend || fail 'Rust frontend build failed'
fast_bin="$BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$workspace_parent"
worker_attach "$temporary_dir"

setup_workspace() {
  local root=$1
  mkdir -p "$root/lib"
  cp "$fixture_dir/pubspec.yaml" "$root/pubspec.yaml"
  cp "$fixture_dir/pubspec.lock" "$root/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$root/build.yaml"
  cp "$fixture_dir/lib"/*.dart "$root/lib/"
  (cd "$root" && PUB_CACHE="$pub_cache" "$dart_bin" \
    --suppress-analytics pub get --offline >/dev/null) || fail "pub get failed: $root"
}

run_runner() {
  local root=$1
  local log=$2
  shift 2
  VERIFY_COMMAND_LOG="$log" \
    BUILD_RUNNER_ACCELERATOR_WORKER_AOT=1 BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" \
    BUILD_RUNNER_ACCELERATOR_METRICS=1 \
    worker_run_frontend \
    "$@" --root "$root" --dart "$dart_bin" --mode rust
}

aot_artifact() {
  local generated_dir="$1/.dart_tool/build_runner_accelerator"
  local aot_path="$generated_dir/aot-sdk/bin/dynamic_worker"
  if [[ ! -f "$aot_path" && -f "$aot_path.exe" ]]; then
    aot_path="$aot_path.exe"
  fi
  [[ -x "$aot_path" ]] && [[ -f "$aot_path.d" ]] && [[ -f "$aot_path.sdk" ]]
}

wait_for_background() {
  local root=$1
  local generated_dir="$root/.dart_tool/build_runner_accelerator"
  local waited=0
  # The ready line precedes the lock guard's drop. Wait for both so that
  # clearing caches or removing the temporary workspace cannot race the child.
  until [[ -f "$generated_dir/prewarm.log" ]] &&
      grep -Fq 'AOT prewarm ready:' "$generated_dir/prewarm.log" &&
      [[ ! -f "$generated_dir/.aot-background.lock" ]]; do
    waited=$((waited + 1))
    (( waited < 240 )) || fail 'background prewarm did not finish in time'
    sleep 0.5
  done
}

setup_workspace "$workspace_a"
setup_workspace "$workspace_b"

# --- Foreground prewarm populates the caches a build consults -------------
run_runner "$workspace_a" "$temporary_dir/prewarm-a.log" prewarm ||
  fail 'foreground prewarm failed'
grep -Fq 'AOT prewarm ready:' "$temporary_dir/prewarm-a.log" ||
  fail 'foreground prewarm printed no artifact line'
aot_artifact "$workspace_a" || fail 'foreground prewarm published no AOT artifact'
[[ -f "$workspace_a/.dart_tool/build_runner_accelerator/builder-manifest.json" ]] ||
  fail 'prewarm produced no builder manifest'
[[ ! -f "$workspace_a/lib/model_01.g.dart" ]] ||
  fail 'prewarm ran build actions'

# A second foreground prewarm must reuse the published artifact, not
# recompile.
run_runner "$workspace_a" "$temporary_dir/prewarm-a2.log" prewarm ||
  fail 'warm prewarm rerun failed'
if grep -Fq 'Rust worker AOT compile: elapsed_us=' "$temporary_dir/prewarm-a2.log"; then
  fail 'warm prewarm rerun recompiled the worker'
fi
analysis_prewarm_ran=no
if grep -Fq 'analysis prewarm[aot-prewarm]' "$temporary_dir/prewarm-a2.log"; then
  analysis_prewarm_ran=yes
fi

# BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0 opts out of the byte-store sweep.
BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM=0 \
  run_runner "$workspace_a" "$temporary_dir/prewarm-a3.log" prewarm ||
  fail 'prewarm with analysis prewarm disabled failed'
if grep -Fq 'analysis prewarm[aot-prewarm]' "$temporary_dir/prewarm-a3.log"; then
  fail 'ANALYSIS_PREWARM=0 still spawned analysis shards'
fi

# --- --background detaches, idempotent, and logs to prewarm.log -----------
run_runner "$workspace_b" "$temporary_dir/bg1.log" prewarm --background ||
  fail 'background prewarm failed to start'
prewarm_log_file="$workspace_b/.dart_tool/build_runner_accelerator/prewarm.log"
lock_file="$workspace_b/.dart_tool/build_runner_accelerator/.aot-background.lock"
[[ -f "$lock_file" ]] || [[ -f "$prewarm_log_file" ]] ||
  fail 'background prewarm left no lock or log record'

# A second --background invocation while the first is running is a no-op.
run_runner "$workspace_b" "$temporary_dir/bg2.log" prewarm --background ||
  fail 'second background prewarm failed'
grep -Fq 'already running' "$temporary_dir/bg2.log" ||
  fail 'second background prewarm was not recognized as a no-op'

# Wait for the detached child to finish (bounded): the completion line is
# logged after the artifact is published, so poll on it (the artifact alone
# appears first and loses the race).
wait_for_background "$workspace_b"
aot_artifact "$workspace_b" ||
  fail 'background prewarm published no AOT artifact'

# --- Concurrent build shares the in-flight compile ------------------------
rm -rf -- "$workspace_b/.dart_tool/build_runner_accelerator/aot-sdk" \
  "$workspace_b/.dart_tool/build_runner_accelerator/.aot-background.lock"
# Keep manifest/worker sources but force a cold AOT compile: wipe the shared
# machine cache too so the build cannot restore from it.
remove_tree "$BUILD_RUNNER_ACCELERATOR_CACHE"
run_runner "$workspace_b" "$temporary_dir/bg3.log" prewarm --background ||
  fail 'background prewarm for concurrency test failed to start'
# The lock is taken before --background returns, so this build must either
# wait for the published artifact or reuse it — never a second compile.
run_runner "$workspace_b" "$temporary_dir/build-b.log" build ||
  fail 'build concurrent with background prewarm failed'
wait_for_background "$workspace_b"
[[ -f "$workspace_b/lib/model_01.g.dart" ]] || fail 'concurrent build produced no output'
# The detached child's output goes to prewarm.log, not the launcher log.
compiles=$(( $(grep -Fhc 'Rust worker AOT compile: elapsed_us=' "$prewarm_log_file" || true) +
             $(grep -Fhc 'Rust worker AOT compile: elapsed_us=' "$temporary_dir/build-b.log" || true) ))
[[ "$compiles" == "1" ]] ||
  fail "expected exactly one compile across prewarm+build logs, saw $compiles"
wait_marker=no
if grep -Fq 'waiting for the published artifact' "$temporary_dir/build-b.log"; then
  wait_marker=yes
fi

# Check every generated output against stock build_runner after warming.
(cd "$workspace_a" && PUB_CACHE="$pub_cache" "$dart_bin" \
  --suppress-analytics run build_runner build --delete-conflicting-outputs) \
  >"$temporary_dir/stock.log" 2>&1 || fail 'stock reference build failed'
for reference in "$workspace_a/lib"/*.g.dart; do
  cmp "$reference" "$workspace_b/lib/$(basename "$reference")" ||
    fail 'post-prewarm output differs from stock'
done

# --- Mode contract ----------------------------------------------------------
"$fast_bin" prewarm --root "$workspace_b" --dart "$dart_bin" --mode dart \
  >"$temporary_dir/dart-mode.log" 2>&1 ||
  fail 'prewarm --mode dart did not exit 0'
grep -Fq 'nothing to prewarm' "$temporary_dir/dart-mode.log" ||
  fail 'prewarm --mode dart printed no skip notice'

if "$fast_bin" build --root "$workspace_b" --dart "$dart_bin" --mode rust \
  --background >"$temporary_dir/bg-build.log" 2>&1; then
  fail '--background outside prewarm did not error'
fi
grep -Fq 'only supported with prewarm' "$temporary_dir/bg-build.log" ||
  fail '--background rejection missing from usage error'

# --- Dart launcher path -----------------------------------------------------
(cd "$repo_root" && env \
  "PUB_CACHE=$pub_cache" \
  "BUILD_RUNNER_ACCELERATOR_BIN=$fast_bin" \
  "BUILD_RUNNER_ACCELERATOR_CACHE=$BUILD_RUNNER_ACCELERATOR_CACHE" \
  "$dart_bin" run bin/build_runner_accelerator.dart prewarm \
  --root "$workspace_a" --mode auto) >"$temporary_dir/launcher.log" 2>&1 ||
  fail 'dart launcher prewarm failed'
grep -Fq 'AOT prewarm ready:' "$temporary_dir/launcher.log" ||
  fail 'dart launcher prewarm printed no artifact line'
if grep -Fq 'Rust worker AOT compile: elapsed_us=' "$temporary_dir/launcher.log"; then
  fail 'dart launcher prewarm recompiled a warm worker'
fi

# Dart-mode prewarm through the launcher is a successful no-op.
(cd "$repo_root" && env "PUB_CACHE=$pub_cache" \
  "$dart_bin" run bin/build_runner_accelerator.dart prewarm \
  --root "$workspace_a" --mode dart) >"$temporary_dir/launcher-dart.log" 2>&1 ||
  fail 'dart launcher prewarm --mode dart did not exit 0'
grep -Fq 'nothing to prewarm' "$temporary_dir/launcher-dart.log" ||
  fail 'dart launcher prewarm --mode dart printed no skip notice'

printf 'prewarm: foreground=yes background=yes idempotent=yes single-flight=yes waited=%s dart-noop=yes launcher=yes analysis-prewarm=%s analysis-opt-out=yes\n' \
  "$wait_marker" "$analysis_prewarm_ran"
