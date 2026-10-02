#!/usr/bin/env python3
"""Alternate native builds of two revisions with warm, isolated tool caches."""

import argparse
import hashlib
import json
import os
from pathlib import Path
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
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--reuse-workspaces', action='store_true',
                        help='Rerun samples in previously prepared workspaces and caches')
    args = parser.parse_args()
    assert args.jobs > 0 and args.repeats > 0
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=args.reuse_workspaces)
    repo = args.candidate_root.resolve()
    variants = {
        'baseline': (args.baseline_root.resolve(), args.baseline_bin.resolve()),
        'candidate': (repo, args.candidate_bin.resolve()),
    }
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('BUILD_RUNNER_ACCELERATOR_')}
    env.update(BUILD_RUNNER_ACCELERATOR_METRICS='1',
               BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1')
    env.setdefault('PUB_CACHE', str(repo / '.pub-cache'))
    records = []
    metadata = {
        'jobs': args.jobs, 'repeats': args.repeats,
        'dart': subprocess.check_output([str(args.dart), '--version'], text=True).strip(),
        'scope': 'native frontend; warm SDK, pub, OS and tool caches; no Dart launcher',
        'variants': {}, 'fixtures': {},
    }
    for mode, (root, binary) in variants.items():
        metadata['variants'][mode] = {
            'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
            'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'rust_tree': subprocess.check_output(['git', 'rev-parse', 'HEAD:rust'], cwd=root, text=True).strip(),
            'lib_tree': subprocess.check_output(['git', 'rev-parse', 'HEAD:lib'], cwd=root, text=True).strip(),
        }
    baseline = metadata['variants']['baseline']
    candidate = metadata['variants']['candidate']
    # Dart-only worker changes legitimately use the same native binary.
    assert (baseline['binary_sha256'] != candidate['binary_sha256'] or
            (baseline['rust_tree'] == candidate['rust_tree'] and
             baseline['lib_tree'] != candidate['lib_tree'])), 'No distinct implementation to compare'

    def command(argv, root, log_path, run_env):
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
        return time.perf_counter() - start

    for fixture_name in ['json_serializable_10_app', 'freezed_app', 'riverpod_app']:
        fixture = repo / 'fixtures' / fixture_name
        config_path = fixture / '.dart_tool/package_config.json'
        config = json.loads(config_path.read_text())
        tracked = subprocess.check_output(
            ['git', 'ls-files', f'fixtures/{fixture_name}/lib'], cwd=repo, text=True).splitlines()
        inputs = {str(Path(p).relative_to(fixture.relative_to(repo))): (repo / p).read_bytes()
                  for p in tracked if not p.endswith(('.g.dart', '.freezed.dart', '.g.part'))}
        metadata['fixtures'][fixture_name] = {
            'pubspec_lock_sha256': hashlib.sha256((fixture / 'pubspec.lock').read_bytes()).hexdigest(),
            'analyzer_root': next(p['rootUri'] for p in config['packages'] if p['name'] == 'analyzer'),
        }

        def workspace(mode, package_root):
            root = results / fixture_name / mode
            if args.reuse_workspaces:
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
        if not args.reuse_workspaces:
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
            run_env = dict(env,
                           BUILD_RUNNER_ACCELERATOR_CACHE=str(results / f'{mode}-tool-cache'),
                           ANALYZER_STATE_LOCATION_OVERRIDE=str(results / f'{mode}-analyzer-cache'))
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
                          packed_bytes_before=packed_before, packed_bytes_after=packed_after,
                          command=argv, log=str(log_path), action_metrics=[])
            for line in text.splitlines():
                if line.startswith('Dart metrics: '):
                    record['action_metrics'].append(json.loads(line.removeprefix('Dart metrics: ')))
            if iteration >= 0:
                assert 'AOT cache miss' not in text, f'{log_path}: measured a cold worker'
                records.append(record)
                (results / 'measurements.json').write_text(json.dumps(records, indent=2))
            print(json.dumps({k: v for k, v in record.items()
                              if k not in ['action_metrics', 'command', 'log']}), flush=True)

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
            summary.append(dict(fixture=fixture, case=case, **medians,
                                change_percent=100 * (medians['candidate'] / medians['baseline'] - 1)))
    (results / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    (results / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
