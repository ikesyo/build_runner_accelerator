#!/usr/bin/env python3
"""Alternate native builds of two revisions with warm tool caches."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import statistics
import subprocess
import threading
import time
import urllib.parse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--baseline-bin', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    parser.add_argument('--candidate-bin', type=Path, required=True)
    parser.add_argument('--fixture-root', type=Path,
                        help='Fixture repository when comparing archived packages without git metadata')
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--metrics', choices=['0', '1'], default='1')
    parser.add_argument('--fixtures', nargs='+', default=[
        'json_serializable_10_app', 'freezed_app', 'riverpod_app'])
    parser.add_argument('--prepared-results', type=Path,
                        help='Reuse matching prepared workspaces and caches; write fresh sample logs')
    parser.add_argument('--shared-cache', action='store_true',
                        help='Use one content-addressed tool/analyzer cache for both variants')
    parser.add_argument('--cache-root', type=Path,
                        help='Retain warm tool/analyzer caches across independent comparisons')
    parser.add_argument('--baseline-commit', help='Identity of an archived baseline checkout')
    parser.add_argument('--reuse-workspaces', action='store_true',
                        help='Rerun samples in previously prepared workspaces and caches')
    args = parser.parse_args()
    assert args.jobs > 0 and args.repeats > 0
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=args.reuse_workspaces)
    prepared = args.prepared_results.resolve() if args.prepared_results else results
    repo = args.candidate_root.resolve()
    fixture_repo = args.fixture_root.resolve() if args.fixture_root else repo
    cache_root = args.cache_root.resolve() if args.cache_root else prepared
    variants = {
        'baseline': (args.baseline_root.resolve(), args.baseline_bin.resolve()),
        'candidate': (repo, args.candidate_bin.resolve()),
    }
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('BUILD_RUNNER_ACCELERATOR_')}
    env.update(BUILD_RUNNER_ACCELERATOR_METRICS=args.metrics,
               BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1')
    env.setdefault('PUB_CACHE', str(fixture_repo / '.pub-cache'))
    records = []
    metadata = {
        'jobs': args.jobs, 'repeats': args.repeats, 'metrics': args.metrics,
        'cache_layout': 'shared' if args.shared_cache else 'isolated',
        'cache_root': str(cache_root),
        'dart': subprocess.check_output([str(args.dart), '--version'], text=True).strip(),
        'scope': 'native frontend; warm SDK, pub, OS and tool caches; no Dart launcher',
        'variants': {}, 'fixtures': {},
    }
    def source_digest(root, directory):
        digest = hashlib.sha256()
        paths = (root / directory).rglob('*.dart' if directory == 'lib' else '*.rs')
        for path in sorted(paths):
            if 'target' in path.relative_to(root).parts:
                continue
            digest.update(str(path.relative_to(root)).encode())
            digest.update(path.read_bytes())
        return digest.hexdigest()

    for mode, (root, binary) in variants.items():
        commit = args.baseline_commit if mode == 'baseline' else None
        if commit is None:
            result = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                                    text=True, capture_output=True)
            commit = result.stdout.strip() if result.returncode == 0 else None
        metadata['variants'][mode] = {
            'commit': commit,
            'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            # Hash the actual files: candidates can be uncommitted and the
            # baseline can be a git archive without moving an existing branch.
            'rust_source_sha256': source_digest(root, 'rust'),
            'lib_source_sha256': source_digest(root, 'lib'),
        }
    baseline = metadata['variants']['baseline']
    candidate = metadata['variants']['candidate']
    assert (baseline['binary_sha256'] != candidate['binary_sha256'] or
            (baseline['rust_source_sha256'] == candidate['rust_source_sha256'] and
             baseline['lib_source_sha256'] != candidate['lib_source_sha256'])), 'No distinct implementation to compare'
    if args.prepared_results:
        previous = json.loads((prepared / 'metadata.json').read_text())
        assert previous['variants'] == metadata['variants'], 'Prepared implementations differ'
        assert previous['jobs'] == args.jobs
        assert previous['cache_layout'] == metadata['cache_layout']
        assert previous['dart'] == metadata['dart']

    last_command_cpu = {}

    def command(argv, root, log_path, run_env):
        cpu_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.perf_counter()
        with log_path.open('w') as log:
            # wait(timeout=...) polls with up to 50 ms sleeps on POSIX, which
            # would obscure differences between these subsecond builds.
            with subprocess.Popen(argv, cwd=root, env=run_env, stdout=log, stderr=log) as process:
                watchdog = threading.Timer(600, process.kill)
                watchdog.start()
                try:
                    returncode = process.wait()
                finally:
                    watchdog.cancel()
                if returncode:
                    raise subprocess.CalledProcessError(returncode, argv)
        wall = time.perf_counter() - start
        cpu_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        last_command_cpu.update(user=cpu_after.ru_utime - cpu_before.ru_utime,
                                system=cpu_after.ru_stime - cpu_before.ru_stime)
        return wall

    for fixture_name in args.fixtures:
        fixture = fixture_repo / 'fixtures' / fixture_name
        config_path = fixture / '.dart_tool/package_config.json'
        config = json.loads(config_path.read_text())
        tracked = subprocess.check_output(
            ['git', 'ls-files', f'fixtures/{fixture_name}/lib'], cwd=fixture_repo, text=True).splitlines()
        inputs = {str(Path(p).relative_to(fixture.relative_to(fixture_repo))): (fixture_repo / p).read_bytes()
                  for p in tracked if not p.endswith(('.g.dart', '.freezed.dart', '.g.part'))}
        metadata['fixtures'][fixture_name] = {
            'pubspec_lock_sha256': hashlib.sha256((fixture / 'pubspec.lock').read_bytes()).hexdigest(),
            'analyzer_root': next(p['rootUri'] for p in config['packages'] if p['name'] == 'analyzer'),
        }

        def workspace(mode, package_root):
            root = prepared / fixture_name / mode
            if args.reuse_workspaces or args.prepared_results:
                assert root.is_dir(), f'Missing prepared workspace: {root}'
                return root
            root.mkdir(parents=True)
            for name in ['pubspec.yaml', 'pubspec.lock', 'build.yaml']:
                if (fixture / name).exists():
                    shutil.copy2(fixture / name, root / name)
            pubspec = root / 'pubspec.yaml'
            pubspec.write_text(pubspec.read_text().replace(
                'path: ../..', f'path: {package_root}'))
            for name, content in inputs.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            relocated = json.loads(json.dumps(config))
            for package in relocated['packages']:
                uri = urllib.parse.urljoin(config_path.as_uri(), package['rootUri'])
                if package['name'] == fixture_name:
                    uri = root.as_uri() + '/'
                elif package['name'] == 'build_runner_accelerator':
                    uri = package_root.as_uri() + '/'
                package['rootUri'] = uri
            (root / '.dart_tool').mkdir()
            (root / '.dart_tool/package_config.json').write_text(json.dumps(relocated))
            command([str(args.dart), '--suppress-analytics', 'pub', 'get', '--offline'],
                    root, results / f'{fixture_name}-{mode}-pub.log', env)
            return root

        def outputs(root, stock=False):
            files = {str(p.relative_to(root)): p.read_bytes() for p in (root / 'lib').rglob('*')
                     if p.is_file() and str(p.relative_to(root)) not in inputs}
            cache = root / ('.dart_tool/build/generated' if stock else '.dart_tool/build_runner_accelerator/cache')
            if cache.exists():
                for p in cache.rglob('*.g.part'):
                    files['cache/' + str(p.relative_to(cache))] = p.read_bytes()
            return files

        reference = workspace('stock', repo)
        if not (args.reuse_workspaces or args.prepared_results):
            command([str(args.dart), '--suppress-analytics', 'run', 'build_runner',
                     'build', '--delete-conflicting-outputs'], reference,
                    results / f'{fixture_name}-stock.log', env)
        expected = outputs(reference, stock=True)
        assert expected
        roots = {mode: workspace(mode, package_root) for mode, (package_root, _) in variants.items()}
        dependency_sets = []
        for root in [reference, *roots.values()]:
            packages = json.loads((root / '.dart_tool/package_config.json').read_text())['packages']
            dependency_sets.append({p['name']: p for p in packages
                                    if p['name'] not in [fixture_name, 'build_runner_accelerator']})
        assert dependency_sets[0] == dependency_sets[1] == dependency_sets[2], 'Dependency sets differ'
        metadata['fixtures'][fixture_name]['dependency_roots'] = {
            name: dependency_sets[0][name]['rootUri']
            for name in ['analyzer', 'build_runner', 'json_serializable', 'freezed', 'riverpod_generator']
            if name in dependency_sets[0]
        }

        def reset(root):
            shutil.rmtree(root / 'lib')
            for name, content in inputs.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            tool = root / '.dart_tool/build_runner_accelerator'
            (tool / 'graph-v3.bin').unlink(missing_ok=True)
            for name in ['cache', 'overlay']:
                shutil.rmtree(tool / name, ignore_errors=True)

        def measure(mode, case, iteration):
            root = roots[mode]
            cache_prefix = 'shared' if args.shared_cache else mode
            run_env = dict(env,
                           BUILD_RUNNER_ACCELERATOR_CACHE=str(cache_root / f'{cache_prefix}-tool-cache'),
                           ANALYZER_STATE_LOCATION_OVERRIDE=str(cache_root / f'{cache_prefix}-analyzer-cache'))
            argv = [str(variants[mode][1]), 'build', '--root', str(root),
                    '--dart', str(args.dart), '--mode', 'rust', '--jobs', str(args.jobs)]
            log_path = results / f'{fixture_name}-{mode}-{iteration}-{case}.log'
            pack_root = Path(run_env['BUILD_RUNNER_ACCELERATOR_CACHE']) / 'byte_store'
            def packed_bytes():
                return sum(p.stat().st_size for p in pack_root.rglob('store.v1.bin'))
            packed_before = packed_bytes()
            wall = command(argv, root, log_path, run_env)
            packed_after = packed_bytes()
            assert outputs(root) == expected, f'{log_path}: outputs differ from stock'
            text = log_path.read_text()
            if case == 'noop':
                assert 'No work to do (Rust frontend)' in text
            record = dict(fixture=fixture_name, variant=mode, case=case,
                          iteration=iteration, wall_seconds=wall, outputs_equal=True,
                          cpu_seconds=dict(last_command_cpu),
                          packed_bytes_before=packed_before, packed_bytes_after=packed_after,
                          command=argv, log=str(log_path), action_metrics=[], resolver_metrics=[])
            for line in text.splitlines():
                if line.startswith('Dart action metrics: '):
                    record['resolver_metrics'].append(json.loads(line.removeprefix('Dart action metrics: ')))
                if line.startswith('Dart metrics: '):
                    record['action_metrics'].append(json.loads(line.removeprefix('Dart metrics: ')))
            if iteration >= 0:
                assert 'AOT cache miss' not in text and 'Generated:' not in text, (
                    f'{log_path}: measured worker compilation')
                records.append(record)
                (results / 'measurements.json').write_text(json.dumps(records, indent=2))
            print(json.dumps({k: v for k, v in record.items()
                              if k not in ['action_metrics', 'resolver_metrics', 'command', 'log']}), flush=True)

        # Compilation and cache population are outside the measured samples.
        for mode in variants:
            measure(mode, 'prime', -1)
            reset(roots[mode])
            measure(mode, 'warmup', -1)
        for iteration in range(args.repeats):
            for mode in (['baseline', 'candidate'] if iteration % 2 == 0 else ['candidate', 'baseline']):
                root = roots[mode]
                reset(root)
                measure(mode, 'clean', iteration)
                measure(mode, 'noop', iteration)
                first = next(iter(inputs))
                (root / first).write_bytes(inputs[first] + f'\n// one-file {iteration}\n'.encode())
                measure(mode, 'one-file', iteration)
                for name, content in inputs.items():
                    (root / name).write_bytes(content + f'\n// broad {iteration}\n'.encode())
                measure(mode, 'broad', iteration)

    summary = []
    for fixture in metadata['fixtures']:
        for case in ['clean', 'noop', 'one-file', 'broad']:
            samples = {mode: [r['wall_seconds'] for r in records
                             if r['fixture'] == fixture and r['case'] == case and r['variant'] == mode]
                       for mode in variants}
            medians = {mode: statistics.median(values) for mode, values in samples.items()}
            spread = {mode: {'min': min(values), 'max': max(values),
                             'p25': statistics.quantiles(values, n=4)[0],
                             'p75': statistics.quantiles(values, n=4)[2]}
                      for mode, values in samples.items()} if args.repeats > 1 else {}
            # Pair by iteration, preserving alternating order instead of
            # inferring variation from independent medians alone.
            paired = [100 * (c / b - 1) for b, c in
                      zip(samples['baseline'], samples['candidate'])]
            summary.append(dict(fixture=fixture, case=case, **medians,
                                spread=spread, paired_change_median=statistics.median(paired),
                                change_percent=100 * (medians['candidate'] / medians['baseline'] - 1)))
    (results / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    (results / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
