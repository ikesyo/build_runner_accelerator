#!/usr/bin/env bash
set -euo pipefail

# Reproducible current build_runner baseline. The default lane measures stock;
# LANE=accelerator measures the Rust frontend with ACCELERATOR_JOBS. Set ACCELERATOR_LAUNCHER=1 to
# include the project-facing Dart launcher in the accelerator lane.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
fixture_dir="$repo_root/fixtures/current_json_app"
measure_script="$script_dir/measure_process.py"
dart_bin=$(resolve_toolchain_dart)
python_bin=${PYTHON_BIN:-python3}
pub_cache=$(resolve_toolchain_pub_cache)
build_runner_version=${BUILD_RUNNER_VERSION:-2.16.1}
json_serializable_version=${JSON_SERIALIZABLE_VERSION:-6.14.1}
json_annotation_version=${JSON_ANNOTATION_VERSION:-4.12.0}
pub_get_offline=${PUB_GET_OFFLINE:-1}
repeat_count=${REPEATS:-1}
case_list=${CASES:-"clean no-op one-file broad"}
mode_list=${STOCK_MODES:-default}
trace_mode=${TRACE_MODE:-0}
lane=${LANE:-stock}
accelerator_jobs=${ACCELERATOR_JOBS:-1}
accelerator_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-}
accelerator_launcher=${ACCELERATOR_LAUNCHER:-0}
toolchain_bin=${RUST_TOOLCHAIN_BIN:-"$repo_root/.toolchains/rustup/toolchains/1.88.0-x86_64-unknown-linux-gnu/bin"}
cargo_bin=${CARGO_BIN:-"$toolchain_bin/cargo"}
rustc_bin=${RUSTC_BIN:-"$toolchain_bin/rustc"}
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)

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

results_dir=${RESULTS_DIR:-}
if [[ -z "$results_dir" ]]; then
  results_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-current-baseline.XXXXXX")
else
  mkdir -p "$results_dir"
  results_dir=$(cd -- "$results_dir" && pwd)
fi
work_root=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-current-baseline-work.XXXXXX")
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
if [[ "$lane" == accelerator && ! "$accelerator_jobs" =~ ^[1-9][0-9]*$ ]]; then
  fail "ACCELERATOR_JOBS must be a positive integer: $accelerator_jobs"
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
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  [[ -x "$rustc_bin" ]] || fail "rustc executable not found: $rustc_bin"
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" \
    CARGO_HOME="$cargo_home" RUSTC="$rustc_bin" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" || \
    fail 'Rust frontend build failed'
  accelerator_bin="$repo_root/rust/target/debug/build_runner_accelerator"
fi
if [[ "$lane" == accelerator ]]; then
  [[ -x "$accelerator_bin" ]] || fail "Rust frontend is not executable: $accelerator_bin"
fi

printf 'dart_bin=%s\n' "$dart_bin" >"$metadata_file"
printf 'dart_version=%s\n' "$dart_version" >>"$metadata_file"
printf 'pub_cache=%s\n' "$pub_cache" >>"$metadata_file"
printf 'build_runner_version=%s\n' "$build_runner_version" >>"$metadata_file"
printf 'json_serializable_version=%s\n' "$json_serializable_version" >>"$metadata_file"
printf 'json_annotation_version=%s\n' "$json_annotation_version" >>"$metadata_file"
printf 'fixture=%s\n' "$fixture_dir" >>"$metadata_file"
printf 'cases=%s\n' "$case_list" >>"$metadata_file"
printf 'stock_modes=%s\n' "$mode_list" >>"$metadata_file"
printf 'repeats=%s\n' "$repeat_count" >>"$metadata_file"
printf 'pub_get_offline=%s\n' "$pub_get_offline" >>"$metadata_file"
printf 'trace_mode=%s\n' "$trace_mode" >>"$metadata_file"
printf 'lane=%s\n' "$lane" >>"$metadata_file"
printf 'accelerator_jobs=%s\n' "$accelerator_jobs" >>"$metadata_file"
printf 'accelerator_launcher=%s\n' "$accelerator_launcher" >>"$metadata_file"

hash_outputs() {
  local package_dir=$1
  (
    cd "$package_dir/lib"
    find . -type f -name '*.g.dart' -print0 |
      sort -z |
      while IFS= read -r -d '' file; do
        sha256sum "$file"
      done
  ) | sha256sum | awk '{print $1}'
}

hash_fixture() {
  find "$fixture_dir" -type f \( -name '*.dart' -o -name '*.yaml' \) -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
      sha256sum "$file"
    done |
    sha256sum | awk '{print $1}'
}

