#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
temporary_dir=$(mktemp -d)
cleanup() {
  local status=$?
  if ((status == 0)); then
    rm -rf -- "$temporary_dir"
  else
    printf 'helper-snapshot: retaining logs: %s\n' "$temporary_dir" >&2
  fi
}
trap cleanup EXIT
worker_ensure_frontend
worker_prepare
worker_attach "$temporary_dir/workspace"
mkdir -p "$temporary_dir/workspace/bin"
cp "$repo_root/bin/prewarm_analysis.dart" "$temporary_dir/workspace/bin/"
fixture="$temporary_dir/workspace/fixtures/app"
mkdir -p "$fixture"
cp "$repo_root/fixtures/json_serializable_app/pubspec.yaml" "$fixture/"
cp "$repo_root/fixtures/json_serializable_app/pubspec.lock" "$fixture/"
cp -R "$repo_root/fixtures/json_serializable_app/lib" "$fixture/"
worker_pub_get "$fixture" --offline
python3 - "$fixture" "$dart_bin" "$BUILD_RUNNER_ACCELERATOR_BIN" "$temporary_dir" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, time

root, dart, native, temporary = sys.argv[1:]
root, temporary = pathlib.Path(root), pathlib.Path(temporary)
state = root / '.dart_tool/build_runner_accelerator'
package = temporary / 'workspace'
env = dict(os.environ, BUILD_RUNNER_ACCELERATOR_CACHE=str(temporary / 'cache'),
           BUILD_RUNNER_ACCELERATOR_METRICS='1', BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1',
           BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT='0',
           BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM='0')

def run(label, command, extra=None):
    with (temporary / (label + '.log')).open('w') as log:
        subprocess.run(command, cwd=root, env=dict(env, **(extra or {})),
                       stdout=log, stderr=log, check=True, timeout=300)
    return (temporary / (label + '.log')).read_text()

def train(name, script, args, cleanup=()):
    spec = '\x1f'.join([name, str(script), *map(str, args), '\x1e', *map(str, cleanup)])
    run('train-' + name, [native, 'helper-snapshot', '--root', str(root), '--dart', dart],
        {'BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT_SPEC': spec})

def generate(label, extra=None):
    (state / 'builder-manifest.json').unlink(missing_ok=True)
    text = run(label, [native, 'build', '--root', str(root), '--dart', dart,
                       '--mode', 'rust', '--jobs', '1'], extra)
    return text, (state / 'dynamic_worker.dart').read_bytes()

catalog = package / 'tool/generate_worker_catalog.dart'
scratch = state / 'helper-snapshots/worker-catalog/train.dart'
train('worker-catalog', catalog, [root, scratch], [scratch])
assert not scratch.exists()
catalog_dir = scratch.parent
assert (catalog_dir / 'helper.jit').is_file()
log, expected = generate('jit')
assert 'artifact=jit cache=local' in log
log, output = generate('disabled', {'BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT': '0'})
assert 'Rust helper snapshot[' not in log and output == expected

shutil.rmtree(catalog_dir)
log, output = generate('shared')
assert 'artifact=jit cache=shared' in log and output == expected

# Reject corrupt warm code, then use the separately validated kernel tier.
(catalog_dir / 'helper.jit').write_bytes(b'corrupt')
for path in (temporary / 'cache/helper-snapshots').glob('*/jit/helper'):
    path.write_bytes(b'corrupt')
log, output = generate('kernel')
assert 'artifact=dill cache=shared' in log and output == expected

# Source digests must invalidate both tiers even when mtime stays unchanged.
dependency = package / 'lib/src/manifest/source.dart'
stat = dependency.stat()
dependency.write_bytes(dependency.read_bytes() + b'\n// helper invalidation probe\n')
os.utime(dependency, ns=(stat.st_atime_ns, stat.st_mtime_ns))
log, output = generate('dependency')
assert 'artifact=script cache=miss' in log and output == expected
deadline = time.monotonic() + 120
while (catalog_dir / '.build.lock').exists():
    assert time.monotonic() < deadline, 'background helper training did not finish'
    time.sleep(0.1)

# Prewarm JIT uses invocation arguments rather than the training shard/dirs.
prewarm = package / 'bin/prewarm_analysis.dart'
train('analysis-prewarm', prewarm, ['--shard', '0', '--shards', '1', '--dirs', 'none'])
program = state / 'helper-snapshots/analysis-prewarm/helper.jit'
log = run('prewarm-jit', [dart, str(program), '--shard', '1', '--shards', '2', '--dirs', 'lib'])
assert 'prewarm[1]: done' in log

# An unsuccessful app-jit training run must retain its valid kernel fallback.
train('failed-training', catalog, [])
failed = state / 'helper-snapshots/failed-training'
assert (failed / 'helper.dill.sdk').is_file() and not (failed / 'helper.jit').exists()
run('failed-training-kernel', [dart, str(failed / 'helper.dill'), str(root), str(scratch)])
assert scratch.read_bytes() == expected

# Observe both the native prewarm invocation and its detached training pass.
# Summary-only work must stay summary-only in both processes.
prewarm.write_text('''import 'dart:convert';
import 'dart:io';
void main(List<String> args) {
  File('training-args.jsonl').writeAsStringSync('${jsonEncode(args)}\\n', mode: FileMode.append);
}
''')
run('prewarm-scope', [native, 'aot-prewarm', '--root', str(root), '--dart', dart,
                      '--mode', 'rust', '--jobs', '1'], {
    'BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM': '1',
    'BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_JOBS': '1',
    'BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM_DIRS': 'none',
})
deadline = time.monotonic() + 120
while (state / 'helper-snapshots/analysis-prewarm/.build.lock').exists():
    assert time.monotonic() < deadline, 'summary-only training did not finish'
    time.sleep(0.1)
invocations = [json.loads(line) for line in (root / 'training-args.jsonl').read_text().splitlines()]
assert len(invocations) >= 2, 'prewarm and training must both run'
assert all(args[-2:] == ['--dirs', 'none'] for args in invocations), invocations
print('helper-snapshot: PASS jit/disabled/shared/corruption/kernel/dependency/prewarm-args/training-failure/training-scope')
PY
