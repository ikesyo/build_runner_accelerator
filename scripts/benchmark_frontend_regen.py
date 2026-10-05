#!/usr/bin/env python3
"""Compare frontend regen in a disposable, prepared cycle fixture.

Before EVERY run, delete the whole fixture .dart_tool/build_runner_accelerator
and lib/*.g.dart / lib/*.freezed.dart. Retain all machine-wide caches and use
native default AOT restore/validation, without a worker pin. Pub resolution and
stock references must already exist. --launcher selects a separate invocation
route; --diagnostic compares only candidate instrumentation settings.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

from benchmark_shared_byte_store import wait_for_process


PREFIX = 'BUILD_RUNNER_ACCELERATOR_'
REMOVED_ENV = tuple(PREFIX + name for name in (
    'WORKER_AOT', 'WORKER_AOT_PATH', 'WORKER_KERNEL',
    'WORKER_AOT_BACKGROUND_LOCK', 'MANIFEST_WORKER_AOT', 'PLAN_ONLY', 'BIN',
))
# Explicit allowlist: never serialize the inherited environment or credentials.
SELECTED_ENV = tuple(PREFIX + name for name in (
    'CACHE', 'BIN', 'METRICS', 'WALL_TRACE', 'ANALYSIS_TRACE',
    'WORKER_AOT', 'WORKER_AOT_PATH', 'WORKER_KERNEL', 'PLAN_ONLY',
    'MANIFEST_SNAPSHOT', 'EARLY_CATALOG', 'COMPILE_PREWARM',
    'MANIFEST_PREWARM', 'ANALYSIS_PREWARM_JOBS', 'ANALYSIS_PREWARM_DIRS',
    'ANALYSIS_SINGLE_FLIGHT', 'PACKED_STORE',
)) + ('DART_SDK', 'PUB_CACHE', 'ANALYZER_STATE_LOCATION_OVERRIDE')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def overlaps(left, right):
    return left == right or left in right.parents or right in left.parents


def fixture_sources(root):
    """Require the complete cycle fixture outside any source checkout."""
    # Managed workspaces may expose a non-repository .git control directory.
    # Recognize actual repositories/worktrees rather than that directory alone.
    if any((parent / '.git').is_file() or (parent / '.git/HEAD').is_file()
           for parent in (root, *root.parents)):
        raise ValueError('fixture must be disposable and outside a Git checkout')
    for name in ('lib', '.dart_tool'):
        path = root / name
        if path.is_symlink() or not path.is_dir():
            raise ValueError(f'requires a real fixture directory: {path}')
    expected = {f'provider_{n:02}.dart' for n in range(64)}
    expected.update(f'shared_{n}{suffix}.dart'
                    for n in range(8) for suffix in ('', '_io'))
    expected.update(f'transitive_{n}_{depth}{suffix}.dart'
                    for n in range(8) for depth in range(8)
                    for suffix in ('', '_io'))
    paths = [p for p in (root / 'lib').glob('*.dart')
             if not p.name.endswith(('.g.dart', '.freezed.dart'))]
    if {p.name for p in paths} != expected:
        raise ValueError('requires exactly 64 provider and 144 shared cycle sources')
    for path in paths:
        if path.is_symlink() or not path.is_file() or not path.stat().st_size:
            raise ValueError(f'invalid cycle source: {path}')
        if path.name.startswith('provider_'):
            content = path.read_text()
            if not all(marker in content for marker in (
                    '@riverpod', '@freezed', '@JsonSerializable()',
                    "if (dart.library.io) 'shared_0_io.dart'")):
                raise ValueError(f'not a mixed-generator cycle source: {path}')
    for name in ('pubspec.yaml', 'pubspec.lock', 'build.yaml',
                 '.dart_tool/package_config.json'):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'missing prepared fixture file: {path}')
    if not re.search(r'^publish_to:\s*none\s*$',
                     (root / 'pubspec.yaml').read_text(), re.MULTILINE):
        raise ValueError('requires a disposable publish_to: none fixture')
    config = json.loads((root / '.dart_tool/package_config.json').read_text())
    names = {p['name'] for p in config['packages']}
    if not {'build_runner_accelerator', 'riverpod_generator', 'freezed',
            'json_serializable'} <= names:
        raise ValueError('fixture dependencies have not been resolved')
    return {str(p.relative_to(root)): sha256(p) for p in paths}


def regen_cleanup(root):
    """Check every deletion target first; never follow a fixture symlink."""
    state = root / '.dart_tool/build_runner_accelerator'
    outputs = list((root / 'lib').glob('*.g.dart'))
    outputs += list((root / 'lib').glob('*.freezed.dart'))
    if state.is_symlink() or (state.exists() and not state.is_dir()):
        raise ValueError(f'unsafe accelerator directory: {state}')
    for path in outputs:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'unsafe generated output: {path}')
    if state.exists():
        shutil.rmtree(state)
    for path in outputs:
        path.unlink()


def output_hashes(root):
    paths = list((root / 'lib').glob('*.g.dart'))
    paths += list((root / 'lib').glob('*.freezed.dart'))
    cache = root / '.dart_tool/build_runner_accelerator/cache'
    return {**{str(p.relative_to(root)): sha256(p) for p in paths},
            **{'cache/' + str(p.relative_to(cache)): sha256(p)
               for p in cache.rglob('*.g.part')}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path,
                        help='Baseline release binary; required except in diagnostic mode')
    for name in ('candidate', 'dart', 'root', 'cache', 'results', 'stock-reference'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--candidate-scheduler', choices=('static', 'tail', 'tail2', 'queue'), default='static')
    parser.add_argument('--wall-trace', action='store_true', help='Separate paired wall-only diagnostics')
    parser.add_argument('--jobs', type=int, nargs='+', default=[2, 4])
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--launcher', action='store_true',
                        help='Measure dart run launcher instead of direct native execution')
    parser.add_argument('--diagnostic', action='store_true',
                        help='Candidate only: disabled, wall-only, wall+metrics; trace stays off')
    args = parser.parse_args()
    if not args.diagnostic and args.baseline is None:
        parser.error('--baseline is required for speed comparisons')
    if args.repeats < 1 or any(j < 1 for j in args.jobs):
        parser.error('--repeats and --jobs must be positive')
    if len(set(args.jobs)) != len(args.jobs):
        parser.error('--jobs must not contain duplicates')
    for name in ('baseline', 'candidate', 'dart', 'root', 'cache', 'results',
                 'stock_reference'):
        path = getattr(args, name)
        if path is not None:
            setattr(args, name, path.resolve())
    state = args.root / '.dart_tool/build_runner_accelerator'
    worker = state / 'aot-sdk/bin/dynamic_worker'
    worker_source = state / 'dynamic_worker.dart'
    config_path = args.root / '.dart_tool/package_config.json'
    binaries = {'candidate': args.candidate}
    if not args.diagnostic:
        binaries['baseline'] = args.baseline
    try:
        for left, right in ((args.root, args.cache), (args.root, args.results),
                            (args.cache, args.results)):
            if overlaps(left, right):
                raise ValueError('root, cache and results must be disjoint (no ancestors)')
        for path in (*binaries.values(), args.dart, args.stock_reference):
            if not path.is_file() or overlaps(path, state) or overlaps(path, args.root / 'lib'):
                raise ValueError(f'missing or unsafe input: {path}')
        if any(not os.access(p, os.X_OK) for p in (*binaries.values(), args.dart)):
            raise ValueError('Dart and native binaries must be executable')
        sources = fixture_sources(args.root)
        if not worker.is_file() or not worker_source.is_file():
            raise ValueError('requires a prepared AOT worker and dynamic_worker.dart')
        expected = json.loads(args.stock_reference.read_text())['cold']
        expected_source_names = {f'lib/provider_{n:02}.{suffix}.dart'
                                 for n in range(64) for suffix in ('g', 'freezed')}
        if (not isinstance(expected, dict) or len(expected) != 256
                or {k for k in expected if k.startswith('lib/')} != expected_source_names
                or sum(k.startswith('cache/') and k.endswith('.g.part') for k in expected) != 128
                or any(not isinstance(v, str) or not re.fullmatch('[0-9a-f]{64}', v)
                       for v in expected.values())):
            raise ValueError('stock cold reference must contain all 256 cycle output hashes')
        worker_hash, worker_source_hash = sha256(worker), sha256(worker_source)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.error(str(error))

    environment = dict(os.environ)
    for name in REMOVED_ENV:
        environment.pop(name, None)
    environment.update({PREFIX + 'CACHE': str(args.cache),
                        PREFIX + 'METRICS': '0', PREFIX + 'WALL_TRACE': str(int(args.wall_trace)),
                        PREFIX + 'ANALYSIS_TRACE': '0'})
    route = 'launcher' if args.launcher else 'native'
    mode = 'diagnostic' if args.diagnostic else 'wall-only' if args.wall_trace else 'speed'
    args.results.mkdir(parents=True, exist_ok=True)
    if any(args.results.iterdir()):
        parser.error('--results must be empty to preserve previous samples/logs')
    protected = {str(p): sha256(p) for p in (
        config_path, args.root / 'pubspec.yaml', args.root / 'pubspec.lock',
        args.root / 'build.yaml', args.stock_reference, *binaries.values(), args.dart)}
    metadata = dict(
        candidate_scheduler=args.candidate_scheduler, wall_trace=args.wall_trace,
        route=route, mode=mode, root=str(args.root), cache=str(args.cache),
        jobs=args.jobs, repeats=args.repeats, timeout_s=300,
        sdk=subprocess.check_output([str(args.dart), '--version'], env=environment,
                                    text=True, timeout=30).strip(),
        dart=str(args.dart), binaries={k: str(v) for k, v in binaries.items()},
        binary_sha256={k: sha256(v) for k, v in binaries.items()},
        dart_sha256=sha256(args.dart), worker=str(worker), worker_sha256=worker_hash,
        worker_source_sha256=worker_source_hash, source_sha256=sources,
        protected_sha256=protected, stock_reference=str(args.stock_reference),
        selected_environment={k: environment.get(k) for k in SELECTED_ENV},
        cleanup=['.dart_tool/build_runner_accelerator', 'lib/*.g.dart', 'lib/*.freezed.dart'],
        machine_wide_caches='retained', os_page_cache='not flushed',
        aot_policy='native default; no worker pin; restore/validation included',
        timing='perf_counter around subprocess spawn, wait and log flush/close; cleanup excluded')
    if environment.get('DART_SDK'):
        sdk_root = Path(environment['DART_SDK']).resolve()
        metadata['sdk_root'] = str(sdk_root)
        metadata['sdk_binary_sha256'] = {
            str(p.relative_to(sdk_root)): sha256(p)
            for p in (sdk_root / 'bin/dart', sdk_root / 'bin/utils/gen_snapshot')
            if p.is_file()}
    write_json(args.results / 'metadata.json', metadata)
    records = []
    for jobs in args.jobs:
        for repeat in range(args.repeats):
            if args.diagnostic:
                settings = ['disabled', 'wall-only', 'wall+metrics']
                shift = repeat % len(settings)
                order = settings[shift:] + settings[:shift]
                if repeat % 2:
                    order.reverse()
            else:
                order = ['baseline', 'candidate']
                if repeat % 2:
                    order.reverse()
            for position, lane in enumerate(order):
                # Validate unchanged inputs and fixture topology before each deletion.
                if fixture_sources(args.root) != sources:
                    raise ValueError('cycle fixture sources changed during comparison')
                for name, digest in protected.items():
                    if sha256(Path(name)) != digest:
                        raise ValueError(f'comparison input changed: {name}')
                regen_cleanup(args.root)
                binary = args.candidate if args.diagnostic else binaries[lane]
                run_env = dict(environment)
                run_env[PREFIX + 'BATCH_SCHEDULER'] = (
                    args.candidate_scheduler if args.diagnostic or lane == 'candidate' else 'static')
                if args.diagnostic:
                    run_env[PREFIX + 'WALL_TRACE'] = str(int(lane != 'disabled'))
                    run_env[PREFIX + 'METRICS'] = str(int(lane == 'wall+metrics'))
                if args.launcher:
                    run_env[PREFIX + 'BIN'] = str(binary)
                    command = [str(args.dart), 'run', 'build_runner_accelerator', 'build',
                               '--mode', 'rust', '--jobs', str(jobs), '--dart', str(args.dart)]
                else:
                    command = [str(binary), 'build', '--root', str(args.root),
                               '--dart', str(args.dart), '--mode', 'rust', '--jobs', str(jobs)]
                log = args.results / f'{route}-{jobs}-{repeat}-{lane}.log'
                row = dict(route=route, mode=mode, case='regen', jobs=jobs, repeat=repeat,
                           lane=lane, position=position, order=order, command=command,
                           cwd=str(args.root), log=str(log), binary_sha256=sha256(binary),
                           selected_environment={k: run_env.get(k) for k in SELECTED_ENV})
                error = None
                usage = None
                with log.open('w') as stream:
                    start = time.perf_counter()
                    try:
                        process = subprocess.Popen(command, cwd=args.root, env=run_env,
                                                   stdout=stream, stderr=stream,
                                                   start_new_session=True)
                        usage = wait_for_process(process, 300)
                        row['returncode'] = process.returncode
                        if process.returncode:
                            raise subprocess.CalledProcessError(process.returncode, command)
                    except Exception as exc:
                        error = exc
                    finally:
                        stream.flush()
                row['wall_s'] = time.perf_counter() - start
                if usage is not None:
                    row.update(cpu_s=usage.ru_utime + usage.ru_stime,
                               max_process_rss_kib=usage.ru_maxrss)
                try:
                    if error is not None:
                        raise error
                    if 'Rust manifest snapshot unavailable' in log.read_text():
                        raise ValueError(f'{log}: manifest snapshot fallback invalidates default-route comparison')
                    hashes = output_hashes(args.root)
                    row.update(output_sha256=hashes, output_count=len(hashes),
                               worker_sha256=sha256(worker),
                               worker_source_sha256=sha256(worker_source))
                    if hashes != expected:
                        raise ValueError(f'{log}: generated outputs differ from stock cold reference')
                    if (row['worker_sha256'] != worker_hash
                            or row['worker_source_sha256'] != worker_source_hash):
                        raise ValueError(f'{log}: worker hash differs from the prepared worker')
                    if fixture_sources(args.root) != sources:
                        raise ValueError(f'{log}: cycle sources changed')
                    for name, digest in protected.items():
                        if sha256(Path(name)) != digest:
                            raise ValueError(f'{log}: comparison input changed: {name}')
                    row['validated'] = True
                except Exception as exc:
                    row.update(validated=False, error=str(exc))
                    error = exc
                records.append(row)
                write_json(args.results / 'builds.json', records)
                if error is not None:
                    raise error
                print(route, jobs, repeat, lane, round(row['wall_s'], 4), flush=True)
    summary = []
    for jobs in args.jobs:
        for lane in order:
            values = [r['wall_s'] for r in records if r['jobs'] == jobs and r['lane'] == lane]
            summary.append(dict(route=route, mode=mode, case='regen', jobs=jobs, lane=lane,
                                count=len(values), samples=values,
                                median_s=statistics.median(values),
                                min_s=min(values), max_s=max(values)))
    write_json(args.results / 'summary.json', summary)


if __name__ == '__main__':
    main()
