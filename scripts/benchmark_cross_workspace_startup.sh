#!/usr/bin/env bash
set -euo pipefail

# Compare main and the current implementation in fresh workspaces on a machine
# whose shared caches are warm. Supply a baseline binary and its package source
# root; resolve fixtures/json_serializable_10_app with dart pub get first.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
worker_ensure_frontend
: "${CROSS_WORKSPACE_BASELINE_BIN:?provide the baseline native binary}"
: "${CROSS_WORKSPACE_BASELINE_ROOT:?provide the baseline package source root}"
fixture=${CROSS_WORKSPACE_ROOT:-$repo_root/fixtures/json_serializable_10_app}
results=${CROSS_WORKSPACE_RESULTS:-$(mktemp -d)}
mkdir -p "$results"
python3 - "$fixture" "$dart_bin" "$BUILD_RUNNER_ACCELERATOR_BIN" \
  "$CROSS_WORKSPACE_BASELINE_BIN" "$CROSS_WORKSPACE_BASELINE_ROOT" "$repo_root" \
  "$results" "${JOBS:-4}" "${CROSS_WORKSPACE_REPEATS:-3}" <<'PY'
import json, os, pathlib, shutil, statistics, subprocess, sys, time, urllib.parse

fixture, dart, native, baseline, baseline_root, repo, results, jobs, repeats = sys.argv[1:]
fixture, results = pathlib.Path(fixture).resolve(), pathlib.Path(results).resolve()
config_path = fixture / '.dart_tool/package_config.json'
config = json.loads(config_path.read_text())
assert not (results / 'reference').exists(), 'Use a fresh results directory'
env = dict(os.environ, BUILD_RUNNER_ACCELERATOR_METRICS='1',
           BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1')
for name in ['BUILD_RUNNER_ACCELERATOR_PLAN_ONLY', 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',
             'BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL', 'BUILD_RUNNER_ACCELERATOR_MANIFEST_PREWARM',
             'BUILD_RUNNER_ACCELERATOR_COMPILE_PREWARM']:
    env.pop(name, None)

def workspace(name, package_root):
    root = results / name
    root.mkdir()
    for name in ['pubspec.yaml', 'pubspec.lock']:
        shutil.copy2(fixture / name, root / name)
    shutil.copytree(fixture / 'lib', root / 'lib')
    for path in (root / 'lib').rglob('*.g.dart'):
        path.unlink()
    relocated = json.loads(json.dumps(config))
    for package in relocated['packages']:
        uri = urllib.parse.urljoin(config_path.as_uri(), package['rootUri'])
        resolved = pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(uri).path)).resolve()
        if resolved == fixture:
            uri = root.as_uri() + '/'
        elif package['name'] == 'build_runner_accelerator':
            uri = pathlib.Path(package_root).resolve().as_uri() + '/'
        package['rootUri'] = uri
    (root / '.dart_tool').mkdir()
    (root / '.dart_tool/package_config.json').write_text(json.dumps(relocated))
    return root

def outputs(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in (root / 'lib').rglob('*.g.dart')}

reference = workspace('reference', repo)
with (results / 'stock.log').open('w') as log:
    subprocess.run([dart, '--suppress-analytics', 'run', 'build_runner', 'build',
                    '--delete-conflicting-outputs'], cwd=reference, env=env,
                   stdout=log, stderr=log, check=True, timeout=300)
expected = outputs(reference)
assert expected, 'Stock produced no outputs'
records = []

def measure(mode, case, root, binary, index):
    run_env = dict(env, BUILD_RUNNER_ACCELERATOR_CACHE=str(results / f'{mode}-cache'),
                   ANALYZER_STATE_LOCATION_OVERRIDE=str(results / f'{mode}-analyzer'))
    command = [binary, 'build', '--root', str(root), '--dart', dart,
               '--mode', 'rust', '--jobs', jobs]
    label = f'{mode}-{index}-{case}'
    start = time.monotonic()
    with (results / f'{label}.log').open('w') as log:
        subprocess.run(command, cwd=root, env=run_env, stdout=log, stderr=log,
                       check=True, timeout=300)
    wall = time.monotonic() - start
    assert outputs(root) == expected, f'{label}: outputs differ from stock'
    if case != 'prime':
        record = dict(mode=mode, case=case, wall_seconds=wall, outputs_equal=True)
        records.append(record)
        (results / 'measurements.json').write_text(json.dumps(records, indent=2))
        print(json.dumps(record), flush=True)

modes = {'main': (baseline, baseline_root), 'reviewed': (native, repo)}
# Prime each machine-wide cache once, in a workspace that is never measured.
for mode, (binary, package_root) in modes.items():
    measure(mode, 'prime', workspace(f'{mode}-prime', package_root), binary, 0)
for index in range(int(repeats)):
    # Alternate ordering so later runs are not always the reviewed variant.
    for mode in (['main', 'reviewed'] if index % 2 == 0 else ['reviewed', 'main']):
        binary, package_root = modes[mode]
        root = workspace(f'{mode}-{index}', package_root)
        inputs = {p: p.read_bytes() for p in (root / 'lib').rglob('*.dart')}
        measure(mode, 'clean', root, binary, index)
        measure(mode, 'noop', root, binary, index)
        first = next(iter(inputs))
        first.write_bytes(inputs[first] + b'\n// one-file benchmark change\n')
        measure(mode, 'one-file', root, binary, index)
        for path, contents in inputs.items():
            path.write_bytes(contents + b'\n// broad benchmark change\n')
        measure(mode, 'broad', root, binary, index)
for mode in modes:
    for case in ['clean', 'noop', 'one-file', 'broad']:
        samples = [r['wall_seconds'] for r in records if r['mode'] == mode and r['case'] == case]
        print(f'{mode} {case}: n={len(samples)} median_seconds={statistics.median(samples):.3f}')
print(f'jobs={jobs} outputs-identical-to-stock=yes native-frontend-only=yes results={results}')
PY
