#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
dart_bin=$(resolve_toolchain_dart)
worker_ensure_frontend
fixture=${MANIFEST_BENCHMARK_ROOT:-$repo_root/fixtures/json_serializable_app}
results=${MANIFEST_BENCHMARK_RESULTS:-$(mktemp -d)}
mkdir -p "$results"
# This measures native generator startup, not launcher-inclusive build time.
# The selected fixture must already have a resolved package configuration.
# Run without concurrent builds or source edits in that workspace.
python3 - "$fixture" "$dart_bin" "$BUILD_RUNNER_ACCELERATOR_BIN" "$results" <<'PY'
import json, os, pathlib, statistics, subprocess, sys, time

root, dart, native, results = sys.argv[1:]
root = pathlib.Path(root).resolve()
results = pathlib.Path(results).resolve()
assert (root / '.dart_tool/package_config.json').is_file(), 'Resolve fixture with dart pub get first'
paths = [root / '.dart_tool/build_runner_accelerator' / name
         for name in ['builder-manifest.json', 'dynamic_worker.dart']]
saved = {path: (path.read_bytes(), path.stat()) if path.exists() else None for path in paths}
env = dict(os.environ,
           BUILD_RUNNER_ACCELERATOR_CACHE=str(results / 'cache'),
           BUILD_RUNNER_ACCELERATOR_WORKER_AOT='0',
           BUILD_RUNNER_ACCELERATOR_PLAN_ONLY='1',
           BUILD_RUNNER_ACCELERATOR_METRICS='1')
command = [native, 'build', '--root', str(root), '--dart', dart,
           '--mode', 'rust', '--jobs', '1']
records = []
reference = None

def generate(mode, label):
    for path in paths:
        path.unlink(missing_ok=True)
    start = time.monotonic()
    run = subprocess.run(command,
                         env=dict(env, BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=mode),
                         text=True, capture_output=True, timeout=300)
    wall = time.monotonic() - start
    (results / (label + '.log')).write_text(run.stdout + run.stderr)
    if run.returncode:
        raise RuntimeError(run.stderr)
    return wall, run.stderr, [path.read_bytes() for path in paths]

try:
    # Warm probe results before timing; leave the snapshot cache empty.
    generate('0', 'probe-prewarm')
    for index, mode in enumerate(['0', '1'] * 4):
        wall, diagnostics, outputs = generate(mode, str(index))
        if reference is None:
            reference = outputs
        assert outputs == reference, 'Manifest or worker differs between source and snapshot'
        state = ('source' if mode == '0' else
                 'hit' if 'Rust manifest snapshot: cache=hit' in diagnostics else
                 'miss' if 'Rust manifest snapshot: cache=miss' in diagnostics else 'fallback')
        record = dict(state=state, wall_seconds=wall,
                      metrics=[line for line in diagnostics.splitlines() if 'manifest' in line])
        records.append(record)
        print(json.dumps(record), flush=True)
    (results / 'measurements.json').write_text(json.dumps(records, indent=2))
    for state in ['source', 'miss', 'hit', 'fallback']:
        samples = [record['wall_seconds'] for record in records if record['state'] == state]
        if samples:
            print(f'{state}: n={len(samples)} median_seconds={statistics.median(samples):.3f}')
    print('manifest-benchmark: manifest-identical=yes worker-identical=yes '
          'worker-aot=disabled jobs=1 frontend-only=yes')
    print(f'command={command!r}\nresults={results}')
finally:
    for path, previous in saved.items():
        if previous is None:
            path.unlink(missing_ok=True)
        else:
            contents, stat = previous
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
PY
