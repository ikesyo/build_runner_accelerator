#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary=$(mktemp -d)
workspace="$temporary/workspace"
stock="$workspace/fixtures/stock"
native="$workspace/fixtures/native"
holder_pid=
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then pub_get_args+=(--offline); fi
cleanup() {
  local status=$?
  if [[ -n "$holder_pid" ]]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  if (( status != 0 )) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'workspace: retained failure files: %s\n' "$temporary" >&2
  else
    rm -rf -- "$temporary"
  fi
}
trap cleanup EXIT
fail() { printf 'workspace: FAIL: %s\n' "$*" >&2; exit 1; }
worker_ensure_frontend
worker_prepare "${pub_get_args[@]}"
mkdir -p "$workspace/fixtures"
worker_attach "$workspace"
cp -R "$repo_root/bin" "$workspace/bin"
cp -R "$repo_root/fixtures/workspace_option_app" "$stock"
cp -R "$repo_root/fixtures/workspace_option_app" "$native"
rm -rf "$stock/.dart_tool" "$native/.dart_tool" "$stock/a/.dart_tool" "$native/a/.dart_tool" "$stock/b/.dart_tool" "$native/b/.dart_tool" "$stock/gen/.dart_tool" "$native/gen/.dart_tool"
worker_pub_get "$stock" "${pub_get_args[@]}"
worker_pub_get "$native" "${pub_get_args[@]}"
run_stock() {
  verification_run_stock_build "$stock" "workspace/stock/$1" "$temporary/stock-$1.log" "$dart_bin" "$pub_cache" build --workspace
}
run_native() {
  local jobs=${2:-1}
  local mode=${3:---force-jit}
  VERIFY_COMMAND_LOG="$temporary/native-$1.log" VERIFY_WORKSPACE="$native/a" \
    BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
    build --root "$native/a" --dart "$dart_bin" --workspace "$mode" --jobs "$jobs"
}
compare() {
  diff -r "$stock/a/lib" "$native/a/lib" || fail "member a outputs differ: $1"
  diff -r "$stock/b/lib" "$native/b/lib" || fail "member b outputs differ: $1"
}
run_stock initial
run_native initial
compare initial
cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/initial.graph"
run_stock noop
verification_run_command_in_dir "$native/a" "workspace/launcher/noop" "$temporary/launcher-noop.log" 300 \
  env PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 "$dart_bin" --suppress-analytics \
  run build_runner_accelerator build --workspace --dart "$dart_bin" --force-jit --jobs 1
VERIFY_COMMAND_LOG="$temporary/native-root.log" VERIFY_WORKSPACE="$native" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
  build --root "$native" --dart "$dart_bin" --workspace --force-jit --jobs 1
compare noop
grep -Fq 'No work to do (Rust frontend)' "$temporary/launcher-noop.log" || fail 'member no-op ran work'
grep -Fq 'No work to do (Rust frontend)' "$temporary/native-root.log" || fail 'root no-op ran work'
cmp "$temporary/initial.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'no-op changed graph'
cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/locked.graph"
for scope in member coordination; do
  if [[ "$scope" == member ]]; then
    lock="$native/a/.dart_tool/build_runner_accelerator/.workspace.lock"
    kind=exclusive
  else
    lock="$native/.dart_tool/build_runner_accelerator/.workspace-coordination.lock"
    kind=shared
  fi
  ready="$temporary/$scope.ready"
  release="$temporary/$scope.release"
  python3 - "$lock" "$kind" "$ready" "$release" <<'PY' &
import fcntl
from pathlib import Path
import sys
import time
with open(sys.argv[1], 'a+') as lock:
    fcntl.flock(lock, fcntl.LOCK_SH if sys.argv[2] == 'shared' else fcntl.LOCK_EX)
    Path(sys.argv[3]).touch()
    while not Path(sys.argv[4]).exists():
        time.sleep(0.05)
