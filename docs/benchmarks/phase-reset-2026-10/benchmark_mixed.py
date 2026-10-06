#!/usr/bin/env python3
"""Disposable cycle fixture plus generic non-resolver and post-process phases.

Default runs trace-disabled cold/no-op/one-file/broad/regen comparisons.
--wall is a separate regen-only diagnostic, never a speed comparison.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / 'scripts'))
from benchmark_frontend_regen import overlaps, regen_cleanup
from benchmark_shared_byte_store import clear_graph, wait_for_process
from summarize_frontend_wall import summarize


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def outputs(root, stock=False):
    result = {}
    for suffix in ('*.g.dart', '*.freezed.dart', '*.probe', '*.probe.post'):
        for path in (root / 'lib').glob(suffix):
            result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    cache = root / ('.dart_tool/build/generated' if stock else
                    '.dart_tool/build_runner_accelerator/cache')
    for path in cache.rglob('*.g.part'):
        result['cache/' + str(path.relative_to(cache))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'candidate', 'dart', 'root', 'cache', 'results'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--wall', action='store_true')
    parser.add_argument('--metrics', action='store_true')
    parser.add_argument('--stock-reference', type=Path)
    args = parser.parse_args()
    for name in ('baseline', 'candidate', 'dart', 'root', 'cache', 'results'):
        setattr(args, name, getattr(args, name).resolve())
    if args.wall and not args.stock_reference:
        parser.error('--wall requires the prior speed run --stock-reference')
    if args.repeats < 1 or (args.metrics and not args.wall):
        parser.error('positive repeats required; metrics requires --wall')
    for left, right in ((args.root, args.cache), (args.root, args.results),
                        (args.cache, args.results), (args.root, REPO)):
        if overlaps(left, right):
            parser.error('fixture, cache, results and repository must be disjoint')
    args.results.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache),
               BUILD_RUNNER_ACCELERATOR_METRICS='0', BUILD_RUNNER_ACCELERATOR_WALL_TRACE='0',
               BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE='0')
    for key in ('WORKER_AOT', 'WORKER_AOT_PATH', 'WORKER_KERNEL', 'ANALYSIS_SINGLE_FLIGHT'):
        env.pop('BUILD_RUNNER_ACCELERATOR_' + key, None)
    if not args.root.exists():
        subprocess.run([sys.executable, str(REPO / 'scripts/prepare_cycle_read_fixture.py'),
                        '--root', str(args.root)], check=True, timeout=300)
        shutil.copy2(HERE / 'probe_builder.dart', args.root / 'lib/reset_probe_builder.dart')
        config = args.root / 'build.yaml'
        config.write_text(config.read_text() + '''
      riverpod_app:overlay_probe:
        generate_for: [lib/*.g.dart]
      riverpod_app:probe_post:
        generate_for: [lib/*.probe]
builders:
  overlay_probe:
    import: package:riverpod_app/reset_probe_builder.dart
    builder_factories: [overlayProbe]
    build_extensions: {".g.dart": [".probe"]}
    required_inputs: [".g.dart"]
    auto_apply: none
    build_to: source
post_process_builders:
  probe_post:
    import: package:riverpod_app/reset_probe_builder.dart
    builder_factory: probePost
    input_extensions: [".probe"]
    build_to: source
''')
        subprocess.run([str(args.dart), 'pub', 'get', '--offline'], cwd=args.root,
                       env=env, check=True, timeout=300)
    if (args.root / 'lib/reset_probe_builder.dart').read_bytes() != (HERE / 'probe_builder.dart').read_bytes():
        parser.error('requires the exact disposable probe fixture')
    sources = {p: p.read_bytes() for p in sorted((args.root / 'lib').glob('provider_??.dart'))}
    if len(sources) != 64:
        parser.error('requires 64 cycle providers')

    def restore(case='cold'):
        for index, (path, content) in enumerate(sources.items()):
            if case == 'broad' or (case == 'one-file' and index == 0):
                content = re.sub(rb'\banswer[0-9]+\b', lambda m: m[0] +
                                 (b'Broad' if case == 'broad' else b'Edited'), content)
            path.write_bytes(content)

    command = lambda binary, jobs: [str(binary), 'build', '--root', str(args.root),
                                   '--dart', str(args.dart), '--mode', 'rust', '--jobs', str(jobs)]
    # AOT, SDK summary and manifest priming are outside every speed sample.
    with (args.results / 'prime.log').open('w') as log:
        subprocess.run(command(args.baseline, 2), cwd=args.root, env=env, check=True,
                       stdout=log, stderr=log, timeout=300)
    if args.stock_reference:
        expected = json.loads(args.stock_reference.read_text())
        for case in ('cold', 'one-file', 'broad'):
            if len(expected[case]) != 384:
                parser.error('requires all 384 stock output hashes per case')
    else:
        stock = args.results / 'stock'
        stock.mkdir()
        for name in ('lib', 'pubspec.yaml', 'pubspec.lock', 'build.yaml'):
            path = args.root / name
            if path.is_dir():
                shutil.copytree(path, stock / name)
            else:
                shutil.copy2(path, stock / name)
        # Post-process outputs have no declared mapping for stock to remove with
        # --delete-conflicting-outputs. Start its reference from sources only.
        for suffix in ('*.g.dart', '*.freezed.dart', '*.probe', '*.probe.post'):
            for path in (stock / 'lib').glob(suffix):
                path.unlink()
        package_config = json.loads((args.root / '.dart_tool/package_config.json').read_text())
        for package in package_config['packages']:
            if package['name'] == 'riverpod_app':
                package['rootUri'] = stock.as_uri() + '/'
        (stock / '.dart_tool').mkdir()
        write_json(stock / '.dart_tool/package_config.json', package_config)
        expected = {}
        for case in ('cold', 'one-file', 'broad'):
            restore(case)
            for path in sources:
                shutil.copy2(path, stock / 'lib' / path.name)
            with (args.results / f'stock-{case}.log').open('w') as log:
                subprocess.run([str(args.dart), 'run', 'build_runner', 'build', '--delete-conflicting-outputs'],
                               cwd=stock, env=env, check=True, stdout=log, stderr=log, timeout=300)
            expected[case] = outputs(stock, True)
            if len(expected[case]) != 384:
                raise RuntimeError(f'expected 384 stock source/cache outputs: {case}')
    expected['no-op'] = expected['regen'] = expected['cold']
    write_json(args.results / 'stock-outputs.json', expected)
    restore()
    worker = args.root / '.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker'
    worker_hash = hashlib.sha256(worker.read_bytes()).hexdigest()
    write_json(args.results / 'metadata.json', dict(
        sdk=subprocess.check_output([str(args.dart), '--version'], text=True, timeout=300).strip(),
        jobs=[2, 4], repeats=args.repeats, wall=args.wall, metrics=args.metrics,
        stock_reference_sha256=hashlib.sha256(args.stock_reference.read_bytes()).hexdigest()
        if args.stock_reference else None,
        binary_sha256={lane: hashlib.sha256(getattr(args, lane).read_bytes()).hexdigest()
                       for lane in ('baseline', 'candidate')}, worker_sha256=worker_hash,
        inputs={str(p.relative_to(args.root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (*sources, args.root / 'build.yaml', args.root / 'pubspec.lock',
                          args.root / 'lib/reset_probe_builder.dart')},
        cache=str(args.cache), cold='clear byte_store/dep_parse; retain prepared AOT/SDK summaries',
        regen='remove workspace accelerator state and all source outputs; retain shared caches'))
    rows = []
    try:
        for jobs in (2, 4):
            for repeat in range(args.repeats):
                for lane in (('baseline', 'candidate') if repeat % 2 == 0 else ('candidate', 'baseline')):
                    for case in (('regen',) if args.wall else ('cold', 'no-op', 'one-file', 'broad', 'regen')):
                        restore(case)
                        if case in ('cold', 'regen'):
                            if case == 'regen':
                                regen_cleanup(args.root)
                            else:
                                clear_graph(args.root)
                                for name in ('byte_store', 'dep_parse'):
                                    shutil.rmtree(args.cache / name, ignore_errors=True)
                            for suffix in ('*.freezed.dart', '*.probe', '*.probe.post'):
                                for path in (args.root / 'lib').glob(suffix):
                                    path.unlink()
                        path = args.results / f'{jobs}-{repeat}-{lane}-{case}.log'
                        run_env = dict(env, BUILD_RUNNER_ACCELERATOR_WALL_TRACE=str(int(args.wall)),
                                       BUILD_RUNNER_ACCELERATOR_METRICS=str(int(args.metrics)),
                                       BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=str(int(args.metrics)))
                        start = time.perf_counter()
                        with path.open('w') as log:
                            process = subprocess.Popen(command(getattr(args, lane), jobs), cwd=args.root,
                                                       env=run_env, stdout=log, stderr=log, start_new_session=True)
                            usage = wait_for_process(process, 300)
                        elapsed = time.perf_counter() - start
                        if process.returncode or outputs(args.root) != expected[case]:
                            raise RuntimeError(f'failed build/output mismatch: {path}')
                        if hashlib.sha256(worker.read_bytes()).hexdigest() != worker_hash:
                            raise RuntimeError('worker changed between lanes')
                        if case in ('one-file', 'broad') and expected[case] == expected['cold']:
                            raise RuntimeError('edit did not change generated bytes')
                        row = dict(jobs=jobs, repeat=repeat, lane=lane, case=case, wall_s=elapsed,
                                   cpu_s=usage.ru_utime + usage.ru_stime, max_process_rss_kib=usage.ru_maxrss,
                                   output_bytes_match=True, command=command(getattr(args, lane), jobs))
                        if args.wall:
                            with path.open() as log:
                                row['session'] = summarize(log)['sessions'][0]
                        rows.append(row)
                        write_json(args.results / 'samples.json', rows)
                        print(jobs, repeat, lane, case, round(elapsed, 4), flush=True)
    finally:
        restore()


if __name__ == '__main__':
    main()
