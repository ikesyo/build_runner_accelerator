#!/usr/bin/env bash
set -euo pipefail

# Reproducible current build_runner baseline. The default lane measures stock;
# LANE=accelerator measures the Rust frontend with ACCELERATOR_JOBS. Set ACCELERATOR_LAUNCHER=1 to
# include the project-facing Dart launcher in the accelerator lane.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
workload=${WORKLOAD:-application}
case "$workload" in
  application) fixture_dir="$repo_root/fixtures/riverpod_app"; default_count=500 ;;
  json) fixture_dir="$repo_root/fixtures/current_json_app"; default_count=1000 ;;
  *) printf 'unsupported WORKLOAD: %s\n' "$workload" >&2; exit 1 ;;
esac
measure_script="$script_dir/measure_process.py"
dart_bin=$(resolve_toolchain_dart)
python_bin=${PYTHON_BIN:-python3}
pub_cache=$(resolve_toolchain_pub_cache)
build_runner_version=${BUILD_RUNNER_VERSION:-2.16.2}
json_serializable_version=${JSON_SERIALIZABLE_VERSION:-6.14.1}
json_annotation_version=${JSON_ANNOTATION_VERSION:-4.12.0}
pub_get_offline=${PUB_GET_OFFLINE:-1}
repeat_count=${REPEATS:-3}
model_count=${COUNT:-$default_count}
input_count=$model_count
expected_output_count=$model_count
if [[ "$workload" == application && "$model_count" =~ ^[1-9][0-9]*$ ]]; then
  input_count=$((2 * model_count + 1))
  expected_output_count=$input_count
fi
case_list=${CASES:-"clean no-op one-file broad"}
mode_list=${STOCK_MODES:-default}
trace_mode=${TRACE_MODE:-0}
lane=${LANE:-stock}
accelerator_jobs=${ACCELERATOR_JOBS:-default}
# Timed baselines must not inherit diagnostic instrumentation.
export BUILD_RUNNER_ACCELERATOR_METRICS=0
export BUILD_RUNNER_ACCELERATOR_WALL_TRACE=0
export BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=0
accelerator_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-}
accelerator_launcher=${ACCELERATOR_LAUNCHER:-1}

fail() {
  printf 'current-baseline: FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
command -v "$python_bin" >/dev/null || fail "Python executable not found: $python_bin"
[[ -f "$fixture_dir/pubspec.yaml" ]] || fail "fixture not found: $fixture_dir"
[[ -f "$measure_script" ]] || fail "measurement helper not found: $measure_script"

if [[ ! "$repeat_count" =~ ^[1-9][0-9]*$ ]]; then
  fail "REPEATS must be a positive integer: $repeat_count"
fi

if [[ ! "$model_count" =~ ^[1-9][0-9]*$ ]]; then
  fail "COUNT must be a positive integer: $model_count"
fi

results_dir=${RESULTS_DIR:-}
if [[ -z "$results_dir" ]]; then
  results_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-current-baseline.XXXXXX")
else
  mkdir -p "$results_dir"
  results_dir=$(cd -- "$results_dir" && pwd)
fi
[[ ! -e "$results_dir/results.jsonl" ]] || fail "results directory already contains measurements: $results_dir"
work_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-current-baseline-work.XXXXXX")
# Each case/repeat selects its own shared cache below so preceding warm
# cases cannot contaminate a later clean repeat.
results_jsonl="$results_dir/results.jsonl"
metadata_file="$results_dir/metadata.txt"

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
  local status=$?
  if ((status != 0)); then
    printf 'current-baseline: retained failed workspace: %s\n' "$work_root" >&2
    return 0
  fi
  remove_tree "$work_root"
}
trap cleanup EXIT

dart_version=$(
  "$dart_bin" --version 2>&1 | tr '\n' ' '
)

normalize_list() {
  tr ',' ' ' <<<"$1"
}

