#!/usr/bin/env bash

# Shared Dart worker management for repository scripts and CI.
#
# This file is a shell library when sourced.  It is also a small command-line
# adapter for workflow steps that need to prepare the worker package without
# duplicating its path and pub commands.

worker_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -z "${repo_root:-}" ]]; then
  repo_root=$(cd -- "$worker_script_dir/.." && pwd)
  source "$worker_script_dir/toolchain.sh"
fi

: "${repo_root:?repo_root must be set before using worker.sh}"
source "$worker_script_dir/verification_support.sh"

root_package_dir="$repo_root"
worker_dart_bin=${DART_BIN:-$(resolve_toolchain_dart)}
worker_pub_cache=${PUB_CACHE:-$(resolve_toolchain_pub_cache)}
worker_rustup_home=${RUSTUP_HOME:-$(resolve_toolchain_rustup_home)}
worker_cargo_home=${CARGO_HOME:-$(resolve_toolchain_cargo_home)}
declare -Ag worker_process_log_paths=()
declare -Ag worker_process_workspaces=()
declare -Ag worker_process_started_at=()

worker_fail() {
  printf 'worker: FAIL: %s\n' "$*" >&2
  return 1
}

worker_require_package() {
  if [[ ! -d "$root_package_dir" ]]; then
    worker_fail "Dart package directory not found: $root_package_dir"
    return 1
  fi
  if [[ ! -f "$root_package_dir/pubspec.yaml" ]]; then
    worker_fail "Dart package pubspec not found: $root_package_dir/pubspec.yaml"
    return 1
  fi
  if [[ ! -f "$root_package_dir/pubspec.lock" ]]; then
    worker_fail "Dart package lockfile not found: $root_package_dir/pubspec.lock"
    return 1
  fi
  if [[ ! -f "$worker_dart_bin" || ! -x "$worker_dart_bin" ]]; then
    worker_fail "Dart executable not found: $worker_dart_bin"
    return 1
  fi
}

