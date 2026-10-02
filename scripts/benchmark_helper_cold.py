#!/usr/bin/env python3
"""Compare first native builds with empty application caches (OS caches warm).

Usage: python3 scripts/benchmark_helper_cold.py /tmp/fresh-results --repeats 3
Runs sequentially, waits for detached training between trials, and checks every
build against stock. Pub resolution and stock generation are outside timing.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--expect-deferred', action='store_true')
    options = parser.parse_args()
    if options.repeats < 1 or options.jobs < 1:
        parser.error('repeats and jobs must be positive')
    repo = Path(__file__).resolve().parent.parent
    results = options.results.resolve()
    results.mkdir()  # A fresh directory prevents accidental cache reuse.
    fixture = repo / 'fixtures/json_serializable_10_app'
    dart = os.environ.get('DART_BIN', str(repo / '.toolchains/dart/dart-sdk/bin/dart'))
    native = os.environ.get('BUILD_RUNNER_ACCELERATOR_BIN',
                            str(repo / 'rust/target/release/build_runner_accelerator'))
    base_env = dict(os.environ, CI='true', DART_SUPPRESS_ANALYTICS='true',
                    PUB_CACHE=os.environ.get('PUB_CACHE', str(repo / '.pub-cache')))
    # Compare the default native policy; change only helper snapshot enablement.
    for key in list(base_env):
        if key.startswith('BUILD_RUNNER_ACCELERATOR_'):
            del base_env[key]

    def run(root, env, label, command):
        with (root / f'{label}.log').open('w') as log:
            start = time.monotonic()
            subprocess.run(command, cwd=root, env=env, stdout=log, stderr=log,
                           check=True, timeout=300)
            return time.monotonic() - start

    def setup(name):
        root = results / name
        root.mkdir()
        for name in ['pubspec.yaml', 'pubspec.lock']:
            shutil.copy2(fixture / name, root / name)
        pubspec = root / 'pubspec.yaml'
        pubspec.write_text(re.sub(
            r'(?m)^([ \t]*path:[ \t]*)\.\./\.\.[ \t]*$',
            lambda match: match[1] + json.dumps(str(repo)), pubspec.read_text()))
        shutil.copytree(fixture / 'lib', root / 'lib')
        for path in (root / 'lib').rglob('*.g.dart'):
            path.unlink()
        env = dict(base_env,
                   BUILD_RUNNER_ACCELERATOR_CACHE=str(root / 'machine-cache'),
                   ANALYZER_STATE_LOCATION_OVERRIDE=str(root / 'analyzer-cache'),
                   BUILD_RUNNER_ACCELERATOR_METRICS='1')
        run(root, env, 'resolve', [dart, '--suppress-analytics', 'pub', 'get', '--offline'])
        return root, env

    def outputs(root):
        return {str(path.relative_to(root)): path.read_bytes()
                for path in (root / 'lib').rglob('*.g.dart')}

    root, env = setup('stock')
    run(root, env, 'stock', [dart, '--suppress-analytics', 'run', 'build_runner',
                           'build', '--delete-conflicting-outputs'])
    expected = outputs(root)
    assert expected
    records = []
    for index in range(options.repeats):
        order = ['disabled', 'enabled'] if index % 2 == 0 else ['enabled', 'disabled']
        for mode in order:
            root, env = setup(f'{mode}-{index}')
            env['BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT'] = '0' if mode == 'disabled' else '1'
            start = time.monotonic()
            foreground = run(root, env, 'build', [
                native, 'build', '--root', str(root), '--dart', dart,
                '--mode', 'rust', '--jobs', str(options.jobs)])
            assert outputs(root) == expected
            helpers = root / '.dart_tool/build_runner_accelerator/helper-snapshots'
            remaining = [str(path.relative_to(root)) for path in helpers.glob('*/.build.lock')]
            if mode == 'enabled' and options.expect_deferred:
                log = (root / 'build.log').read_text()
                assert log.index('Build completed (Rust frontend)') < log.index('training=started')
            while list(helpers.glob('*/.build.lock')):
                if time.monotonic() - start > 300:
                    raise TimeoutError('detached helper training still active')
                time.sleep(0.1)
            total = time.monotonic() - start
            artifacts = sorted(path.parent.name for path in helpers.glob('*/helper.jit.sdk'))
            if mode == 'enabled':
                assert 'worker-catalog' in artifacts, 'catalog JIT training failed'
            record = dict(mode=mode, index=index, foreground_seconds=foreground,
                          with_background_seconds=total,
                          training_active_at_build_end=remaining,
                          jit_helpers=artifacts, outputs_equal=True)
            records.append(record)
            (results / 'measurements.json').write_text(json.dumps(records, indent=2))
            print(json.dumps(record), flush=True)
    summary = {mode: {
        field: statistics.median(record[field] for record in records if record['mode'] == mode)
        for field in ['foreground_seconds', 'with_background_seconds']
    } for mode in ['disabled', 'enabled']}
    (results / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