read -r -a cases <<<"$(normalize_list "$case_list")"
read -r -a modes <<<"$(normalize_list "$mode_list")"
[[ "${#cases[@]}" -gt 0 ]] || fail "CASES is empty"
[[ "${#modes[@]}" -gt 0 ]] || fail "STOCK_MODES is empty"
case "$lane" in
  stock|accelerator) ;;
  *) fail "unsupported LANE value: $lane (use stock or accelerator)" ;;
esac
if [[ "$lane" == accelerator && "$accelerator_jobs" != default && ! "$accelerator_jobs" =~ ^[1-9][0-9]*$ ]]; then
  fail "ACCELERATOR_JOBS must be default or a positive integer: $accelerator_jobs"
fi
if [[ "$accelerator_launcher" != 0 && "$accelerator_launcher" != 1 ]]; then
  fail "ACCELERATOR_LAUNCHER must be 0 or 1: $accelerator_launcher"
fi

for case_name in "${cases[@]}"; do
  case "$case_name" in
    clean|no-op|one-file|broad) ;;
    *) fail "unsupported case: $case_name (use clean, no-op, one-file, broad)" ;;
  esac
done
for mode in "${modes[@]}"; do
  case "$mode" in
    default|force-jit|force-aot|low-resources) ;;
    *) fail "unsupported STOCK_MODES value: $mode" ;;
  esac
  if [[ "$lane" == accelerator && "$mode" != default ]]; then
    fail "LANE=accelerator only supports STOCK_MODES=default"
  fi
done

if [[ "$lane" == accelerator && -z "$accelerator_bin" ]]; then
  worker_ensure_frontend || fail 'Rust frontend build failed'
  accelerator_bin="$BUILD_RUNNER_ACCELERATOR_BIN"
fi
if [[ "$lane" == accelerator ]]; then
  [[ -x "$accelerator_bin" ]] || fail "Rust frontend is not executable: $accelerator_bin"
  export BUILD_RUNNER_ACCELERATOR_BIN="$accelerator_bin"
fi

git -C "$repo_root" rev-parse HEAD >"$results_dir/source-commit.txt"
git -C "$repo_root" diff HEAD --binary >"$results_dir/harness.patch"
cp "$fixture_dir/pubspec.lock" "$results_dir/fixture.pubspec.lock"
printf 'dart_bin=%s\n' "$dart_bin" >"$metadata_file"
printf 'dart_version=%s\n' "$dart_version" >>"$metadata_file"
printf 'pub_cache=%s\n' "$pub_cache" >>"$metadata_file"
printf 'build_runner_version=%s\n' "$build_runner_version" >>"$metadata_file"
printf 'json_serializable_version=%s\n' "$json_serializable_version" >>"$metadata_file"
printf 'json_annotation_version=%s\n' "$json_annotation_version" >>"$metadata_file"
printf 'fixture=%s\n' "$fixture_dir" >>"$metadata_file"
printf 'cases=%s\n' "$case_list" >>"$metadata_file"
printf 'stock_modes=%s\n' "$mode_list" >>"$metadata_file"
printf 'workload=%s\ncount=%s\nexpected_output_count=%s\n' "$workload" "$model_count" "$expected_output_count" >>"$metadata_file"
printf 'input_count=%s\n' "$input_count" >>"$metadata_file"
printf 'warm_preparation=reuse-last-clean-or-one-warm-workspace;baseline-restored-before-each-edit\n' >>"$metadata_file"
printf 'repeats=%s\n' "$repeat_count" >>"$metadata_file"
printf 'pub_get_offline=%s\n' "$pub_get_offline" >>"$metadata_file"
printf 'trace_mode=%s\n' "$trace_mode" >>"$metadata_file"
printf 'lane=%s\n' "$lane" >>"$metadata_file"
printf 'accelerator_jobs=%s\n' "$accelerator_jobs" >>"$metadata_file"
printf 'accelerator_launcher=%s\n' "$accelerator_launcher" >>"$metadata_file"

