#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
export PUB_CACHE="$(resolve_toolchain_pub_cache)"
worker_ensure_frontend
fixture=${HELPER_BENCHMARK_ROOT:-$repo_root/fixtures/json_serializable_10_app}
worker_pub_get "$fixture" --offline
results=${HELPER_BENCHMARK_RESULTS:-$(mktemp -d)}
mkdir -p "$results"
python3 - "$fixture" "$dart_bin" "$BUILD_RUNNER_ACCELERATOR_BIN" "$repo_root" \
  "$results" "${JOBS:-4}" "${HELPER_BENCHMARK_REPEATS:-3}" <<'PY'
import json, os, pathlib, shutil, statistics, subprocess, sys, time, urllib.parse

fixture, dart, native, repo, results, jobs, repeats = sys.argv[1:]
fixture, repo, results = map(lambda p: pathlib.Path(p).resolve(), (fixture, repo, results))
root = results / 'fixture'
root.mkdir()
for name in ['pubspec.yaml', 'pubspec.lock']:
    shutil.copy2(fixture / name, root / name)
shutil.copytree(fixture / 'lib', root / 'lib')
config_path = fixture / '.dart_tool/package_config.json'
config = json.loads(config_path.read_text())
for package in config['packages']:
    uri = urllib.parse.urljoin(config_path.as_uri(), package['rootUri'])
    resolved = pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path)).resolve()
    package['rootUri'] = root.as_uri() + '/' if resolved == fixture else uri
(root / '.dart_tool').mkdir()
(root / '.dart_tool/package_config.json').write_text(json.dumps(config))
for p in (root / 'lib').rglob('*.g.dart'):
    p.unlink()
inputs = {p: p.read_bytes() for p in sorted((root / 'lib').rglob('*.dart'))}
state = root / '.dart_tool/build_runner_accelerator'
env = dict(os.environ, BUILD_RUNNER_ACCELERATOR_CACHE=str(results / 'cache'),
           ANALYZER_STATE_LOCATION_OVERRIDE=str(results / 'analyzer'),
           BUILD_RUNNER_ACCELERATOR_METRICS='1', BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1',
           BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT='0',
           BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT='1')
for name in ['BUILD_RUNNER_ACCELERATOR_PLAN_ONLY', 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',
             'BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL']:
    env.pop(name, None)
records = []

def run(label, command, run_env=env):
    start = time.monotonic()
    with (results / (label + '.log')).open('w') as log:
        subprocess.run(command, cwd=root, env=run_env, stdout=log, stderr=log,
                       check=True, timeout=300)
    return time.monotonic() - start

def outputs():
    return {str(p.relative_to(root)): p.read_bytes() for p in (root / 'lib').rglob('*.g.dart')}

run('stock', [dart, '--suppress-analytics', 'run', 'build_runner', 'build', '--delete-conflicting-outputs'])
expected = outputs()
assert expected
helper_args = {'worker-catalog': [str(root), str(state / 'train.dart')],
               'analysis-prewarm': ['--shard', '0', '--shards', '1']}
helper_scripts = {'worker-catalog': repo / 'tool/generate_worker_catalog.dart',
                  'analysis-prewarm': repo / 'bin/prewarm_analysis.dart'}
for name in helper_args:
    spec = '\x1f'.join([name, str(helper_scripts[name]), *helper_args[name], '\x1e'])
    run('train-' + name, [native, 'helper-snapshot', '--root', str(root), '--dart', dart],
        dict(env, BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT_SPEC=spec))
    for index in range(int(repeats)):
        for tier in (['script', 'dill', 'jit'] if index % 2 == 0 else ['jit', 'dill', 'script']):
            program = helper_scripts[name] if tier == 'script' else state / f'helper-snapshots/{name}/helper.{tier}'
            seconds = run(f'helper-{name}-{tier}-{index}',
                          [dart, f'--packages={root}/.dart_tool/package_config.json', str(program), *helper_args[name]])
            record = dict(scope='helper', helper=name, mode=tier, wall_seconds=seconds)
            if name == 'worker-catalog':
                actual = (state / 'train.dart').read_bytes()
                if 'catalog_expected' not in globals():
                    catalog_expected = actual
                assert actual == catalog_expected
                record['outputs_equal'] = True
            records.append(record)

command = [native, 'build', '--root', str(root), '--dart', dart, '--mode', 'rust', '--jobs', jobs]
run('prime', command)
assert outputs() == expected

def measure(mode, case, index, run_env):
    seconds = run(f'{mode}-{case}-{index}', command, run_env)
    assert outputs() == expected
    record = dict(scope='build', mode=mode, case=case, wall_seconds=seconds, outputs_equal=True)
    records.append(record)
    print(json.dumps(record), flush=True)
    (results / 'measurements.json').write_text(json.dumps(records, indent=2))

for index in range(int(repeats)):
    for mode in (['script', 'snapshot'] if index % 2 == 0 else ['snapshot', 'script']):
        for path, content in inputs.items():
            path.write_bytes(content)
        for path in (root / 'lib').rglob('*.g.dart'):
            path.unlink()
        for path in ['builder-manifest.json', 'graph-v3.bin', 'dynamic_worker.dart']:
            (state / path).unlink(missing_ok=True)
        shutil.rmtree(state / 'cache', ignore_errors=True)
        run_env = dict(env, BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT='0' if mode == 'script' else '1')
        measure(mode, 'clean', index, run_env)
        measure(mode, 'noop', index, run_env)
        first = next(iter(inputs))
        first.write_bytes(inputs[first] + b'\n// one-file helper benchmark\n')
        measure(mode, 'one-file', index, run_env)
        for path, content in inputs.items():
            path.write_bytes(content + b'\n// broad helper benchmark\n')
        measure(mode, 'broad', index, run_env)

summary = {}
for record in records:
    key = '/'.join([record['scope'], record.get('helper', record.get('case')), record['mode']])
    summary.setdefault(key, []).append(record['wall_seconds'])
summary = {key: statistics.median(values) for key, values in summary.items()}
(results / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2))
print(f'jobs={jobs} outputs-identical-to-stock=yes native-frontend-only=yes\ncommand={command!r}\nresults={results}')
PY
