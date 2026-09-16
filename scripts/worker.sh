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

worker_package_dir=${BUILD_RUNNER_ACCELERATOR_WORKER_DIR:-"$repo_root/dart_worker"}
worker_package_name=build_runner_accelerator_worker
worker_link_name=dart_worker
worker_dart_bin=${DART_BIN:-$(resolve_toolchain_dart)}
worker_pub_cache=${PUB_CACHE:-$(resolve_toolchain_pub_cache)}
worker_rustup_home=${RUSTUP_HOME:-$(resolve_toolchain_rustup_home)}
worker_cargo_home=${CARGO_HOME:-$(resolve_toolchain_cargo_home)}

worker_fail() {
  printf 'worker: FAIL: %s\n' "$*" >&2
  return 1
}

worker_require_package() {
  if [[ ! -d "$worker_package_dir" ]]; then
    worker_fail "worker package directory not found: $worker_package_dir"
    return 1
  fi
  if [[ ! -f "$worker_package_dir/pubspec.yaml" ]]; then
    worker_fail "worker pubspec not found: $worker_package_dir/pubspec.yaml"
    return 1
  fi
  if [[ ! -f "$worker_package_dir/pubspec.lock" ]]; then
    worker_fail "worker lockfile not found: $worker_package_dir/pubspec.lock"
    return 1
  fi
  if [[ ! -f "$worker_dart_bin" || ! -x "$worker_dart_bin" ]]; then
    worker_fail "Dart executable not found: $worker_dart_bin"
    return 1
  fi
}

worker_pub_get() {
  local directory=${1:-$worker_package_dir}
  if (($# > 0)); then
    shift
  fi
  if [[ ! -d "$directory" ]]; then
    worker_fail "pub workspace not found: $directory"
    return 1
  fi
  local lock_dir="$worker_package_dir/.dart_tool"
  local lock_file="$lock_dir/worker-pub-get.lock"
  mkdir -p -- "$lock_dir" || {
    worker_fail "cannot create worker pub lock directory: $lock_dir"
    return 1
  }
  (
    exec 9>"$lock_file"
    flock 9 || exit 1
    cd -- "$directory"
    PUB_CACHE="$worker_pub_cache" \
      "$worker_dart_bin" --suppress-analytics pub get "$@"
  )
}

worker_prepare() {
  worker_require_package || return 1
  worker_pub_get "$worker_package_dir" "$@"
}

worker_attach() {
  local workspace_root=$1
  local link="$workspace_root/$worker_link_name"
  worker_require_package || return 1
  mkdir -p -- "$workspace_root"

  if [[ -L "$link" ]]; then
    local actual_target expected_target
    actual_target=$(cd -- "$link" && pwd -P) || {
      worker_fail "worker link is not a directory: $link"
      return 1
    }
    expected_target=$(cd -- "$worker_package_dir" && pwd -P) || {
      worker_fail "worker package directory is not accessible: $worker_package_dir"
      return 1
    }
    [[ "$actual_target" == "$expected_target" ]] || {
      worker_fail "worker link points to $actual_target, expected $expected_target"
      return 1
    }
  elif [[ -e "$link" ]]; then
    worker_fail "worker link destination already exists: $link"
    return 1
  else
    ln -s -- "$worker_package_dir" "$link"
  fi

  if [[ ! -f "$link/pubspec.yaml" ]]; then
    worker_fail "attached worker does not expose pubspec.yaml: $link"
    return 1
  fi
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
  local -a environment=(
    "PUB_CACHE=$worker_pub_cache"
    "RUSTUP_HOME=$worker_rustup_home"
    "CARGO_HOME=$worker_cargo_home"
    "BUILD_RUNNER_ACCELERATOR_BIN=$BUILD_RUNNER_ACCELERATOR_BIN"
  )
  local variable_name
  for variable_name in \
    DART_SDK \
    BUILD_RUNNER_ACCELERATOR_METRICS \
    BUILD_RUNNER_ACCELERATOR_WORKER_AOT \
    BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH \
    BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_LOCK \
    BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL; do
    if [[ -n "${!variable_name+x}" ]]; then
      environment+=("$variable_name=${!variable_name}")
    fi
  done
  env "${environment[@]}" "$worker_script_dir/run_rust_frontend.sh" "$@"
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
  if ! PATH="$(dirname -- "$cargo_bin"):$PATH" \
    RUSTUP_HOME="$worker_rustup_home" CARGO_HOME="$worker_cargo_home" \
    "$cargo_bin" "${cargo_args[@]}"; then
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
  if [[ $# -eq 0 ]]; then
    worker_fail 'worker process command is empty'
    return 1
  fi
  mkdir -p -- "$(dirname -- "$log_path")"
  setsid "$@" >"$log_path" 2>&1 &
  worker_last_pid=$!
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
  worker_start_process_group "$log_path" \
    bash -c 'cd -- "$1" && shift && exec "$@"' worker-process "$workdir" "$@"
}

worker_start_frontend_process_group() {
  local log_path=$1
  shift
  local -a environment=()
  while (($# > 0)) && [[ "$1" != -- ]]; do
    environment+=("$1")
    shift
  done
  if (($# == 0)) || [[ "$1" != -- ]]; then
    worker_fail 'frontend process requires -- before its command arguments'
    return 1
  fi
  shift
  if (($# == 0)); then
    worker_fail 'frontend process command is empty'
    return 1
  fi
  worker_start_process_group "$log_path" env "${environment[@]}" \
    bash -c 'set -euo pipefail; source "$1"; shift; worker_run_frontend "$@"' \
    worker-process "$worker_script_dir/worker.sh" "$@"
}

worker_stop_process_group() {
  local pid=${1:-}
  [[ -n "$pid" ]] || return 0
  kill -0 "$pid" 2>/dev/null && {
    kill -- -"$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  }
  wait "$pid" 2>/dev/null || true
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

prepare/pub-get: resolve the pinned Dart worker package and run pub get.
attach: attach the canonical dart_worker package to a temporary workspace.
validate: validate the worker package and Dart executable without mutation.
build-frontend: build the Rust frontend and export its binary path.
run-frontend: run the Rust frontend through the canonical worker launcher.
EOF
      ;;
    *)
      worker_fail "unknown command: $command_name"
      ;;
  esac
fi