snapshot_outputs() {
  "$python_bin" - "$1" "$2" <<'OUTPUTS'
import hashlib
import json
import re
import sys
from pathlib import Path
root, destination = Path(sys.argv[1]), Path(sys.argv[2])
lib = root / 'lib'
paths = sorted(p for p in lib.rglob('*.dart')
               if p.name.endswith(('.g.dart', '.freezed.dart')))
expected = set()
generated = set(paths)
for path in lib.rglob('*.dart'):
    if path in generated:
        continue
    for part in re.findall(r"^part '([^']+)';", path.read_text(), re.M):
        expected.add((path.parent / part).relative_to(lib).as_posix())
files = {p.relative_to(lib).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in paths}
if set(files) != expected:
    raise SystemExit(f'generated file set differs: missing={expected-set(files)}, extra={set(files)-expected}')
hash = hashlib.sha256()
for name, digest in files.items():
    hash.update(f'{digest}  ./{name}\n'.encode())
destination.write_text(json.dumps({'files': files, 'sha256': hash.hexdigest(),
                                  'bytes': sum(p.stat().st_size for p in paths)}, sort_keys=True) + '\n')
OUTPUTS
}

hash_fixture() {
  "$python_bin" - "$1" <<'HASH'
import hashlib
import sys
from pathlib import Path
root = Path(sys.argv[1])
hash = hashlib.sha256()
for path in sorted(root.glob('lib/**/*.dart')):
    if path.name.endswith(('.g.dart', '.freezed.dart')):
        continue
    hash.update(path.relative_to(root).as_posix().encode() + b'\0')
    hash.update(path.read_bytes())
hash.update((root / 'build.yaml').read_bytes())
print(hash.hexdigest())
HASH
}

prepare_package() {
  local package_dir=$1
  local package_name=$2
  mkdir -p "$package_dir"
  cp "$fixture_dir/build.yaml" "$package_dir/build.yaml"
  if [[ "$workload" == application ]]; then
    "$python_bin" "$script_dir/generate_application_fixture.py" \
      "$model_count" "$package_dir" >"$results_dir/generate.log"
  else
    bash "$script_dir/generate_json_serializable_fixture.sh" \
      "$model_count" "$package_dir" "$fixture_dir" >"$results_dir/generate.log"
  fi
  # Keep the fixture's tested transitive versions in every isolated package.
  # Resolving from scratch can select incompatible builder dependencies.
  cp "$fixture_dir/pubspec.lock" "$package_dir/pubspec.lock"
  sed \
    -e "s/^name: .*/name: $package_name/" \
    -e "s/^  build_runner: .*/  build_runner: $build_runner_version/" \
    -e "s/^  json_serializable: .*/  json_serializable: $json_serializable_version/" \
    -e "s/^  json_annotation: .*/  json_annotation: $json_annotation_version/" \
    "$fixture_dir/pubspec.yaml" >"$package_dir/pubspec.yaml"

  local pub_args=(--suppress-analytics pub get --enforce-lockfile)
  if [[ "$pub_get_offline" == 1 ]]; then
    pub_args+=(--offline)
  fi
  run_unmeasured "$package_dir" pub-get \
    env "PUB_CACHE=$pub_cache" "$dart_bin" "${pub_args[@]}"
}

build_command() {
  local mode=$1
  if [[ "$lane" == accelerator ]]; then
    if [[ "$accelerator_launcher" == 1 ]]; then
      BUILD_COMMAND=(
        env
        "PUB_CACHE=$pub_cache"
        "BUILD_RUNNER_ACCELERATOR_BIN=$accelerator_bin"
        "$dart_bin"
        --suppress-analytics
        run
        build_runner_accelerator
        build
      )
    else
      BUILD_COMMAND=(
        env
        "PUB_CACHE=$pub_cache"
        "BUILD_RUNNER_ACCELERATOR_BIN=$accelerator_bin"
        "$script_dir/worker.sh"
        run-frontend
        build
        --root
        .
        --dart
        "$dart_bin"
      )
    fi
    if [[ "$accelerator_jobs" != default ]]; then
      BUILD_COMMAND+=(--jobs "$accelerator_jobs")
    fi
    return 0
  fi
  BUILD_COMMAND=(
    env
    "PUB_CACHE=$pub_cache"
    "$dart_bin"
    --suppress-analytics
    run
    build_runner
    build
  )
  case "$mode" in
    default) ;;
    force-jit) BUILD_COMMAND+=(--force-jit) ;;
    force-aot) BUILD_COMMAND+=(--force-aot) ;;
    low-resources) BUILD_COMMAND+=(--low-resources-mode) ;;
  esac
}

