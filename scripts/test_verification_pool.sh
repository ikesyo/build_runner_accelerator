#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/verification_support.sh"
source "$script_dir/verification_pool.sh"
tmp=${VERIFY_POOL_TEST_TMP:-$(mktemp -d)}
drain_pid=
signal_pid=
drain_tmp=
signal_tmp=
cleanup() {
  local pid
  for pid in "$drain_pid" "$signal_pid"; do
    [[ -n "$pid" ]] || continue
    # The drain scheduler may be stopped; resume it so its EXIT trap can
    # terminate and reap its own workers before we reap the scheduler.
    kill -CONT "$pid" 2>/dev/null || true
    verification_stop_process_group "$pid"
  done
  verification_pool_stop
  [[ -z "$drain_tmp" ]] || rm -rf -- "$drain_tmp"
  [[ -z "$signal_tmp" ]] || rm -rf -- "$signal_tmp"
  [[ -n ${VERIFY_POOL_TEST_TMP:-} ]] || rm -rf -- "$tmp"
}
trap cleanup EXIT

verification_pool_run_item() {
  local name=$1
  # Each item owns a separate process group, like a suite command.
  setsid bash -c '
    printf "%s start %s\n" "$1" "$(date +%s%N)" >>"$2/events"
    if [[ "$1" == fail ]]; then sleep 0.3; exit 7; fi
    if [[ "$1" == long ]]; then
      sleep 30 &
      echo "$!" >"$2/child"
      wait
    else
      sleep 0.5
    fi
    printf "%s end %s\n" "$1" "$(date +%s%N)" >>"$2/events"
  ' pool-test "$name" "$tmp" &
  wait "$!"
}

if [[ ${VERIFY_POOL_TEST_DRAIN:-0} == 1 ]]; then
  trap 'exit 143' TERM
  verification_pool_run_item() {
    printf '%s\n' "$BASHPID" >"$tmp/ready-$1"
    while [[ ! -e "$tmp/gate" ]]; do sleep 0.01; done
    [[ "$1" != fail ]]
  }
  verification_pool_run 2 success fail queued
  exit $?
fi
if [[ ${VERIFY_POOL_TEST_SIGNAL:-0} == 1 ]]; then
  trap 'exit 143' TERM
  verification_pool_run 2 long long2
  exit 1
fi
verification_pool_run 1 one two
verification_pool_run 2 a b c d
python3 - "$tmp/events" <<'PY'
import sys
active = maximum = 0
events = [line.split() for line in open(sys.argv[1])]
assert [event[:2] for event in events[:4]] == [['one', 'start'], ['one', 'end'], ['two', 'start'], ['two', 'end']]
for _, event, _ in sorted(events, key=lambda e: int(e[2])):
    active += 1 if event == 'start' else -1
    maximum = max(maximum, active)
assert active == 0 and maximum == 2, maximum
PY
status=0
verification_pool_run 2 long fail skipped || status=$?
[[ "$status" == 7 ]]
[[ -f "$tmp/child" ]]
! kill -0 "$(cat "$tmp/child")" 2>/dev/null || {
  # A killed descendant can briefly remain as a zombie awaiting its reaper.
  [[ $(ps -o stat= -p "$(cat "$tmp/child")") == Z* ]]
}
! grep -q '^skipped start ' "$tmp/events"
drain_tmp=$(mktemp -d)
setsid env VERIFY_POOL_TEST_TMP="$drain_tmp" VERIFY_POOL_TEST_DRAIN=1 bash "$0" &
drain_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -s "$drain_tmp/ready-success" && -s "$drain_tmp/ready-fail" ]] && break
  sleep 0.05
done
[[ -s "$drain_tmp/ready-success" && -s "$drain_tmp/ready-fail" ]]
kill -STOP "$drain_pid"
# Delivery of SIGSTOP is asynchronous; confirm it before releasing workers.
scheduler_stopped=0
for ((attempt = 0; attempt < 100; attempt++)); do
  if ! scheduler_state=$(ps -o stat= -p "$drain_pid"); then
    printf 'pool test: cannot inspect scheduler %s\n' "$drain_pid" >&2
    exit 1
  fi
  [[ -n "$scheduler_state" ]] || { printf 'pool test: missing scheduler state for %s\n' "$drain_pid" >&2; exit 1; }
  if [[ "$scheduler_state" == T* || "$scheduler_state" == t* ]]; then
    scheduler_stopped=1
    break
  fi
  sleep 0.05
done
((scheduler_stopped)) || { printf 'pool test: scheduler did not stop: %s\n' "$drain_pid" >&2; exit 1; }
touch "$drain_tmp/gate"
# A zombie has exited but cannot be reaped until its stopped parent resumes.
# Wait for both actual worker processes, not markers written before exit.
for ((attempt = 0; attempt < 100; attempt++)); do
  workers_exited=1
  for worker in "$drain_tmp/ready-success" "$drain_tmp/ready-fail"; do
    worker_pid=$(cat "$worker")
    if ! worker_state=$(ps -o stat= -p "$worker_pid"); then
      printf 'pool test: cannot inspect worker %s\n' "$worker_pid" >&2
      exit 1
    fi
    [[ -n "$worker_state" ]] || { printf 'pool test: missing worker state for %s\n' "$worker_pid" >&2; exit 1; }
    if [[ "$worker_state" != Z* ]]; then
      workers_exited=0
    fi
  done
  ((workers_exited)) && break
  sleep 0.05
done
((workers_exited))
kill -CONT "$drain_pid"
drain_status=0
wait "$drain_pid" || drain_status=$?
drain_pid=
[[ "$drain_status" == 1 ]]
[[ ! -e "$drain_tmp/ready-queued" ]]
rm -rf -- "$drain_tmp"
drain_tmp=
signal_tmp=$(mktemp -d)
setsid env VERIFY_POOL_TEST_TMP="$signal_tmp" VERIFY_POOL_TEST_SIGNAL=1 bash "$0" &
signal_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -s "$signal_tmp/child" ]] && break
  sleep 0.05
done
[[ -s "$signal_tmp/child" ]]
child_pid=$(cat "$signal_tmp/child")
kill -TERM "$signal_pid"
signal_status=0
wait "$signal_pid" || signal_status=$?
signal_pid=
[[ "$signal_status" == 143 ]]
! kill -0 "$child_pid" 2>/dev/null || [[ $(ps -o stat= -p "$child_pid") == Z* ]]
rm -rf -- "$signal_tmp"
signal_tmp=
# Many jobs that exit before the scheduler polls must all be reaped.
verification_pool_run_item() { :; }
mapfile -t fast_items < <(seq 1 100)
verification_pool_run 4 "${fast_items[@]}" 2>"$tmp/fast.log"
[[ $(grep -c '^verify: suite=' "$tmp/fast.log") == 100 ]]
printf 'verification pool tests passed\n'