worker_pub_get() {
  local directory=${1:-$root_package_dir}
  if (($# > 0)); then shift; fi
  if [[ ! -d "$directory" ]]; then worker_fail "pub workspace not found: $directory"; return 1; fi
  local lock_dir="$root_package_dir/.dart_tool"
  local lock_file="$lock_dir/worker-pub-get.lock"
  mkdir -p -- "$lock_dir" || { worker_fail "cannot create worker pub lock directory: $lock_dir"; return 1; }
  (
    exec 9>"$lock_file"
    flock 9 || exit 1
    local log_path="${VERIFY_PUB_GET_LOG:-$directory/.dart_tool/build_runner_accelerator/verification/pub-get.log}"
    local timeout_seconds
    timeout_seconds=$(verification_timeout_seconds VERIFY_PUB_GET_TIMEOUT_SECONDS 180) || exit 2
    verification_run_command_in_dir "$directory" "pub-get/$(basename "$directory")" "$log_path" "$timeout_seconds" env PUB_CACHE="$worker_pub_cache" "$worker_dart_bin" --suppress-analytics pub get "$@"
  )
}

worker_prepare() {
  worker_require_package || return 1
  worker_pub_get "$root_package_dir" "$@"
}

worker_attach_root_package() {
  local workspace_root=$1
  local root_pubspec="$workspace_root/pubspec.yaml"
  local root_lib="$workspace_root/lib"
  local root_tool="$workspace_root/tool"

  # Fixture packages depend on the repository package via `path: ../..`.
  # Project the root package into temporary workspaces so that dependency
  # resolution and manifest generation see the same package sources.
  if [[ -e "$root_pubspec" ]]; then
    # Accept the usual YAML scalar spellings without bootstrapping a Dart
    # package parser before this workspace is ready for `dart pub get`.
    if awk '
      !seen && /^name:[[:space:]]*/ {
        seen = 1
        value = $0
        sub(/^name:[[:space:]]*/, "", value)
        sub(/[[:space:]]+#.*$/, "", value)
        sub(/[[:space:]]+$/, "", value)
        if (value == "build_runner_accelerator" ||
            value == "\"build_runner_accelerator\"" ||
            value == sprintf("%cbuild_runner_accelerator%c", 39, 39)) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    ' "$root_pubspec"; then
      return 0
    fi
    worker_fail "workspace root already contains a different package pubspec: $root_pubspec"
    return 1
  fi
  if [[ -e "$root_lib" || -L "$root_lib" || -e "$root_tool" || -L "$root_tool" ]]; then
    worker_fail "workspace already contains root package sources without pubspec.yaml: $workspace_root"
    return 1
  fi
  mkdir -p -- "$root_lib" "$root_tool" || {
    worker_fail "cannot create root package source directories: $workspace_root"
    return 1
  }
  cp -- "$repo_root/pubspec.yaml" "$root_pubspec" || {
    worker_fail "cannot attach root package pubspec: $root_pubspec"
    return 1
  }
  cp -R -- "$repo_root/lib/." "$root_lib/" || {
    worker_fail "cannot attach root package sources: $root_lib"
    return 1
  }
  cp -R -- "$repo_root/tool/." "$root_tool/" || {
    worker_fail "cannot attach root package tools: $root_tool"
    return 1
  }
}

worker_attach() {
  local workspace_root=$1
  worker_require_package || return 1
  mkdir -p -- "$workspace_root"

  worker_attach_root_package "$workspace_root" || return 1
}

worker_require_frontend() {
  if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
    worker_fail 'BUILD_RUNNER_ACCELERATOR_BIN is not set'
    return 1
  fi
  if [[ ! -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]]; then
    worker_fail "Rust frontend binary is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"
    return 1
  fi
}

worker_run_frontend() {
  worker_require_frontend || return 1
  local -a environment=("PUB_CACHE=$worker_pub_cache" "RUSTUP_HOME=$worker_rustup_home" "CARGO_HOME=$worker_cargo_home" "BUILD_RUNNER_ACCELERATOR_BIN=$BUILD_RUNNER_ACCELERATOR_BIN")
  local variable_name
  for variable_name in DART_SDK BUILD_RUNNER_ACCELERATOR_METRICS BUILD_RUNNER_ACCELERATOR_PLAN_ONLY BUILD_RUNNER_ACCELERATOR_WORKER_AOT BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_LOCK BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL; do
    if [[ -n "${!variable_name+x}" ]]; then environment+=("$variable_name=${!variable_name}"); fi
  done
  local log_path="${VERIFY_COMMAND_LOG:-${VERIFY_LOG_DIR:-$repo_root/.dart_tool/build_runner_accelerator/verification}/rust-frontend.log}"
  local timeout_variable=VERIFY_BUILD_TIMEOUT_SECONDS
  local timeout_default=300
  if [[ "${1:-}" == watch ]]; then
    timeout_variable=VERIFY_WATCH_PROCESS_TIMEOUT_SECONDS
    timeout_default=1800
  fi
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds "$timeout_variable" "$timeout_default") || return 2
  VERIFY_WORKSPACE="${VERIFY_WORKSPACE:-$repo_root}" verification_run_command "rust-frontend" "$timeout_seconds" "$log_path" env "${environment[@]}" "$worker_script_dir/run_rust_frontend.sh" "$@"
}

worker_build_frontend() {
  local profile=debug
  local target=
  local quiet=1
  while (($# > 0)); do
    case "$1" in
      --profile)
        if (($# < 2)); then
          worker_fail '--profile requires a value'
          return 1
        fi
        profile=$2
        shift 2
        ;;
      --release)
        profile=release
        shift
        ;;
      --target)
        if (($# < 2)); then
          worker_fail '--target requires a value'
          return 1
        fi
        target=$2
        shift 2
        ;;
      --no-quiet)
        quiet=0
        shift
        ;;
      *)
        worker_fail "unknown frontend build option: $1"
        return 1
        ;;
    esac
  done

  if [[ "$profile" != debug && "$profile" != release ]]; then
    worker_fail "unsupported frontend build profile: $profile"
    return 1
  fi
  local cargo_bin
  cargo_bin=$(resolve_toolchain_cargo)
  if [[ ! -x "$cargo_bin" ]]; then
    worker_fail "Cargo executable not found: $cargo_bin"
    return 1
  fi

  local -a cargo_args=(build --locked)
  [[ "$profile" == release ]] && cargo_args+=(--release)
  [[ "$quiet" == 1 ]] && cargo_args+=(--quiet)
  cargo_args+=(--manifest-path "$repo_root/rust/Cargo.toml")
  [[ -n "$target" ]] && cargo_args+=(--target "$target")
  local log_path="${VERIFY_FRONTEND_BUILD_LOG:-${VERIFY_LOG_DIR:-$repo_root/.dart_tool/build_runner_accelerator/verification}/frontend-build.log}"
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_FRONTEND_BUILD_TIMEOUT_SECONDS 900) || return 2
  if ! VERIFY_WORKSPACE="$repo_root" PATH="$(dirname -- "$cargo_bin"):$PATH" RUSTUP_HOME="$worker_rustup_home" CARGO_HOME="$worker_cargo_home" verification_run_command "frontend-build" "$timeout_seconds" "$log_path" "$cargo_bin" "${cargo_args[@]}"; then
    worker_fail 'Rust frontend build failed'
    return 1
  fi

  local binary_dir="$repo_root/rust/target"
  [[ -n "$target" ]] && binary_dir+="/$target"
  binary_dir+="/$profile"
  local binary="$binary_dir/build_runner_accelerator"
  if [[ ! -x "$binary" ]]; then
    worker_fail "Rust frontend binary is not executable: $binary"
    return 1
  fi
  export BUILD_RUNNER_ACCELERATOR_BIN="$binary"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    if ! printf 'BUILD_RUNNER_ACCELERATOR_BIN=%s\n' "$binary" >>"$GITHUB_ENV"; then
      worker_fail "cannot export frontend path to GITHUB_ENV: $GITHUB_ENV"
      return 1
    fi
  fi
}

worker_ensure_frontend() {
  if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
    worker_build_frontend "$@" || return 1
  fi
  worker_require_frontend || return 1
}

worker_start_process_group() {
  local log_path=$1
  shift
  if [[ $# -eq 0 ]]; then worker_fail 'worker process command is empty'; return 1; fi
  mkdir -p -- "$(dirname -- "$log_path")"
  local workspace="${WORKER_PROCESS_WORKSPACE:-${VERIFY_WORKSPACE:-$(pwd)}}"
  local started
  started=$(verification_now)
  printf 'worker: process-start workspace=%s log=%s command=%s\n' "$workspace" "$log_path" "$(verification_command_text "$@")" | tee -a "$log_path" >&2
  setsid "$@" >>"$log_path" 2>&1 &
  worker_last_pid=$!
  worker_process_log_paths["$worker_last_pid"]=$log_path
  worker_process_workspaces["$worker_last_pid"]=$workspace
  worker_process_started_at["$worker_last_pid"]=$started
  printf 'worker: process-pid pid=%s workspace=%s log=%s\n' "$worker_last_pid" "$workspace" "$log_path" | tee -a "$log_path" >&2
}

worker_start_process_group_in_dir() {
  local workdir=$1
  local log_path=$2
  shift 2
  if [[ ! -d "$workdir" ]]; then
    worker_fail "worker process directory not found: $workdir"
    return 1
  fi
  if [[ $# -eq 0 ]]; then
    worker_fail 'worker process command is empty'
    return 1
  fi
  WORKER_PROCESS_WORKSPACE="$workdir" worker_start_process_group "$log_path" bash -c 'cd -- "$1" && shift && exec "$@"' worker-process "$workdir" "$@"
}

worker_start_frontend_process_group() {
  local log_path=$1
  shift
  local -a environment=()
  while (($# > 0)) && [[ "$1" != -- ]]; do environment+=("$1"); shift; done
  if (($# == 0)) || [[ "$1" != -- ]]; then worker_fail 'frontend process requires -- before its command arguments'; return 1; fi
  shift
  if (($# == 0)); then worker_fail 'frontend process command is empty'; return 1; fi
  local workspace="${WORKER_PROCESS_WORKSPACE:-${VERIFY_WORKSPACE:-$(pwd)}}"
  local previous=
  local argument
  for argument in "$@"; do
    if [[ "$previous" == --root ]]; then workspace=$argument; break; fi
    previous=$argument
  done
  environment+=("VERIFY_COMMAND_LOG=$log_path" "VERIFY_WORKSPACE=$workspace" "VERIFY_STREAM_LOGS=0" "VERIFY_COMMAND_LOG_APPEND=1")
  WORKER_PROCESS_WORKSPACE="$workspace" worker_start_process_group "$log_path" env "${environment[@]}" bash -c 'set -euo pipefail; source "$1"; shift; worker_run_frontend "$@"' worker-process "$worker_script_dir/worker.sh" "$@"
}

worker_stop_process_group() {
  local pid=${1:-}
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  local log_path=${worker_process_log_paths["$pid"]:-}
  local workspace=${worker_process_workspaces["$pid"]:-${VERIFY_WORKSPACE:-$(pwd)}}
  local started=${worker_process_started_at["$pid"]:-}
  if [[ -n "$log_path" ]]; then
    printf 'worker: process-stop pid=%s workspace=%s log=%s\n' \
      "$pid" "$workspace" "$log_path" | tee -a "$log_path" >&2
  fi
  verification_stop_process_group "$pid"
  local elapsed=0
  if [[ "$started" =~ ^[0-9]+$ ]]; then
    elapsed=$(($(verification_now) - started))
  fi
  if [[ -n "$log_path" ]]; then
    printf 'worker: process-end pid=%s status=stopped elapsed=%ss workspace=%s log=%s\n' \
      "$pid" "$elapsed" "$workspace" "$log_path" | tee -a "$log_path" >&2
  fi
  unset 'worker_process_log_paths[$pid]'
  unset 'worker_process_workspaces[$pid]'
  unset 'worker_process_started_at[$pid]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  command_name=${1:-help}
  if (($# > 0)); then
    shift
  fi
  case "$command_name" in
    prepare|pub-get)
      worker_prepare "$@"
      ;;
    attach)
      if (($# != 1)); then
        worker_fail 'attach requires exactly one workspace root'
        exit 1
      fi
      worker_attach "$1"
      ;;
    validate)
      worker_require_package
      ;;
    build-frontend)
      worker_build_frontend "$@"
      ;;
    run-frontend)
      worker_run_frontend "$@"
      ;;
    help|-h|--help)
      cat >&2 <<'EOF'
usage: scripts/worker.sh <prepare|attach|validate|build-frontend|run-frontend> [args]

prepare/pub-get: resolve the root Dart package and run pub get.
attach: attach the canonical root package to a temporary workspace.
validate: validate the root Dart package and Dart executable without mutation.
build-frontend: build the Rust frontend and export its binary path.
run-frontend: run the Rust frontend through the canonical worker launcher.
EOF
      ;;
    *)
      worker_fail "unknown command: $command_name"
      ;;
  esac
fi