PY
  holder_pid=$!
  for ((attempt=0; attempt<100; attempt++)); do
    [[ -e "$ready" ]] && break
    kill -0 "$holder_pid" 2>/dev/null || fail "$scope lock holder exited"
    sleep 0.1
  done
  [[ -e "$ready" ]] || fail "$scope lock holder did not start"
  if run_native "locked-$scope"; then fail "$scope lock conflict was accepted"; fi
  if [[ "$scope" == member ]]; then
    grep -Fq 'native workspace writer lock is already held for ' "$temporary/native-locked-member.log" || fail 'wrong member-lock rejection'
  else
    grep -Fq 'workspace build conflicts with a running prewarm or cache-key command' "$temporary/native-locked-coordination.log" || fail 'wrong coordination-lock rejection'
  fi
  cmp "$temporary/locked.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail "$scope lock conflict changed graph"
  touch "$release"
  wait "$holder_pid"
  holder_pid=
done
printf 'changed a\n' > "$stock/a/lib/input.txt"
printf 'changed a\n' > "$native/a/lib/input.txt"
printf 'changed second\n' > "$stock/a/lib/second.txt"
printf 'changed second\n' > "$native/a/lib/second.txt"
printf 'changed b\n' > "$stock/b/lib/input.txt"
printf 'changed b\n' > "$native/b/lib/input.txt"
run_stock edit
BUILD_RUNNER_ACCELERATOR_METRICS=1 run_native edit 2 --force-aot
grep -Eq 'workers_active=2[[:space:]]+worker_starts_total=' "$temporary/native-edit.log" || fail 'AOT edit did not run with two active workers'
compare edit
rm "$stock/b/lib/input.txt" "$native/b/lib/input.txt"
run_stock delete
run_native delete
compare delete
mv "$stock/a/lib/input.txt" "$stock/a/lib/renamed.txt"
mv "$native/a/lib/input.txt" "$native/a/lib/renamed.txt"
run_stock rename
run_native rename
compare rename
cp "$native/a/lib/renamed.gen" "$temporary/before.gen"
cp "$native/a/lib/second.gen" "$temporary/before-second.gen"
cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/before.graph"
printf 'FAIL\n' > "$native/a/lib/renamed.txt"
printf 'changed during failure\n' > "$native/a/lib/second.txt"
printf 'new output\n' > "$native/b/lib/new.txt"
if run_native failure 2; then fail 'expected builder failure'; fi
cmp "$temporary/before.gen" "$native/a/lib/renamed.gen" || fail 'failure changed output'
cmp "$temporary/before-second.gen" "$native/a/lib/second.gen" || fail 'failure published another action output'
cmp "$temporary/before.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'failure changed graph'
[[ ! -e "$native/b/lib/new.gen" ]] || fail 'failure published another member output'
printf 'recovered\n' > "$stock/a/lib/renamed.txt"
printf 'recovered\n' > "$native/a/lib/renamed.txt"
printf 'changed during failure\n' > "$stock/a/lib/second.txt"
printf 'new output\n' > "$stock/b/lib/new.txt"
run_stock recovery
run_native recovery
compare recovery
if VERIFY_COMMAND_LOG="$temporary/single.log" VERIFY_WORKSPACE="$native/a" worker_run_frontend build --root "$native/a" --dart "$dart_bin" --force-jit --jobs 1; then
  fail 'individual build reused workspace outputs'
fi
if VERIFY_COMMAND_LOG="$temporary/prewarm.log" VERIFY_WORKSPACE="$native/a" worker_run_frontend prewarm --root "$native/a" --dart "$dart_bin"; then
  fail 'prewarm reused workspace state'
