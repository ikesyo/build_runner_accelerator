#!/usr/bin/env bash
set -euo pipefail

verification_timeout_seconds() {
  local variable_name=$1
  local default_value=$2
  local value=${!variable_name:-$default_value}
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf 'verification: invalid %s=%q; expected a positive integer\n' "$variable_name" "$value" >&2
    return 2
  fi
  printf '%s\n' "$value"
}

verification_now() {
  date +%s
}

verification_command_text() {
  local argument
  local command_line=
  for argument in "$@"; do
    printf -v argument '%q' "$argument"
    command_line+="$argument "
  done
  printf '%s' "${command_line% }"
}

verification_process_group_ids() {
  local root_pid=$1
  local root_group
  root_group=$(ps -o pgid= -p "$root_pid" 2>/dev/null | tr -d ' ') || true
  [[ "$root_group" =~ ^[0-9]+$ ]] && printf '%s\n' "$root_group"
  local snapshot
  snapshot=$(ps -eo pid=,ppid=,pgid= 2>/dev/null || true)
  printf '%s\n' "$snapshot" | awk -v root="$root_pid" '
    {
      pid[NR] = $1
      parent[NR] = $2
      group[NR] = $3
    }
    END {
      for (i = 1; i <= NR; i++) {
        current = pid[i]
        for (j = 1; j <= NR; j++) {
          if (current == root) {
            if (group[i] ~ /^[0-9]+$/) print group[i]
            break
          }
          next_current = ""
          for (k = 1; k <= NR; k++) {
            if (pid[k] == current) {
              next_current = parent[k]
              break
            }
          }
          if (next_current == "" || next_current == current) break
          current = next_current
        }
      }
    }
  ' | sort -nu
}

verification_report_process_tree() {
  local pid=$1
  printf 'verification: process-tree pid=%s\n' "$pid"
  if command -v pstree >/dev/null 2>&1; then
    pstree -ap "$pid" 2>&1 || true
  else
    ps -e -o pid=,ppid=,pgid=,etimes=,state=,args= --forest 2>&1 || true
  fi
  printf 'verification: process-rows pid=%s\n' "$pid"
  ps -e -o pid=,ppid=,pgid=,etimes=,state=,args= 2>&1 | awk -v root="$pid" 'NR == 1 || $1 == root || $2 == root { print }' || true
}

