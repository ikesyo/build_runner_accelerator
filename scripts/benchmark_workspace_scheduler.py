#!/usr/bin/env python3
"""Paired native scheduler experiment; stock is an untimed byte reference."""
import argparse
import hashlib
import json
import os
import platform
import re
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-bin', '--wave-bin', dest='baseline_bin', required=True, type=Path)
    parser.add_argument('--candidate-bin', '--ready-bin', dest='candidate_bin', required=True, type=Path)
    parser.add_argument('--results', required=True, type=Path)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--profiles', default='skew,balanced,inputs')
    parser.add_argument('--worker-mode', choices=['jit', 'aot'], default='jit')
    parser.add_argument('--diagnostics', action='store_true', help='Separate untimed worker/IPC diagnostics after each profile')
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
    binaries = {'baseline': args.baseline_bin.resolve(), 'candidate': args.candidate_bin.resolve()}
    assert all(path.is_file() for path in binaries.values())
    assert digest(binaries['baseline'].read_bytes()) != digest(binaries['candidate'].read_bytes())
    env = os.environ.copy()
    env.update(BUILD_RUNNER_ACCELERATOR_METRICS='0',
               BUILD_RUNNER_ACCELERATOR_WORKER_AOT='force' if args.worker_mode == 'aot' else '0',
               BUILD_RUNNER_ACCELERATOR_BYTE_STORE='1',
               BUILD_RUNNER_ACCELERATOR_CACHE=str(results / 'shared-native-cache'))
    for name in ['SCHEDULER_HISTORY', 'SCHEDULER_RENDEZVOUS', 'SCHEDULER_INPUT_RENDEZVOUS',
                 'SCHEDULER_CRASH', 'WALL_TRACE', 'BUILD_RUNNER_ACCELERATOR_WALL_TRACE',
                 'BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE', 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',
                 'BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL', 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_BACKGROUND_LOCK']:
        env.pop(name, None)
    profiles = {
        'skew': {'jobs': 2, 'delays': {'schedule_a': 200, 'schedule_b': 2000, 'schedule_c': 1800}},
        'balanced': {'jobs': 3, 'delays': {'schedule_a': 0}},
        'inputs': {'jobs': 3, 'delays': {'schedule_a': 200, **{
            f'schedule_a|lib/{name}.seed': 2000 for name in ['input', 'input_01', 'input_02']}}},
    }
    profiles['many'] = {'jobs': 3, 'delays': {'schedule_a': 0}, 'inputs': 120}
    profiles['single-balanced'] = {'jobs': 3, 'delays': {'schedule_a': 0}, 'inputs': 120, 'single': True}
    profiles['single-inputs'] = {**profiles['inputs'], 'single': True}
    # The reference is untimed; artificial fixture waits do not affect its
    # output bytes. Avoid paying those waits for every clean/broad reference.
    stock_delays = dict.fromkeys(['schedule_a', 'schedule_b', 'schedule_c'], 0)
    stock_extra = {'SCHEDULER_DELAYS': json.dumps(stock_delays)}
    requested = args.profiles.split(',')
    assert all(profile in profiles for profile in requested)
    records = []
    diagnostics = []
    metadata = {
        'dart': subprocess.check_output([str(dart), '--version'], text=True).strip(),
        'cargo': subprocess.check_output([str(cargo), '--version'], text=True).strip(),
        'platform': platform.system() + '/' + platform.machine(),
        'cpu_quota': Path('/sys/fs/cgroup/cpu.max').read_text().strip() if Path('/sys/fs/cgroup/cpu.max').exists() else None,
        'pub_cache': env.get('PUB_CACHE'), 'native_cache': env['BUILD_RUNNER_ACCELERATOR_CACHE'],
        'worker_mode': args.worker_mode.upper(), 'frontend_profile': 'release', 'metrics': False,
        'diagnostics_after_timing': args.diagnostics,
        'cache_definition': 'Untimed preparation of both implementations; retain compiler/analysis caches; clean removes native graph/generated artifacts only.',
        'stock_role': 'Untimed output reference with identical lockfiles and source bytes.',
        'stock_artificial_delays_ms': stock_delays,
        'binary_sha256': {name: digest(path.read_bytes()) for name, path in binaries.items()},
        'profiles': {name: profiles[name] for name in requested}, 'repeat': args.repeat,
        'fixture_builder_sha256': digest((repo / 'fixtures/workspace_scheduler_app/gen/lib/builder.dart').read_bytes()),
        'source_dart_sha256': digest(json.dumps({str(path.relative_to(repo)): digest(path.read_bytes())
            for directory in ['lib', 'tool'] for path in sorted((repo / directory).rglob('*.dart'))}, sort_keys=True).encode()),
        'source_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        'source_rust_sha256': digest(json.dumps({str(path.relative_to(repo)): digest(path.read_bytes())
            for path in sorted((repo / 'rust/src').rglob('*.rs'))}, sort_keys=True).encode()),
        'aot_artifacts': {},
    }
    (results / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')

    def run(command, root, log, extra=None, worker_executables=None):
        process_env = env.copy()
        process_env.update(extra or {})
        with log.open('w') as output:
            started = time.perf_counter()
            command = list(map(str, command))
            if worker_executables is None:
                subprocess.run(command, cwd=root, env=process_env,
                               stdout=output, stderr=subprocess.STDOUT, check=True, timeout=600)
            else:
                # Only instrument separate diagnostics. Observe the actual
                # builder processes, rather than inferring AOT from a counter.
                process = subprocess.Popen(command, cwd=root, env=process_env,
                                           stdout=output, stderr=subprocess.STDOUT)
                seen = set()
                try:
                    while process.poll() is None:
                        for path in Path(process_env['SCHEDULER_HISTORY']).glob('*-start.json'):
                            if path in seen:
                                continue
                            try:
                                pid = json.loads(path.read_text())['pid']
                            except (OSError, json.JSONDecodeError):
                                continue
                            seen.add(path)
                            try:
                                worker_executables[str(pid)] = os.readlink(f'/proc/{pid}/exe')
                            except OSError:
                                pass
                        if time.perf_counter() - started > 600:
                            raise subprocess.TimeoutExpired(command, 600)
                        time.sleep(0.01)
                    if process.returncode:
                        raise subprocess.CalledProcessError(process.returncode, command)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            return time.perf_counter() - started

    def inventory(root, stock=False, single=False):
        assets = {}
        for package in (['.'] if single else ['a', 'b', 'c', 'helper']):
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
        for variant in ['stock', 'baseline', 'candidate']:
            root = workspace / 'fixtures' / f'{profile_name}-{variant}'
            shutil.copytree(repo / 'fixtures/workspace_scheduler_app', root,
                            ignore=shutil.ignore_patterns('.dart_tool', '.cache'))
            single = settings.get('single', False)
            if single:
                subprocess.run(['python3', str(repo / 'scripts/prepare_single_scheduler_fixture.py'), str(root)], check=True)
            if profile_name == 'skew':
                (root / 'a/lib/second.seed').unlink()
            else:
                if not single:
                    for package in ['b', 'c']:
                        (root / package / 'lib/input.seed').unlink()
                for number in range(1, settings.get('inputs', 12) - 1):
                    (root / ('lib' if single else 'a/lib') / f'input_{number:02}.seed').write_text(f'input {number}\n')
            roots[variant] = root
            if single and variant != 'stock':
                shutil.copy2(roots['stock'] / 'pubspec.lock', root / 'pubspec.lock')
            pub_args = [] if single and variant == 'stock' else ['--enforce-lockfile']
            run([dart, '--suppress-analytics', 'pub', 'get', *pub_args], root,
                results / f'{profile_name}-{variant}-pub.log')
        locks = {(root / 'pubspec.lock').read_bytes() for root in roots.values()}
        assert len(locks) == 1, 'Dependency solutions differ'
        (results / f'{profile_name}.lock').write_bytes(next(iter(locks)))
        single = settings.get('single', False)
        execution_roots = roots
        stock_command = [dart, '--suppress-analytics', 'run', 'build_runner', 'build'] + ([] if single else ['--workspace'])
        commands = {variant: [binary, 'build', '--root', execution_roots[variant], '--dart', dart,
                             '--force-' + args.worker_mode, '--jobs', str(settings['jobs'])] + ([] if single else ['--workspace'])
                    for variant, binary in binaries.items()}
        extra = {'SCHEDULER_DELAYS': json.dumps(settings['delays'])}
        print(f'warming {profile_name}', flush=True)
        run(stock_command, execution_roots['stock'], results / f'{profile_name}-stock-warm.log', stock_extra)
        reference = inventory(roots['stock'], stock=True, single=single)
        for variant in binaries:
            run(commands[variant], roots[variant], results / f'{profile_name}-{variant}-warm.log', extra)
            assert inventory(roots[variant], single=single) == reference, f'{profile_name}/{variant} warm bytes differ'
            if args.worker_mode == 'aot':
                artifact = roots[variant] / '.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker'
                if os.name == 'nt':
                    artifact = artifact.with_suffix('.exe')
                assert artifact.is_file(), 'Forced-AOT warm build did not publish its executable'
                metadata['aot_artifacts'].setdefault(profile_name, {})[variant] = {
                    'path': str(artifact.resolve()), 'sha256': digest(artifact.read_bytes()),
                    'mtime_ns': artifact.stat().st_mtime_ns}
        (results / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
        for repeat in range(args.repeat):
            for case in ['clean', 'noop', 'one-file', 'broad']:
                for root in roots.values():
                    if case in ['clean', 'broad']:
                        for path in sorted(root.rglob('*.seed')):
                            path.write_text(f'{path.stem} repeat {repeat} case {case}\n')
                    elif case == 'one-file':
                        (root / ('lib/input.seed' if single else 'a/lib/input.seed')).write_text(f'input repeat {repeat} case edit\n')
                run(stock_command, execution_roots['stock'], results / f'{profile_name}-{repeat}-{case}-stock.log', stock_extra)
                reference = inventory(roots['stock'], stock=True, single=single)
                order = ['baseline', 'candidate'] if repeat % 2 == 0 else ['candidate', 'baseline']
                for variant in order:
                    if case == 'clean':
                        clean(execution_roots[variant])
                    graph = execution_roots[variant] / '.dart_tool/build_runner_accelerator/graph-v3.bin'
                    before = graph.read_bytes() if case == 'noop' else None
                    log = results / f'{profile_name}-{repeat}-{case}-{variant}.log'
                    elapsed = run(commands[variant], roots[variant], log, extra)
                    if args.worker_mode == 'aot':
                        artifact = metadata['aot_artifacts'][profile_name][variant]
                        assert Path(artifact['path']).stat().st_mtime_ns == artifact['mtime_ns'], 'Timed run rebuilt AOT worker'
                    actual = inventory(roots[variant], single=single)
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
        if args.diagnostics:
            for root in roots.values():
                for path in sorted(root.rglob('*.seed')):
                    path.write_text(f'{path.stem} untimed diagnostic edit\n')
            run(stock_command, execution_roots['stock'], results / f'{profile_name}-diagnostic-stock.log', stock_extra)
            reference = inventory(roots['stock'], stock=True, single=single)
            for variant in binaries:
                log = results / f'{profile_name}-diagnostic-{variant}.log'
                history = results / f'{profile_name}-history-{variant}'
                history.mkdir()
                worker_executables = {}
                diagnostic_seconds = run(commands[variant], roots[variant], log,
                    {**extra, 'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
                     'BUILD_RUNNER_ACCELERATOR_WALL_TRACE': '1', 'SCHEDULER_HISTORY': str(history)},
                    worker_executables)
                assert inventory(roots[variant], single=single) == reference, 'Diagnostic bytes differ'
                line = re.search(r'^Rust metrics: (.*)$', log.read_text(), re.MULTILINE)
                assert line, 'Missing diagnostic worker/IPC metrics'
                metrics = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line[1])}
                starts = [json.loads(path.read_text()) for path in history.glob('*-start.json')]
                if args.worker_mode == 'aot' and Path('/proc/self/exe').exists():
                    expected = metadata['aot_artifacts'][profile_name][variant]['path']
                    builder_pids = {str(row['pid']) for row in starts}
                    assert builder_pids and set(worker_executables) == builder_pids, 'AOT executable verification incomplete: missing builder PID observations'
                    assert worker_executables and all(path == expected for path in worker_executables.values()), 'Observed worker is not the warmed AOT executable'
                diagnostics.append({'profile': profile_name, 'variant': variant,
                    'stock_byte_identical': True, 'actions': len(starts), 'jobs': settings['jobs'],
                    'worker_pids': sorted({row['pid'] for row in starts}), 'metrics': metrics,
                    'instrumented_seconds': diagnostic_seconds,
                    'worker_executables': worker_executables})
                (results / 'diagnostics.json').write_text(json.dumps(diagnostics, indent=2) + '\n')
    summary = []
    for profile in requested:
        for case in ['clean', 'noop', 'one-file', 'broad']:
            row = {'profile': profile, 'case': case}
            for variant in binaries:
                values = [record['seconds'] for record in records
                          if record['profile'] == profile and record['case'] == case and record['variant'] == variant]
                row[variant] = {'median': statistics.median(values), 'min': min(values), 'max': max(values)}
            row['baseline_over_candidate'] = row['baseline']['median'] / row['candidate']['median']
            summary.append(row)
    (results / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == '__main__':
    main()
