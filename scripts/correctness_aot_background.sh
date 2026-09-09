#!/usr/bin/env bash
set -euo pipefail

# Verify that a local background AOT miss does not delay the first build, that
# the detached compile eventually publishes a reusable artifact, and that the
# next build selects AOT without invoking the Dart script worker.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
fixture_dir="$repo_root/fixtures/current_json_app"
dart_bin=$(resolve_toolchain_dart)
dart_sdk=$(resolve_toolchain_dart_sdk)
pub_cache=$(resolve_toolchain_pub_cache)
fast_bin=${BUILD_RUNNER_ACCELERATOR_BIN:-"$repo_root/rust/target/debug/build_runner_accelerator"}
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
rust_dir="$workspace_root/fixtures/rust"
first_log="$temporary_dir/first.log"
second_log="$temporary_dir/second.log"
failure_log="$temporary_dir/failure.log"
retry_log="$temporary_dir/retry.log"
compile_attempts="$temporary_dir/compile-attempts"
fail_compile="$temporary_dir/fail-compile"
compile_started="$temporary_dir/compile-started"
release_compile="$temporary_dir/release-compile"
script_started="$temporary_dir/script-started"
dart_wrapper="$temporary_dir/dart-wrapper"

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
  rm -f -- "$release_compile"
  remove_tree "$temporary_dir"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'aot-background: FAIL: %s\n' "$*" >&2
  for log in "$first_log" "$second_log" "$failure_log" "$retry_log"; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,260p' "$log" >&2
    fi
  done
  exit 1
}

wait_for_file() {
  local path=$1
  local attempts=$2
  for _ in $(seq 1 "$attempts"); do
    [[ -e "$path" ]] && return 0
    sleep 0.2
  done
  return 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -d "$dart_sdk/lib" ]] || fail "Dart SDK not found: $dart_sdk"
[[ -x "$fast_bin" ]] || fail "Rust frontend is not executable: $fast_bin"

mkdir -p "$rust_dir/lib"
cp "$fixture_dir/pubspec.yaml" "$rust_dir/pubspec.yaml"
cp "$fixture_dir/pubspec.lock" "$rust_dir/pubspec.lock"
cp "$fixture_dir/build.yaml" "$rust_dir/build.yaml"
cp "$fixture_dir/lib"/*.dart "$rust_dir/lib/"
ln -s "$repo_root/dart_worker" "$workspace_root/dart_worker"

(cd "$rust_dir" && PUB_CACHE="$pub_cache" "$dart_bin" \
  --suppress-analytics pub get --offline >/dev/null) || fail 'pub get failed'

cat >"$dart_wrapper" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == *"compile exe"* ]]; then
  touch "$compile_started"
  printf "compile\n" >>"$compile_attempts"
  [[ ! -e "$fail_compile" ]] || exit 23
  while [[ ! -e "$release_compile" ]]; do
    sleep 0.05
  done
fi
if [[ "\$*" == *"dynamic_worker.dart"* ]]; then
  touch "$script_started"
fi
exec "$dart_bin" "\$@"
EOF
chmod 755 "$dart_wrapper"

BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background DART_SDK="$dart_sdk" \
  BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/run_rust_frontend.sh" \
  build --root "$rust_dir" --dart "$dart_wrapper" --mode rust \
  >"$first_log" 2>&1 &
first_pid=$!

wait_for_file "$compile_started" 600 || fail 'background compile did not start'

# The compiler is deliberately held behind a gate. A synchronous miss would
# leave the foreground build before the script worker starts; seeing the script
# marker while the gate is closed proves that background mode did not wait.
wait_for_file "$script_started" 600 || \
  fail 'first build did not start the script worker while AOT was compiling'
touch "$release_compile"
wait "$first_pid" || fail 'first background build failed'
[[ -f "$rust_dir/lib/model_01.g.dart" ]] || \
  fail 'first build produced no generated output'
aot_root="$rust_dir/.dart_tool/build_runner_accelerator/aot-sdk"
aot_path="$aot_root/bin/dynamic_worker"
if [[ ! -f "$aot_path" && -f "$aot_path.exe" ]]; then
  aot_path="$aot_path.exe"
fi
wait_for_file "$aot_path" 1200 || fail 'background AOT compile did not publish an executable'
[[ -x "$aot_path" ]] || fail 'background AOT artifact is not executable'
[[ -f "$aot_path.d" ]] || fail 'background AOT compile did not publish a depfile'
[[ -f "$aot_path.sdk" ]] || fail 'background AOT compile did not publish SDK metadata'

# A failed helper must remove its lock and leave the foreground build on the
# script path. Removing the failed cache then exercises the retry path.
rm -f -- "$script_started" "$compile_started"
touch "$fail_compile"
printf '\n// background AOT failure probe\n' >>"$rust_dir/lib/model_01.dart"
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background DART_SDK="$dart_sdk" \
  BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/run_rust_frontend.sh" \
  build --root "$rust_dir" --dart "$dart_wrapper" --mode rust \
  >"$failure_log" 2>&1 || fail 'failed background build did not fall back'
wait_for_file "$compile_started" 600 || fail 'failed background compile did not start'
lock_path="$rust_dir/.dart_tool/build_runner_accelerator/.aot-background.lock"
for _ in $(seq 1 600); do
  [[ ! -e "$lock_path" ]] && break
  sleep 0.2
done
[[ ! -e "$lock_path" ]] || fail 'failed background compile left a stale lock'
[[ -e "$script_started" ]] || fail 'failed background build did not use script fallback'

: >"$lock_path"
stale_lock_check=skipped
if touch -d '2 hours ago' "$lock_path" 2>/dev/null; then
  stale_lock_check=passed
else
  rm -f -- "$lock_path"
fi
rm -f -- "$fail_compile" "$compile_started" "$script_started"
rm -f -- "$aot_path" "$aot_path.d" "$aot_path.sdk"
printf '\n// background AOT retry probe\n' >>"$rust_dir/lib/model_01.dart"
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background DART_SDK="$dart_sdk" \
  BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/run_rust_frontend.sh" \
  build --root "$rust_dir" --dart "$dart_wrapper" --mode rust \
  >"$retry_log" 2>&1 || fail 'background retry build failed'
wait_for_file "$aot_path" 1200 || fail 'background AOT retry did not publish an executable'
[[ -x "$aot_path" ]] || fail 'background retry artifact is not executable'
[[ "$(wc -l <"$compile_attempts")" -ge 3 ]] || fail 'background retry did not invoke the compiler again'

rm -f -- "$script_started"
printf '\n// background AOT reuse probe\n' >>"$rust_dir/lib/model_01.dart"
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background DART_SDK="$dart_sdk" \
  BUILD_RUNNER_ACCELERATOR_BIN="$fast_bin" "$script_dir/run_rust_frontend.sh" \
  build --root "$rust_dir" --dart "$dart_wrapper" --mode rust \
  >"$second_log" 2>&1 || fail 'AOT reuse build failed'
[[ -f "$rust_dir/lib/model_01.g.dart" ]] || \
  fail 'AOT reuse build produced no generated output'
[[ ! -e "$script_started" ]] || \
  fail 'AOT reuse build invoked the Dart script worker'

printf 'aot-background: first-build-immediate=yes failure-fallback=yes lock-released=yes stale-lock=$stale_lock_check retry=yes cache-reuse=yes\n'