verification_stop_process_group() {
  local root_pid=${1:-}
  [[ "$root_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  local own_group
  own_group=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ') || true
  local groups
  groups=$(verification_process_group_ids "$root_pid" || true)
  local known_groups="$groups"
  local group
  for group in $groups; do
    [[ "$group" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$group" == "$own_group" ]] && continue
    kill -TERM -- "-$group" 2>/dev/null || true
  done
  kill -TERM "$root_pid" 2>/dev/null || true
  local grace
  grace=$(verification_timeout_seconds VERIFY_TIMEOUT_GRACE_SECONDS 5) || grace=5
  local deadline=$(($(verification_now) + grace))
  while kill -0 "$root_pid" 2>/dev/null; do
    (( $(verification_now) >= deadline )) && break
    sleep 0.1
  done
  local remaining_groups
  remaining_groups=$(verification_process_group_ids "$root_pid" || true)
  groups=$(printf '%s\n%s\n' "$known_groups" "$remaining_groups" | sort -nu)
  for group in $groups; do
    [[ "$group" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$group" == "$own_group" ]] && continue
    kill -KILL -- "-$group" 2>/dev/null || true
  done
  kill -KILL "$root_pid" 2>/dev/null || true
  wait "$root_pid" 2>/dev/null || true
}

verification_report_failure_context() {
  local label=$1
  local pid=$2
  local log_path=$3
  local workspace=$4
  { printf 'verification: timeout label=%s pid=%s workspace=%s log=%s\n' "$label" "$pid" "$workspace" "$log_path"; verification_report_process_tree "$pid"; printf 'verification: log-tail label=%s\n' "$label"; tail -n 120 "$log_path" 2>/dev/null || true; } | tee -a "$log_path" >&2
}

verification_report_watch_timeout() {
  local label=$1
  local workspace=$2
  shift 2
  while (($# >= 2)); do
    local log_path=$1
    local pid=$2
    shift 2
    mkdir -p -- "$(dirname -- "$log_path")"
    {
      printf 'verification: watch-timeout label=%s pid=%s workspace=%s log=%s\n' \
        "$label" "$pid" "$workspace" "$log_path"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        verification_report_process_tree "$pid"
      fi
      printf 'verification: log-tail label=%s\n' "$label"
      tail -n 120 "$log_path" 2>/dev/null || true
    } | tee -a "$log_path" >&2 || true
  done
}
verification_run_command() {
  local label=$1
  local timeout_seconds=$2
  local log_path=$3
  shift 3
  (($# > 0)) || { printf 'verification: command is empty label=%s\n' "$label" >&2; return 2; }
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { printf 'verification: invalid timeout label=%s value=%q\n' "$label" "$timeout_seconds" >&2; return 2; }
  local workspace=${VERIFY_WORKSPACE:-$(pwd)}
  mkdir -p -- "$(dirname -- "$log_path")"
  if [[ "${VERIFY_COMMAND_LOG_APPEND:-0}" == 1 ]]; then
    : >>"$log_path"
  else
    : >"$log_path"
  fi
  local command_line
  command_line=$(verification_command_text "$@")
  local started
  started=$(verification_now)
  printf 'verification: command-start label=%s timeout=%ss workspace=%s log=%s command=%s\n' "$label" "$timeout_seconds" "$workspace" "$log_path" "$command_line" | tee -a "$log_path" >&2
  setsid "$@" >>"$log_path" 2>&1 &
  local pid=$!
  local tail_pid=
  if [[ "${VERIFY_STREAM_LOGS:-0}" == 1 ]]; then
    tail -n +1 -F "$log_path" >&2 &
    tail_pid=$!
  fi
  local status=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(verification_now) - started >= timeout_seconds )); then
      verification_report_failure_context "$label" "$pid" "$log_path" "$workspace"
      verification_stop_process_group "$pid"
      status=124
      break
    fi
    sleep 0.2
  done
  if ((status == 0)); then
    wait "$pid" || status=$?
  else
    wait "$pid" 2>/dev/null || true
  fi
  if [[ -n "$tail_pid" ]]; then
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
  fi
  local elapsed=$(($(verification_now) - started))
  printf 'verification: command-end label=%s status=%s elapsed=%ss workspace=%s log=%s\n' "$label" "$status" "$elapsed" "$workspace" "$log_path" | tee -a "$log_path" >&2
  if ((status != 0 && status != 124)); then
    printf 'verification: log-tail label=%s\n' "$label" | tee -a "$log_path" >&2
    tail -n 120 "$log_path" >&2 || true
  fi
  return "$status"
}

verification_run_command_in_dir() {
  local workdir=$1
  local label=$2
  local log_path=$3
  local timeout_seconds=$4
  shift 4
  [[ -d "$workdir" ]] || { printf 'verification: workspace not found label=%s workspace=%s\n' "$label" "$workdir" >&2; return 2; }
  VERIFY_WORKSPACE="$workdir" verification_run_command "$label" "$timeout_seconds" "$log_path" bash -c 'cd -- "$1" && shift && exec "$@"' verification-workdir "$workdir" "$@"
}

verification_run_pub_get() {
  local workdir=$1
  local label=$2
  local dart_bin=$3
  local pub_cache=$4
  shift 4
  local log_path=${VERIFY_PUB_GET_LOG:-$workdir/.dart_tool/build_runner_accelerator/verification/pub-get.log}
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_PUB_GET_TIMEOUT_SECONDS 180) || return 2
  verification_run_command_in_dir "$workdir" "$label" "$log_path" "$timeout_seconds" env PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "$@"
}

verification_run_stock_build() {
  local workdir=$1
  local label=$2
  local log_path=$3
  local dart_bin=$4
  local pub_cache=$5
  shift 5
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_BUILD_TIMEOUT_SECONDS 300) || return 2
  verification_run_command_in_dir "$workdir" "$label" "$log_path" "$timeout_seconds" env PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner "$@"
}

verification_run_case() {
  local label=$1
  shift
  (($# > 0)) || return 2
  local started
  started=$(verification_now)
  printf 'verification: case-start label=%s workspace=%s\n' "$label" "${VERIFY_WORKSPACE:-$(pwd)}" >&2
  local status=0
  if "$@"; then status=0; else status=$?; fi
  local elapsed=$(($(verification_now) - started))
  printf 'verification: case-end label=%s status=%s elapsed=%ss workspace=%s\n' "$label" "$status" "$elapsed" "${VERIFY_WORKSPACE:-$(pwd)}" >&2
  return "$status"
}

verification_watch_poll_iterations() {
  local interval_ms=${1:-200}
  [[ "$interval_ms" =~ ^[1-9][0-9]*$ ]] || {
    printf 'verification: invalid watch poll interval: %s\n' "$interval_ms" >&2
    return 2
  }
  local timeout_seconds
  timeout_seconds=$(verification_timeout_seconds VERIFY_WATCH_TIMEOUT_SECONDS 300) || return 2
  printf '%s\n' "$(((timeout_seconds * 1000) / interval_ms + 3))"
}
