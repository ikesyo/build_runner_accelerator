#!/usr/bin/env bash
# Bounded suite scheduler. The caller supplies verification_pool_run_item.

verification_pool_pids=()

verification_pool_stop() {
  local pid
  for pid in "${verification_pool_pids[@]}"; do
    verification_stop_process_group "$pid"
  done
  verification_pool_pids=()
}

verification_pool_run() {
  local jobs=$1
  shift
  local -a items=("$@")
  local -A names=() starts=()
  local next=0 completed pid status started total_start
  total_start=$(verification_now)
  if ((jobs == 1)); then
    local index item
    for ((index = 0; index < ${#items[@]}; index++)); do
      item=${items[index]}
      started=$(verification_now)
      status=0
      verification_pool_run_item "$item" "$index" || status=$?
      printf 'verify: suite=%s status=%s elapsed=%ss\n' "$item" "$status" "$(( $(verification_now) - started ))" >&2
      if ((status != 0)); then
        printf 'verify: FAIL: full verification suite failed: %s (status=%s)\n' "$item" "$status" >&2
        printf 'verify: full suites elapsed=%ss\n' "$(( $(verification_now) - total_start ))" >&2
        return "$status"
      fi
    done
    printf 'verify: full suites elapsed=%ss\n' "$(( $(verification_now) - total_start ))" >&2
    return 0
  fi
  while ((next < ${#items[@]} || ${#verification_pool_pids[@]} > 0)); do
    while ((next < ${#items[@]} && ${#verification_pool_pids[@]} < jobs)); do
      local item=${items[next]}
      started=$(verification_now)
      verification_pool_run_item "$item" "$next" &
      pid=$!
      verification_pool_pids+=("$pid")
      names[$pid]=$item
      starts[$pid]=$started
      ((next += 1))
    done
    # Bash can reap a fast background job before wait -n observes it. Wait
    # for a specific completed PID instead, which retains its exit status.
    completed=
    while [[ -z "$completed" ]]; do
      for pid in "${verification_pool_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
          completed=$pid
          break
        fi
      done
      [[ -n "$completed" ]] || sleep 0.1
    done
    status=0
    wait "$completed" || status=$?
    local -a remaining=()
    for pid in "${verification_pool_pids[@]}"; do
      [[ "$pid" == "$completed" ]] || remaining+=("$pid")
    done
    verification_pool_pids=("${remaining[@]}")
    printf 'verify: suite=%s status=%s elapsed=%ss\n' "${names[$completed]}" "$status" "$(( $(verification_now) - starts[$completed] ))" >&2
    if ((status != 0)); then
      printf 'verify: FAIL: full verification suite failed: %s (status=%s)\n' "${names[$completed]}" "$status" >&2
      verification_pool_stop
      printf 'verify: full suites elapsed=%ss\n' "$(( $(verification_now) - total_start ))" >&2
      return "$status"
    fi
  done
  printf 'verify: full suites elapsed=%ss\n' "$(( $(verification_now) - total_start ))" >&2
}