prepare_package() {
  local package_dir=$1
  local package_name=$2
  mkdir -p "$package_dir"
  cp "$fixture_dir/build.yaml" "$package_dir/build.yaml"
  cp -R "$fixture_dir/lib" "$package_dir/lib"
  sed \
    -e "s/^name: .*/name: $package_name/" \
    -e "s/^  build_runner: .*/  build_runner: $build_runner_version/" \
    -e "s/^  json_serializable: .*/  json_serializable: $json_serializable_version/" \
    -e "s/^  json_annotation: .*/  json_annotation: $json_annotation_version/" \
    "$fixture_dir/pubspec.yaml" >"$package_dir/pubspec.yaml"

  local pub_args=(--suppress-analytics pub get)
  if [[ "$pub_get_offline" == 1 ]]; then
    pub_args+=(--offline)
  fi
  (cd "$package_dir" && PUB_CACHE="$pub_cache" "$dart_bin" "${pub_args[@]}") \
    >"$package_dir/pub-get.stdout" 2>"$package_dir/pub-get.stderr"
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
        "$repo_root/bin/build_runner_accelerator.dart"
        build
        --root
        .
        --dart
        "$dart_bin"
        --jobs
        "$accelerator_jobs"
        --mode
        rust
      )
    else
      BUILD_COMMAND=(
        env
        "PUB_CACHE=$pub_cache"
        "BUILD_RUNNER_ACCELERATOR_BIN=$accelerator_bin"
        "$script_dir/run_rust_frontend.sh"
        build
        --root
        .
        --dart
        "$dart_bin"
        --jobs
        "$accelerator_jobs"
        --mode
        rust
      )
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
    --verbose-durations
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
  (cd "$package_dir" && "$@") \
    >"$package_dir/$label.stdout" 2>"$package_dir/$label.stderr"
}

set_marker() {
  local package_dir=$1
  local marker=$2
  local file
  while IFS= read -r -d '' file; do
    sed -i -E "s#// baseline-marker: .*#// baseline-marker: $marker#" "$file"
  done < <(find "$package_dir/lib" -type f -name 'model_*.dart' -print0 | sort -z)
}

measure_case() {
  local package_dir=$1
  local mode=$2
  local case_name=$3
  local repeat_index=$4
  local package_lock_sha=$5
  local fixture_sha=$6
  local output_path="$results_dir/${mode}.${case_name}.r${repeat_index}"
  local metric_path="$output_path.json"
  local trace_path="$output_path.strace"
  local trace_args=()
  local parallelism=default
  if [[ "$lane" == accelerator ]]; then
    parallelism="jobs:$accelerator_jobs"
  fi
  if [[ "$trace_mode" == 1 ]]; then
    trace_args+=(--trace "$trace_path")
  fi

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
    --metadata input_count=10 \
    "${trace_args[@]}" \
    -- "${BUILD_COMMAND[@]}"

  local output_count
  local output_sha
  output_count=$(find "$package_dir/lib" -type f -name '*.g.dart' | wc -l | tr -d ' ')
  [[ "$output_count" == 10 ]] || fail "expected 10 generated outputs for $mode/$case_name, got $output_count"
  output_sha=$(hash_outputs "$package_dir")
  "$python_bin" - "$metric_path" "$output_sha" "$output_count" <<'PY'
import json
import sys

metric_path, output_sha, output_count = sys.argv[1:]
with open(metric_path, encoding="utf-8") as stream:
    record = json.load(stream)
record["output_sha256"] = output_sha
record["output_count"] = int(output_count)
with open(metric_path, "w", encoding="utf-8") as stream:
    json.dump(record, stream, ensure_ascii=False, sort_keys=True)
    stream.write("\n")
PY
  cat "$metric_path" >>"$results_jsonl"
}

fixture_sha=$(hash_fixture)
for mode in "${modes[@]}"; do
  build_command "$mode"
  mode_root="$work_root/$mode"
  mkdir -p "$mode_root"
  if [[ ! -e "$mode_root/dart_worker" && ! -L "$mode_root/dart_worker" ]]; then
    ln -s "$repo_root/dart_worker" "$mode_root/dart_worker"
  fi
  for ((repeat_index = 1; repeat_index <= repeat_count; repeat_index++)); do
    for case_name in "${cases[@]}"; do
      package_dir="$work_root/$mode/r$repeat_index/$case_name"
      prepare_package "$package_dir" "current_json_${mode//-/_}_${repeat_index}_${case_name//-/_}"
      package_lock_sha=$(sha256sum "$package_dir/pubspec.lock" | awk '{print $1}')

      case "$case_name" in
        clean)
          ;;
        no-op|one-file|broad)
          run_unmeasured "$package_dir" warmup "${BUILD_COMMAND[@]}"
          ;;
      esac
      case "$case_name" in
        one-file) set_marker "$package_dir" one-file ;;
        broad) set_marker "$package_dir" broad ;;
      esac

      measure_case "$package_dir" "$mode" "$case_name" "$repeat_index" \
        "$package_lock_sha" "$fixture_sha"
    done
  done
done

printf 'current-baseline: PASS\n'
printf 'current-baseline: results=%s\n' "$results_dir"
printf 'current-baseline: metadata=%s\n' "$metadata_file"
printf 'current-baseline: records=%s\n' "$results_jsonl"
cat "$results_jsonl"
