#!/usr/bin/env python3
"""Rotate three frontends on a disposable, prepared mixed benchmark fixture.

Derived from the PR #163 paired harness, adapted for this investigation.
Run after benchmark_current_baseline.sh with KEEP_BENCHMARK_WORKSPACE=1. This edits
the generated fixture sources and reuses its explicitly prewarmed AOT worker.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
import time


def inventory(workspace):
    return {str(p.relative_to(workspace / 'lib')): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((workspace / 'lib').rglob('*.dart'))
            if p.name.endswith(('.g.dart', '.freezed.dart'))}


def marker(workspace, value):
    shared = workspace / 'lib/shared.dart'
    before = shared.read_text()
    after = re.sub(r'enum Lifecycle \{[^}]+\}',
                   'enum Lifecycle { unknown, draft, active, archived' +
                   (', paused }' if value == 'broad' else ' }'), before)
    if before != after:
        shared.write_text(after)
    paths = sorted((workspace / 'lib/features').glob('*/model.dart'))
    if value == 'one-file':
        paths = paths[:1]
    for path in paths:
        before = path.read_text()
        after = re.sub(r"@JsonKey\(name: 'title_[^']*'\)",
                       "@JsonKey(name: 'title_" + ('one-file' if value == 'one-file' else 'base') + "')", before)
        if before != after:
            path.write_text(after)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['workspace', 'repository', 'baseline', 'native', 'proposal',
                 'cache', 'dart', 'pub-cache', 'results']:
        parser.add_argument('--' + name, required=True, type=Path)
    parser.add_argument('--noop-repeats', type=int, default=9)
    parser.add_argument('--edit-repeats', type=int, default=3)
    parser.add_argument('--broad-repeats', type=int, default=3)
    parser.add_argument('--worker-aot', type=Path)
    args = parser.parse_args()
    assert min(args.noop_repeats, args.edit_repeats, args.broad_repeats) > 0
    workspace = args.workspace.resolve()
    repository = args.repository.resolve()
    results = args.results.resolve()
    results.mkdir(parents=True)
    assert (workspace / 'lib/shared.dart').is_file()
    models = list((workspace / 'lib/features').glob('*/model.dart'))
    assert len(models) == 500, 'requires the disposable 500-feature benchmark'
    assert 'publish_to: none' in (workspace / 'pubspec.yaml').read_text()
    aot = (args.worker_aot or workspace / '.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker').resolve()
    assert aot.is_file()
    binaries = {name: getattr(args, name).resolve() for name in ['baseline', 'native', 'proposal']}

    def environment(variant):
        return dict(os.environ, PUB_CACHE=str(args.pub_cache.resolve()),
                    BUILD_RUNNER_ACCELERATOR_BIN=str(binaries[variant]),
                    BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache.resolve()),
                    BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH=str(aot),
                    BUILD_RUNNER_ACCELERATOR_METRICS='0',
                    BUILD_RUNNER_ACCELERATOR_WALL_TRACE='0',
                    BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE='0')

    command = [str(args.dart.resolve()), '--suppress-analytics', 'run',
               'build_runner_accelerator', 'build', '--jobs', '2']

    state_root = results / 'variant-state'
    state_root.mkdir()
    state_files = ['graph-v3.bin', 'builder-manifest.json']
    private = workspace / '.dart_tool/build_runner_accelerator'

    def activate(variant):
        saved = state_root / variant
        if saved.exists():
            for name in state_files:
                shutil.copy2(saved / name, private / name)

    def remember(variant):
        saved = state_root / variant
        saved.mkdir(exist_ok=True)
        for name in state_files:
            shutil.copy2(private / name, saved / name)

    def restore(label, variant='baseline'):
        activate(variant)
        marker(workspace, 'base')
        with (results / f'{label}.restore.log').open('w') as output:
            subprocess.run(command, cwd=workspace, env=environment(variant),
                           stdout=output, stderr=subprocess.STDOUT, check=True)

    preparation = []
    for variant in binaries:
        start = time.perf_counter()
        restore('initial-' + variant, variant)
        preparation.append({'variant': variant, 'initialization_s': time.perf_counter()-start})
        remember(variant)
    (results / 'initialization.json').write_text(json.dumps(preparation, indent=2))
    restore('initial')
    base = inventory(workspace)
    assert len(base) == 1001
    references = {'no-op': base}
    records = []
    variants = list(binaries)
    for case in ['no-op', 'one-file', 'broad']:
        repeats = {'no-op': args.noop_repeats, 'one-file': args.edit_repeats, 'broad': args.broad_repeats}[case]
        for repeat in range(repeats):
            order = variants[repeat % 3:] + variants[:repeat % 3]
            for variant in order:
                label = f'{case}.{repeat}.{variant}'
                activate(variant)
                if case != 'no-op':
                    restore(label, variant)
                    assert inventory(workspace) == base
                    marker(workspace, case)
                prefix = results / label
                subprocess.run(['python3', str(repository / 'scripts/measure_process.py'),
                                '--metrics', str(prefix.with_suffix(prefix.suffix + '.json')),
                                '--stdout', str(prefix.with_suffix(prefix.suffix + '.stdout')),
                                '--stderr', str(prefix.with_suffix(prefix.suffix + '.stderr')),
                                '--cwd', str(workspace), '--label', label, '--', *command],
                               env=environment(variant), check=True, stdout=subprocess.DEVNULL)
                remember(variant)
                current = inventory(workspace)
                assert current.keys() == base.keys()
                changed = sum(digest != base[name] for name, digest in current.items())
                assert changed == {'no-op': 0, 'one-file': 1, 'broad': 500}[case]
                assert current == references.setdefault(case, current)
                record = json.loads(prefix.with_suffix(prefix.suffix + '.json').read_text())
                records.append({key: record[key] for key in ['wall_ms', 'user_ms', 'sys_ms', 'maxrss']}
                               | {'variant': variant, 'case': case, 'repeat': repeat,
                                  'byte_identical': True, 'changed_output_count': changed})
                (results / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
                print(label, record['wall_ms'], flush=True)


if __name__ == '__main__':
    main()
