#!/usr/bin/env python3
"""Paired native scheduler experiment; stock is an untimed byte reference."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wave-bin', required=True, type=Path)
    parser.add_argument('--ready-bin', required=True, type=Path)
    parser.add_argument('--results', required=True, type=Path)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--profiles', default='skew,balanced,inputs')
    args = parser.parse_args()
    assert args.repeat > 0
    repo = Path(__file__).resolve().parents[1]
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=True)
    workspace = results / 'workspace'
    assert not workspace.exists(), 'Use a fresh results directory'
    workspace.mkdir()
    shutil.copy2(repo / 'pubspec.yaml', workspace / 'pubspec.yaml')
    for name in ['lib', 'tool']:
        shutil.copytree(repo / name, workspace / name)
    (workspace / 'fixtures').mkdir()
    dart = Path(os.environ['DART_BIN']).resolve()
    cargo = Path(os.environ['CARGO_BIN']).absolute()
    binaries = {'wave': args.wave_bin.resolve(), 'ready': args.ready_bin.resolve()}
    assert all(path.is_file() for path in binaries.values())
    assert digest(binaries['wave'].read_bytes()) != digest(binaries['ready'].read_bytes())
    env = os.environ.copy()
    env.update(BUILD_RUNNER_ACCELERATOR_METRICS='0', BUILD_RUNNER_ACCELERATOR_WORKER_AOT='0',
               BUILD_RUNNER_ACCELERATOR_BYTE_STORE='1',
               BUILD_RUNNER_ACCELERATOR_CACHE=str(results / 'shared-native-cache'))
    for name in ['SCHEDULER_HISTORY', 'SCHEDULER_RENDEZVOUS', 'SCHEDULER_INPUT_RENDEZVOUS',
                 'SCHEDULER_CRASH', 'WALL_TRACE', 'BUILD_RUNNER_ACCELERATOR_WALL_TRACE',
                 'BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE']:
        env.pop(name, None)
    profiles = {
        'skew': {'jobs': 2, 'delays': {'schedule_a': 200, 'schedule_b': 2000, 'schedule_c': 1800}},
        'balanced': {'jobs': 3, 'delays': {'schedule_a': 0}},
        'inputs': {'jobs': 3, 'delays': {'schedule_a': 200, **{
            f'schedule_a|lib/{name}.seed': 2000 for name in ['input', 'input_01', 'input_02']}}},
    }
    requested = args.profiles.split(',')
    assert all(profile in profiles for profile in requested)
    records = []
    metadata = {
        'dart': subprocess.check_output([str(dart), '--version'], text=True).strip(),
        'cargo': subprocess.check_output([str(cargo), '--version'], text=True).strip(),
        'platform': platform.system() + '/' + platform.machine(),
        'cpu_quota': Path('/sys/fs/cgroup/cpu.max').read_text().strip() if Path('/sys/fs/cgroup/cpu.max').exists() else None,
        'pub_cache': env.get('PUB_CACHE'), 'native_cache': env['BUILD_RUNNER_ACCELERATOR_CACHE'],
        'worker_mode': 'JIT', 'frontend_profile': 'release', 'metrics': False,
        'cache_definition': 'Untimed preparation of both implementations; retain compiler/analysis caches; clean removes native graph/generated artifacts only.',
        'stock_role': 'Untimed output reference with identical lockfiles and source bytes.',
        'binary_sha256': {name: digest(path.read_bytes()) for name, path in binaries.items()},
        'profiles': {name: profiles[name] for name in requested}, 'repeat': args.repeat,
        'fixture_builder_sha256': digest((repo / 'fixtures/workspace_scheduler_app/gen/lib/builder.dart').read_bytes()),
        'source_dart_sha256': digest(json.dumps({str(path.relative_to(repo)): digest(path.read_bytes())
            for directory in ['lib', 'tool'] for path in sorted((repo / directory).rglob('*.dart'))}, sort_keys=True).encode()),
        'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        'source_rust_sha256': digest(json.dumps({str(path.relative_to(repo)): digest(path.read_bytes())
            for path in sorted((repo / 'rust/src').rglob('*.rs'))}, sort_keys=True).encode()),
    }
    (results / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')

    def run(command, root, log, extra=None):
        process_env = env.copy()
        process_env.update(extra or {})
        with log.open('w') as output:
            started = time.perf_counter()
            subprocess.run(list(map(str, command)), cwd=root, env=process_env,
                           stdout=output, stderr=subprocess.STDOUT, check=True, timeout=600)
            return time.perf_counter() - started

    def inventory(root, stock=False):
        assets = {}
        for package in ['a', 'b', 'c', 'helper']:
            for path in (root / package / 'lib').rglob('*.summary'):
                assets[f'source/{package}/{path.relative_to(root / package)}'] = digest(path.read_bytes())
        cache = root / ('.dart_tool/build/generated' if stock else '.dart_tool/build_runner_accelerator/cache')
        for path in cache.rglob('*.made.dart'):
            assets[f'cache/{path.relative_to(cache)}'] = digest(path.read_bytes())
        return assets

    def clean(root):
        state = root / '.dart_tool/build_runner_accelerator'
        assert not (state / 'graph-v3.commit-undo').exists(), 'Preserve pending recovery evidence'
        for name in ['graph-v3.bin', 'workspace-mode']:
            (state / name).unlink(missing_ok=True)
        shutil.rmtree(state / 'cache', ignore_errors=True)
        for path in root.rglob('*.summary'):
            path.unlink()

    for profile_name in requested:
        print(f'preparing {profile_name}', flush=True)
        settings = profiles[profile_name]
        roots = {}
        for variant in ['stock', 'wave', 'ready']:
            root = workspace / 'fixtures' / f'{profile_name}-{variant}'
            shutil.copytree(repo / 'fixtures/workspace_scheduler_app', root,
                            ignore=shutil.ignore_patterns('.dart_tool', '.cache'))
            if profile_name == 'skew':
                (root / 'a/lib/second.seed').unlink()
            else:
                for package in ['b', 'c']:
                    (root / package / 'lib/input.seed').unlink()
                for number in range(1, 11):
                    (root / f'a/lib/input_{number:02}.seed').write_text(f'input {number}\n')
            roots[variant] = root
            run([dart, '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'], root,
                results / f'{profile_name}-{variant}-pub.log')
        locks = {(root / 'pubspec.lock').read_bytes() for root in roots.values()}
        assert len(locks) == 1, 'Dependency solutions differ'
        (results / f'{profile_name}.lock').write_bytes(next(iter(locks)))
        stock_command = [dart, '--suppress-analytics', 'run', 'build_runner', 'build', '--workspace']
        commands = {variant: [binary, 'build', '--root', roots[variant], '--dart', dart,
                             '--workspace', '--force-jit', '--jobs', str(settings['jobs'])]
                    for variant, binary in binaries.items()}
        extra = {'SCHEDULER_DELAYS': json.dumps(settings['delays'])}
        print(f'warming {profile_name}', flush=True)
        run(stock_command, roots['stock'], results / f'{profile_name}-stock-warm.log')
        reference = inventory(roots['stock'], stock=True)
        for variant in binaries:
            run(commands[variant], roots[variant], results / f'{profile_name}-{variant}-warm.log', extra)
            assert inventory(roots[variant]) == reference, f'{profile_name}/{variant} warm bytes differ'
        for repeat in range(args.repeat):
            for case in ['clean', 'noop', 'one-file', 'broad']:
                for root in roots.values():
                    if case in ['clean', 'broad']:
                        for path in sorted(root.rglob('*.seed')):
                            path.write_text(f'{path.stem} repeat {repeat} case {case}\n')
                    elif case == 'one-file':
                        (root / 'a/lib/input.seed').write_text(f'input repeat {repeat} case edit\n')
                run(stock_command, roots['stock'], results / f'{profile_name}-{repeat}-{case}-stock.log')
                reference = inventory(roots['stock'], stock=True)
                order = ['wave', 'ready'] if repeat % 2 == 0 else ['ready', 'wave']
                for variant in order:
                    if case == 'clean':
                        clean(roots[variant])
                    graph = roots[variant] / '.dart_tool/build_runner_accelerator/graph-v3.bin'
                    before = graph.read_bytes() if case == 'noop' else None
                    log = results / f'{profile_name}-{repeat}-{case}-{variant}.log'
                    elapsed = run(commands[variant], roots[variant], log, extra)
                    actual = inventory(roots[variant])
                    assert actual == reference, f'{profile_name}/{variant}/{case} stock bytes differ'
                    if case == 'noop':
                        assert graph.read_bytes() == before, 'No-op changed graph'
                        assert 'No work to do (Rust frontend)' in log.read_text(), 'No-op ran actions'
                    record = {'profile': profile_name, 'repeat': repeat, 'case': case,
                              'variant': variant, 'jobs': settings['jobs'], 'seconds': elapsed,
                              'stock_byte_identical': True, 'inventory_sha256': digest(json.dumps(actual, sort_keys=True).encode()),
                              'command': list(map(str, commands[variant]))}
                    records.append(record)
                    (results / 'samples.json').write_text(json.dumps(records, indent=2) + '\n')
                    print(f'{profile_name}/{repeat}/{case}/{variant}: {elapsed:.3f}s stock-bytes=yes', flush=True)
    summary = []
    for profile in requested:
        for case in ['clean', 'noop', 'one-file', 'broad']:
            row = {'profile': profile, 'case': case}
            for variant in binaries:
                values = [record['seconds'] for record in records
                          if record['profile'] == profile and record['case'] == case and record['variant'] == variant]
                row[variant] = {'median': statistics.median(values), 'min': min(values), 'max': max(values)}
            row['wave_over_ready'] = row['wave']['median'] / row['ready']['median']
            summary.append(row)
    (results / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
