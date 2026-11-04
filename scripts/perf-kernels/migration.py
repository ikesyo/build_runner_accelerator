#!/usr/bin/env python3
"""Measure a hash upgrade and its next ordinary (non-override) launcher build.

Requires a disposable prepared 500-feature mixed fixture. Baseline preparation
is unmeasured and warms its normal AOT cache before the candidate invalidates it.
Do not run other benchmarks, compilers or correctness checks concurrently.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
from paired_warm import inventory, marker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['workspace', 'baseline', 'proposal', 'dart', 'pub-cache', 'cache', 'results']:
        parser.add_argument('--' + name, required=True, type=Path)
    args = parser.parse_args()
    work = args.workspace.resolve()
    results = args.results.resolve()
    results.mkdir(parents=True)
    assert len(list((work / 'lib/features').glob('*/model.dart'))) == 500
    assert 'publish_to: none' in (work / 'pubspec.yaml').read_text()
    repo = Path(__file__).resolve().parents[2]
    command = [str(args.dart.resolve()), '--suppress-analytics', 'run',
               'build_runner_accelerator', 'build', '--jobs', '2']
    env = dict(os.environ, PUB_CACHE=str(args.pub_cache.resolve()),
               BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache.resolve()),
               BUILD_RUNNER_ACCELERATOR_METRICS='0',
               BUILD_RUNNER_ACCELERATOR_WALL_TRACE='0',
               BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE='0')
    env.pop('BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH', None)
    marker(work, 'base')
    env['BUILD_RUNNER_ACCELERATOR_BIN'] = str(args.baseline.resolve())
    with (results / 'baseline-preparation.log').open('w') as output:
        subprocess.run(command, cwd=work, env=env, stdout=output,
                       stderr=subprocess.STDOUT, check=True)
    expected = inventory(work)
    assert len(expected) == 1001
    env['BUILD_RUNNER_ACCELERATOR_BIN'] = str(args.proposal.resolve())
    records = []
    for label in ['upgrade', 'steady']:
        prefix = results / label
        subprocess.run(['python3', str(repo / 'scripts/measure_process.py'),
                        '--metrics', str(prefix.with_suffix('.json')),
                        '--stdout', str(prefix.with_suffix('.stdout')),
                        '--stderr', str(prefix.with_suffix('.stderr')),
                        '--cwd', str(work), '--label', label, '--', *command],
                       env=env, check=True)
        assert inventory(work) == expected
        records.append(json.loads(prefix.with_suffix('.json').read_text())
                       | {'case': label, 'byte_identical': True})
    (results / 'results.json').write_text(json.dumps(records, indent=2) + '\n')


if __name__ == '__main__':
    main()