fi
cmp "$temporary/before.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" >/dev/null && fail 'recovery did not update graph'
cp "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/recovered.graph"
manifest="$native/.dart_tool/build_runner_accelerator/builder-manifest.json"
cp "$manifest" "$temporary/manifest.json"
python3 - "$manifest" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
next(builder for builder in data['builders'] if builder['package'] == 'ws_a')['is_root'] = False
path.write_text(json.dumps(data))
PY
if run_native bad-scope; then fail 'inconsistent manifest output scope was accepted'; fi
grep -Fq 'manifest output-package markers disagree with the locked build scope' "$temporary/native-bad-scope.log" || fail 'wrong output-scope rejection'
cmp "$temporary/recovered.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'invalid manifest changed graph'
cp "$temporary/manifest.json" "$manifest"
python3 - "$manifest" <<'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1])
data = json.loads(path.read_text())
builder = next(item for item in data['builders'] if item['package'] == 'ws_a')
builder.update(package='build', target='build:build', is_root=False)
path.write_text(json.dumps(data))
PY
if run_native bad-destination; then fail 'source builder in non-output package was accepted'; fi
grep -Fq 'source builders cannot write into non-output packages' "$temporary/native-bad-destination.log" || fail 'wrong non-output-package rejection'
cmp "$temporary/recovered.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'invalid destination changed graph'
cp "$temporary/manifest.json" "$manifest"
cp "$native/gen/build.yaml" "$temporary/generator.yaml"
printf '    is_optional: true\n' >> "$native/gen/build.yaml"
if run_native unsupported; then fail 'optional workspace builder was accepted'; fi
grep -Fq -- '--workspace currently supports non-optional builders without shared parts or triggers' "$temporary/native-unsupported.log" || fail 'wrong optional-builder rejection'
cmp "$temporary/recovered.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'unsupported builder changed graph'
cp "$temporary/generator.yaml" "$native/gen/build.yaml"
python3 - "$native/pubspec.yaml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('workspace: [a, b, gen]', 'workspace: [a, gen]'))
PY
worker_pub_get "$native" "${pub_get_args[@]}"
if run_native topology; then fail 'workspace topology change was accepted'; fi
grep -Fq 'workspace package topology changed or state marker is invalid' "$temporary/native-topology.log" || fail 'wrong topology rejection'
cmp "$temporary/recovered.graph" "$native/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'topology failure changed graph'
standalone="$workspace/fixtures/standalone"
mkdir -p "$standalone/lib"
cp "$repo_root/fixtures/workspace_option_app/gen/lib/builder.dart" "$standalone/lib/builder.dart"
printf 'standalone input\n' > "$standalone/lib/input.txt"
cat > "$standalone/pubspec.yaml" <<'YAML'
name: ws_gen
publish_to: none
environment:
  sdk: ">=3.11.0 <4.0.0"
dependencies:
  build: any
dev_dependencies:
  build_runner_accelerator:
    path: ../..
YAML
cp "$repo_root/fixtures/workspace_option_app/gen/build.yaml" "$standalone/build.yaml"
worker_pub_get "$standalone" "${pub_get_args[@]}"
VERIFY_COMMAND_LOG="$temporary/standalone.log" VERIFY_WORKSPACE="$standalone" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
  build --root "$standalone" --dart "$dart_bin" --force-jit --jobs 1
cp "$standalone/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/standalone.graph"
VERIFY_COMMAND_LOG="$temporary/standalone-workspace.log" VERIFY_WORKSPACE="$standalone" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
  build --root "$standalone" --dart "$dart_bin" --workspace --force-jit --jobs 1
cmp "$temporary/standalone.graph" "$standalone/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'workspace flag outside Pub workspace changed graph'
[[ ! -e "$standalone/.dart_tool/build_runner_accelerator/workspace-mode" ]] || fail 'standalone workspace flag created workspace marker'
previous="$workspace/fixtures/previous"
cp -R "$repo_root/fixtures/workspace_option_app" "$previous"
rm -rf "$previous/.dart_tool" "$previous/a/.dart_tool" "$previous/b/.dart_tool" "$previous/gen/.dart_tool"
worker_pub_get "$previous" "${pub_get_args[@]}"
VERIFY_COMMAND_LOG="$temporary/previous-single.log" VERIFY_WORKSPACE="$previous" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
  build --root "$previous" --dart "$dart_bin" --force-jit --jobs 1
cp "$previous/.dart_tool/build_runner_accelerator/graph-v3.bin" "$temporary/previous.graph"
if VERIFY_COMMAND_LOG="$temporary/previous-workspace.log" VERIFY_WORKSPACE="$previous" \
  BUILD_RUNNER_ACCELERATOR_WORKER_AOT=0 worker_run_frontend \
  build --root "$previous" --dart "$dart_bin" --workspace --force-jit --jobs 1; then
  fail 'workspace build reused individual root state'
fi
cmp "$temporary/previous.graph" "$previous/.dart_tool/build_runner_accelerator/graph-v3.bin" || fail 'scope rejection changed individual graph'
[[ ! -e "$previous/.dart_tool/build_runner_accelerator/workspace-mode" ]] || fail 'scope rejection created workspace marker'
printf 'workspace: PASS stock/native=yes aot=yes jobs=2 noop=yes edit=yes delete=yes rename=yes failure-recovery=yes state-transition=yes topology-rejection=yes\n'
