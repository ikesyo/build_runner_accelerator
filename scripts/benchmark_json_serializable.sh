#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
dart_bin=${DART_BIN:-"$repo_root/.toolchains/dart/dart-sdk/bin/dart"}
pub_cache=${PUB_CACHE:-"$repo_root/.pub-cache"}
cargo_bin=${CARGO_BIN:-"$repo_root/.toolchains/cargo/bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}
jobs=${JOBS:-1}
count=${COUNT:-10}
io_metrics=${IO_METRICS:-0}
strace_bin=${STRACE_BIN:-}
worker_dir="$repo_root/dart_worker"
fixture_dir="$repo_root/fixtures/json_serializable_${count}_app"
state_path="$fixture_dir/.dart_tool/fast_build_runner/graph-v3.bin"
results_dir=$(mktemp -d)
metrics_path="$results_dir/metrics.txt"
io_trace_path=
io_trace_available=0

if [[ -z "$strace_bin" ]]; then
  strace_bin=$(command -v strace || true)
fi
if [[ "$io_metrics" == 1 && -n "$strace_bin" ]]; then
  if "$strace_bin" -f -qq -e trace=read,open,openat,openat2,creat \
    -o "$results_dir/io-probe.trace" true \
    >"$results_dir/io-probe.stdout" 2>"$results_dir/io-probe.stderr"; then
    io_trace_available=1
  fi
fi

if [[ "$count" != 10 || ! -f "$fixture_dir/pubspec.yaml" ]]; then
  bash "$script_dir/generate_json_serializable_fixture.sh" "$count" "$fixture_dir"
fi

prepare_rust_binary() {
  if [[ -n "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
    [[ -x "$FAST_BUILD_RUNNER_BIN" ]] || {
      printf 'Rust frontend binary is not executable: %s\n' "$FAST_BUILD_RUNNER_BIN" >&2
      exit 1
    }
    return 0
  fi
  [[ -x "$cargo_bin" ]] || {
    printf 'Cargo executable not found: %s\n' "$cargo_bin" >&2
    exit 1
  }
  (cd "$repo_root" && \
    RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
      "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml")
  local binary="$repo_root/rust/target/debug/fast_build_runner"
  [[ -x "$binary" ]] || {
    printf 'Rust frontend binary was not built: %s\n' "$binary" >&2
    exit 1
  }
  export FAST_BUILD_RUNNER_BIN="$binary"
}

prepare_rust_binary

(cd "$worker_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get)
(cd "$fixture_dir" && \
  PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get)

input_file=
for source in "$fixture_dir"/lib/model_*.dart; do
  if [[ "$source" == *.g.dart ]]; then
    continue
  fi
  input_file="$source"
  break
done
if [[ -z "$input_file" ]]; then
  printf 'no model source files found in %s\n' "$fixture_dir" >&2
  exit 1
fi

restore_markers() {
  if [[ ! -d "$fixture_dir/lib" ]]; then
    return 0
  fi
  for source in "$fixture_dir"/lib/model_*.dart; do
    if [[ "$source" == *.g.dart ]]; then
      continue
    fi
    sed -i 's/benchmark marker: [01]/benchmark marker: 0/' "$source"
  done
}
trap restore_markers EXIT

run_stock() {
  (cd "$fixture_dir" && \
    PUB_CACHE="$pub_cache" run_traced "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs \
      --log-performance .dart_tool/fast_build_runner/stock-performance)
}

run_frontend() {
  PUB_CACHE="$pub_cache" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    run_traced "$script_dir/run_rust_frontend.sh" \
    build --root "$fixture_dir" --dart "$dart_bin" --jobs "$jobs"
}

run_traced() {
  if [[ "$io_trace_available" == 1 ]]; then
    "$strace_bin" -f -qq -e trace=read,open,openat,openat2,creat \
      -o "$io_trace_path" "$@"
  else
    "$@"
  fi
}

summarize_io() {
  local label=$1
  if [[ "$io_metrics" != 1 ]]; then
    return 0
  fi
  if [[ "$io_trace_available" != 1 || ! -s "$io_trace_path" ]]; then
    printf '%s read_bytes=unavailable open_count=unavailable\n' "$label" >>"$metrics_path"
    return 0
  fi
  local read_bytes
  local open_count
  read_bytes=$(awk '/read\([^)]*\)[[:space:]]*=[[:space:]]*[0-9]+$/ {sum += $NF} END {print sum + 0}' "$io_trace_path")
  open_count=$(awk '/(open|openat|openat2|creat)\([^)]*\)[[:space:]]*=[[:space:]]*[0-9]+$/ {count++} END {print count + 0}' "$io_trace_path")
  printf '%s read_bytes=%s open_count=%s\n' "$label" "$read_bytes" "$open_count" >>"$metrics_path"
}

measure() {
  local label=$1
  shift
  local status=0
  if [[ "$io_metrics" == 1 ]]; then
    io_trace_path="$results_dir/$label.strace"
  else
    io_trace_path=
  fi
  if [[ -x /usr/bin/time ]]; then
    /usr/bin/time -f "$label real=%e user=%U sys=%S maxrss_kb=%M" \
      "$@" >"$results_dir/$label.stdout" 2>"$results_dir/$label.stderr" || status=$?
    cat "$results_dir/$label.stderr" >>"$metrics_path"
  else
    TIMEFORMAT="$label real=%3R user=%3U sys=%3S maxrss_kb=unavailable"
    { time "$@"; } >"$results_dir/$label.stdout" 2>>"$metrics_path" || status=$?
    printf '%s maxrss_kb=unavailable cache_kb=%s\n' \
      "$label" "$(cache_size_kb "$label")" >>"$metrics_path"
  fi
  if [[ -x /usr/bin/time ]]; then
    printf '%s cache_kb=%s\n' "$label" "$(cache_size_kb "$label")" >>"$metrics_path"
  fi
  summarize_io "$label"
  io_trace_path=
  if ((status != 0)); then
    if [[ -x /usr/bin/time ]]; then
      cat "$results_dir/$label.stderr" >&2
    fi
    return "$status"
  fi
}

cache_size_kb() {
  local label=$1
  local cache_path="$fixture_dir/.dart_tool/fast_build_runner/cache"
  if [[ "$label" == stock_* ]]; then
    cache_path="$fixture_dir/.dart_tool/build"
  fi
  if [[ -d "$cache_path" ]]; then
    du -sk "$cache_path" | awk '{print $1 + 0}'
  else
    printf '0\n'
  fi
}

copy_outputs() {
  local destination=$1
  mkdir -p "$destination"
  for source in "$fixture_dir"/lib/model_*.dart; do
    if [[ "$source" == *.g.dart ]]; then
      continue
    fi
    local stem=${source##*/}
    stem=${stem%.dart}
    cp "$fixture_dir/lib/$stem.g.dart" "$destination/$stem.g.dart"
  done
}

compare_outputs() {
  local expected=$1
  for baseline in "$expected"/model_*.g.dart; do
    local name=${baseline##*/}
    cmp "$baseline" "$fixture_dir/lib/$name"
  done
}

measure stock_clean run_stock
copy_outputs "$results_dir/stock_clean"
measure stock_noop run_stock

if [[ -f "$state_path" ]]; then
  mv "$state_path" "$results_dir/graph-before-clean.bin"
fi
measure rust_clean run_frontend
compare_outputs "$results_dir/stock_clean"
measure rust_noop run_frontend
grep -Fq 'No work to do (Rust frontend)' "$results_dir/rust_noop.stdout"

marker=$(rg -o 'benchmark marker: [01]' "$input_file" | awk '{print $3}')
next_marker=$((1 - marker))
sed -i "s/benchmark marker: $marker/benchmark marker: $next_marker/" \
  "$input_file"
measure stock_1_file run_stock
copy_outputs "$results_dir/stock_1_file"
measure rust_1_file run_frontend
compare_outputs "$results_dir/stock_1_file"

for source in "$fixture_dir"/lib/model_*.dart; do
  if [[ "$source" == *.g.dart ]]; then
    continue
  fi
  marker=$(rg -o 'benchmark marker: [01]' "$source" | awk '{print $3}')
  next_marker=$((1 - marker))
  sed -i "s/benchmark marker: [01]/benchmark marker: $next_marker/" "$source"
done
measure "stock_${count}_file" run_stock
copy_outputs "$results_dir/stock_${count}_file"
measure "rust_${count}_file" run_frontend
compare_outputs "$results_dir/stock_${count}_file"

restore_markers
run_frontend >"$results_dir/restore.stdout" 2>"$results_dir/restore.stderr" || {
  cat "$results_dir/restore.stderr" >&2
  exit 1
}

printf 'benchmark: jobs=%s byte-identical=yes no-op=yes\n' "$jobs"
cat "$metrics_path"
printf 'results=%s\n' "$results_dir"