run_unmeasured() {
  local package_dir=$1
  local label=$2
  shift 2
  local package_label=${package_dir#"$work_root"/}
  local log_prefix="$results_dir/${package_label//\//.}.$label"
  local status
  if (cd "$package_dir" && "$@") \
    >"$log_prefix.stdout" 2>"$log_prefix.stderr"; then
    return 0
  else
    status=$?
  fi
  cat "$log_prefix.stdout" >&2
  cat "$log_prefix.stderr" >&2
  printf 'current-baseline: %s failed for %s (exit %s); logs=%s.{stdout,stderr}\n' \
    "$label" "$package_label" "$status" "$log_prefix" >&2
  return "$status"
}

prewarm_aot_worker() {
  local package_dir=$1
  local label=$2
  local log_prefix="$results_dir/$label.aot-prewarm"
  local aot_path="$package_dir/.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker"

  if ! (
    cd "$package_dir"
    DART_BIN="$dart_bin" \
      PUB_CACHE="$pub_cache" \
      BUILD_RUNNER_ACCELERATOR_BIN="$accelerator_bin" \
      "$script_dir/aot_prewarm.sh" "$package_dir"
  ) >"$log_prefix.stdout" 2>"$log_prefix.stderr"; then
    cat "$log_prefix.stdout" >&2 || true
    cat "$log_prefix.stderr" >&2 || true
    fail "AOT worker prewarm failed for $label"
  fi

  if [[ ! -f "$aot_path" && -f "$aot_path.exe" ]]; then
    aot_path="$aot_path.exe"
  fi
  [[ -x "$aot_path" ]] || fail "AOT prewarm did not leave an executable: $aot_path"
  grep -Fq 'AOT prewarm complete' "$log_prefix.stdout" || \
    fail "AOT prewarm did not confirm completion for $label"

  aot_path=$(cd -- "$(dirname -- "$aot_path")" && pwd)/$(basename -- "$aot_path")
  printf 'current-baseline: AOT-prewarmed worker for %s: %s\n' "$label" "$aot_path" >&2
  printf '%s\n' "$aot_path"
}

set_marker() {
  "$python_bin" - "$1" "$2" "$workload" <<'MARKER'
import re
import sys
from pathlib import Path
root, marker, workload = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
if workload == 'application':
    shared = root / 'lib/shared.dart'
    text = shared.read_text()
    text = re.sub(r'enum Lifecycle \{[^}]+\}',
                  'enum Lifecycle { unknown, draft, active, archived' +
                  (', paused }' if marker == 'broad' else ' }'), text)
    if text != shared.read_text():
        shared.write_text(text)
    paths = sorted((root / 'lib/features').glob('*/model.dart'))
    if marker == 'one-file':
        paths = paths[:1]
    for path in paths:
        before = path.read_text()
        after = re.sub(r"@JsonKey\(name: 'title_[^']*'\)",
                       "@JsonKey(name: 'title_" + ('one-file' if marker == 'one-file' else 'base') + "')", before)
        if before != after:
            path.write_text(after)
    sys.exit(0)
paths = [p for p in sorted((root / 'lib').glob('model_*.dart'))
         if not p.name.endswith('.g.dart')]
if marker == 'one-file':
    paths = paths[:1]
for path in paths:
    before = path.read_text()
    after = re.sub(r'// baseline-marker: .*', '// baseline-marker: ' + marker, before)
    after = re.sub(r"@JsonKey\(name: 'value_[^']*'\)",
                   "@JsonKey(name: 'value_" + marker + "')", after)
    if before != after:
        path.write_text(after)
MARKER
}

measure_case() {
  local package_dir=$1
  local mode=$2
  local case_name=$3
  local repeat_index=$4
  local package_lock_sha=$5
  local fixture_sha=$6
  shift 6
  local -a case_command=("$@")
  local worker_aot_state=stock-default
  if [[ "$lane" == accelerator ]]; then
    if [[ "$case_name" == clean ]]; then
      worker_aot_state=launcher-default-cold
    else
      worker_aot_state=prewarmed-explicit-path
    fi
  fi
  local output_path="$results_dir/${mode}.${case_name}.r${repeat_index}"
  local metric_path="$output_path.json"
  local trace_path="$output_path.strace"
  local trace_args=()
  local parallelism=default
  if [[ "$lane" == accelerator ]]; then
    [[ "$accelerator_jobs" == default ]] || parallelism="jobs:$accelerator_jobs"
  fi
  if [[ "$trace_mode" == 1 ]]; then
    trace_args+=(--trace "$trace_path")
  fi

  local status=0
  "$python_bin" "$measure_script" \
    --metrics "$metric_path" \
    --stdout "$output_path.stdout" \
    --stderr "$output_path.stderr" \
    --cwd "$package_dir" \
    --label "$lane.$mode.$case_name.r$repeat_index" \
    --metadata lane="$lane" \
    --metadata case="$case_name" \
    --metadata mode="$mode" \
    --metadata repeat="$repeat_index" \
    --metadata dart_version="$dart_version" \
    --metadata build_runner_version="$build_runner_version" \
    --metadata json_serializable_version="$json_serializable_version" \
    --metadata json_annotation_version="$json_annotation_version" \
    --metadata build_runner_parallelism="$parallelism" \
    --metadata pubspec_lock_sha256="$package_lock_sha" \
    --metadata fixture_sha256="$fixture_sha" \
    --metadata input_count="$input_count" \
    --metadata workload="$workload" \
    --metadata feature_count="$model_count" \
    --metadata worker_aot_state="$worker_aot_state" \
    "${trace_args[@]}" \
    -- "${case_command[@]}" || status=$?
  if ((status != 0)); then
    cat "$output_path.stdout" >&2
    cat "$output_path.stderr" >&2
    printf 'current-baseline: measured build failed for %s/%s/r%s (exit %s); logs=%s.{stdout,stderr}\n' \
      "$mode" "$case_name" "$repeat_index" "$status" "$output_path" >&2
    return "$status"
  fi

  snapshot_outputs "$package_dir" "$output_path.outputs.json"
  "$python_bin" - "$metric_path" "$output_path.outputs.json" \
    "$results_dir/$mode.baseline.outputs.json" "$case_name" \
    "$expected_output_count" "$model_count" "$workload" <<'PYTHON'
import json
import sys
from pathlib import Path
metric_path, inventory_path, baseline_path = map(Path, sys.argv[1:4])
case, count, models, workload = sys.argv[4:]
record = json.loads(metric_path.read_text())
inventory = json.loads(inventory_path.read_text())
if len(inventory['files']) != int(count):
    raise SystemExit(f'expected {count} generated files, got {len(inventory["files"])}')
record.update(output_sha256=inventory['sha256'], output_count=len(inventory['files']),
              output_bytes=inventory['bytes'], output_manifest=inventory_path.name)
if case != 'clean':
    baseline = json.loads(baseline_path.read_text())
    if inventory['files'].keys() != baseline['files'].keys():
        raise SystemExit('incremental build changed the generated file set')
    changed = sum(digest != baseline['files'][name] for name, digest in inventory['files'].items())
    expected = 0 if case == 'no-op' else (1 if case == 'one-file' else int(models))
    if changed != expected:
        raise SystemExit(f'{case}: expected {expected} changed outputs, got {changed}')
    record['changed_output_count'] = changed
metric_path.write_text(json.dumps(record, sort_keys=True) + '\n')
PYTHON
  local output_sha
  output_sha=$("$python_bin" -c 'import json,sys; print(json.load(open(sys.argv[1]))["output_sha256"])' "$metric_path")
  if [[ "$worker_aot_state" == prewarmed-explicit-path ]] &&
    rg -q -e 'using Dart script' -e 'using kernel/script' -e 'Generated:.*\.aot' \
      "$output_path.stdout" "$output_path.stderr"; then
    fail "measured build did not use the prewarmed AOT worker for $case_name/r$repeat_index"
  fi
  if [[ -f "$results_dir/expected-output-sha256.$case_name" ]]; then
    [[ "$output_sha" == "$(cat "$results_dir/expected-output-sha256.$case_name")" ]] || fail "generated output set/content mismatch: $case_name/r$repeat_index"
  else
    printf '%s\n' "$output_sha" >"$results_dir/expected-output-sha256.$case_name"
  fi
  cat "$metric_path" >>"$results_jsonl"
}

for mode in "${modes[@]}"; do
  build_command "$mode"
  mode_root="$work_root/$mode"
  mkdir -p "$mode_root"
  worker_attach "$mode_root"
  cp -R "$repo_root/bin" "$mode_root/bin"
  # Cold samples must remain independent: no workspace or shared cache reuse.
  if [[ " ${cases[*]} " == *" clean "* ]]; then
    for ((repeat_index = 1; repeat_index <= repeat_count; repeat_index++)); do
      package_dir="$mode_root/r$repeat_index/clean"
      export BUILD_RUNNER_ACCELERATOR_CACHE="$package_dir.shared-cache"
      prepare_package "$package_dir" "benchmark_${workload}_${mode//-/_}"
      package_lock_sha=$(sha256sum "$package_dir/pubspec.lock" | awk '{print $1}')
      fixture_sha=$(hash_fixture "$package_dir")
      measure_case "$package_dir" "$mode" clean "$repeat_index" \
        "$package_lock_sha" "$fixture_sha" "${BUILD_COMMAND[@]}"
    done
  fi
  [[ "${cases[*]}" == clean ]] && continue

  # One compilation/prewarm and initial build for all warm samples. Reset input
  # and rebuild the baseline outside timing before each edited sample, so edits
  # do not accumulate and stock/native start with the same input and output set.
  if [[ " ${cases[*]} " != *" clean "* ]]; then
    package_dir="$mode_root/warm/app"
    export BUILD_RUNNER_ACCELERATOR_CACHE="$package_dir.shared-cache"
    prepare_package "$package_dir" "benchmark_${workload}_${mode//-/_}"
    package_lock_sha=$(sha256sum "$package_dir/pubspec.lock" | awk '{print $1}')
    fixture_sha=$(hash_fixture "$package_dir")
  fi
  case_build_command=("${BUILD_COMMAND[@]}")
  if [[ "$lane" == accelerator ]]; then
    prewarmed_aot_path=$(prewarm_aot_worker "$package_dir" "$mode.warm")
    case_build_command=(env "BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH=$prewarmed_aot_path" "${BUILD_COMMAND[@]:1}")
  fi
  run_unmeasured "$package_dir" warmup "${case_build_command[@]}"
  snapshot_outputs "$package_dir" "$results_dir/$mode.baseline.outputs.json"
  for case_name in "${cases[@]}"; do
    [[ "$case_name" == clean ]] && continue
    for ((repeat_index = 1; repeat_index <= repeat_count; repeat_index++)); do
      if [[ "$case_name" != no-op || "$repeat_index" == 1 ]]; then
        set_marker "$package_dir" base
        run_unmeasured "$package_dir" "reset-$case_name-r$repeat_index" "${case_build_command[@]}"
        snapshot_outputs "$package_dir" "$results_dir/$mode.reset.outputs.json"
        cmp "$results_dir/$mode.baseline.outputs.json" "$results_dir/$mode.reset.outputs.json" || fail 'baseline output restoration mismatch'
      fi
      if [[ "$case_name" != no-op ]]; then
        set_marker "$package_dir" "$case_name"
      fi
      measure_case "$package_dir" "$mode" "$case_name" "$repeat_index" \
        "$package_lock_sha" "$fixture_sha" "${case_build_command[@]}"
    done
  done
done

printf 'current-baseline: PASS\n'
printf 'current-baseline: results=%s\n' "$results_dir"
printf 'current-baseline: metadata=%s\n' "$metadata_file"
printf 'current-baseline: records=%s\n' "$results_jsonl"
cat "$results_jsonl"
