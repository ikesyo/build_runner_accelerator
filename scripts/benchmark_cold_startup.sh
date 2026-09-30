#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
worker_ensure_frontend
fixture=${COLD_BENCHMARK_ROOT:-$repo_root/fixtures/json_serializable_10_app}
results=${COLD_BENCHMARK_RESULTS:-$(mktemp -d)}
mkdir -p "$results"
# The JSON fixture must already have a resolved package_config. All measured
# builds run in an isolated copy; SDK/pub downloads and OS page cache are warm.
# Run without concurrent builds. Results must be a fresh directory.
python3 - "$fixture" "$dart_bin" "$BUILD_RUNNER_ACCELERATOR_BIN" "$results" "${JOBS:-1}" "${COLD_BENCHMARK_REPEATS:-3}" <<'PY'
import json, os, pathlib, shutil, statistics, subprocess, sys, time, urllib.parse

source, dart, native, results, jobs, repeats = sys.argv[1:]
source, results = pathlib.Path(source).resolve(), pathlib.Path(results).resolve()
config_path = source / '.dart_tool/package_config.json'
assert config_path.is_file(), 'Resolve fixture with dart pub get first'
root = results / 'fixture'
assert not root.exists(), 'Use a fresh results directory'
root.mkdir()
for name in ['pubspec.yaml', 'pubspec.lock']:
    shutil.copy2(source / name, root / name)
shutil.copytree(source / 'lib', root / 'lib')
for path in (root / 'lib').rglob('*.g.dart'):
    path.unlink()
config = json.loads(config_path.read_text())
for package in config['packages']:
    uri = urllib.parse.urljoin(config_path.as_uri(), package['rootUri'])
    if pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path)).resolve() == source:
        uri = root.as_uri() + '/'
    package['rootUri'] = uri
(root / '.dart_tool').mkdir()
(root / '.dart_tool/package_config.json').write_text(json.dumps(config))
inputs = {p: p.read_bytes() for p in (root / 'lib').rglob('*.dart')}
env = dict(os.environ, BUILD_RUNNER_ACCELERATOR_METRICS='1',
           BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1')
for variable in ['BUILD_RUNNER_ACCELERATOR_PLAN_ONLY', 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',
                 'BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL']:
    env.pop(variable, None)

def outputs():
    return {str(p.relative_to(root)): p.read_bytes() for p in (root / 'lib').rglob('*.g.dart')}

stock_command = [dart, '--suppress-analytics', 'run', 'build_runner', 'build',
                 '--delete-conflicting-outputs']
with (results / 'stock.log').open('w') as log:
    subprocess.run(stock_command, cwd=root, env=env, stdout=log, stderr=log,
                   check=True, timeout=300)
expected = outputs()
assert expected, 'Stock reference produced no JSON outputs'
command = [native, 'build', '--root', str(root), '--dart', dart,
           '--mode', 'rust', '--jobs', jobs]
records = []

def measure(mode, case, index, run_env):
    label = f'{index}-{mode}-{case}'
    start = time.monotonic()
    with (results / (label + '.log')).open('w') as log:
        subprocess.run(command, cwd=root, env=run_env, stdout=log, stderr=log,
                       check=True, timeout=300)
    wall = time.monotonic() - start
    assert outputs() == expected, f'{label}: output differs from stock'
    record = dict(mode=mode, case=case, wall_seconds=wall, outputs_equal=True)
    records.append(record)
    (results / 'measurements.json').write_text(json.dumps(records, indent=2))
    print(json.dumps(record), flush=True)

for index, mode in enumerate(['baseline', 'early'] * int(repeats)):
    for path, contents in inputs.items():
        path.write_bytes(contents)
    for path in (root / 'lib').rglob('*.g.dart'):
        path.unlink()
    for directory in ['build', 'build_runner_accelerator']:
        shutil.rmtree(root / '.dart_tool' / directory, ignore_errors=True)
    run_env = dict(env, BUILD_RUNNER_ACCELERATOR_CACHE=str(results / f'cache-{index}'),
                   ANALYZER_STATE_LOCATION_OVERRIDE=str(results / f'analyzer-{index}'),
                   BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT='0' if mode == 'baseline' else '1',
                   BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG='0' if mode == 'baseline' else '1')
    measure(mode, 'cold', index, run_env)
    measure(mode, 'noop', index, run_env)
    first = next(iter(inputs))
    first.write_bytes(inputs[first] + b'\n// one-file benchmark change\n')
    measure(mode, 'one-file', index, run_env)
    for path, contents in inputs.items():
        path.write_bytes(contents + b'\n// broad benchmark change\n')
    measure(mode, 'broad', index, run_env)
for mode in ['baseline', 'early']:
    for case in ['cold', 'noop', 'one-file', 'broad']:
        samples = [r['wall_seconds'] for r in records if r['mode'] == mode and r['case'] == case]
        print(f'{mode} {case}: n={len(samples)} median_seconds={statistics.median(samples):.3f}')
print(f'jobs={jobs} outputs-identical-to-stock=yes native-frontend-only=yes\n'
      f'command={command!r}\nresults={results}')
PY
