#!/usr/bin/env python3
"""Small stock/main/candidate phase-growth check and Linux process-tree benchmark.

Uses one disposable path and prepared AOT/SDK caches for both native lanes.
Metrics/trace runs are separate from speed runs. Raw logs stay outside the repo.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

REPO = Path(__file__).resolve().parents[1]


def snapshot(root, stock=False):
    paths = list((root / 'lib').glob('*.ready.dart*'))
    cache = root / ('.dart_tool/build/generated' if stock else '.dart_tool/build_runner_accelerator/cache')
    paths += list(cache.rglob('*.cache.dart'))
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def run(command, root, env, log, expected_success=True):
    # RUSAGE_CHILDREN CPU includes waited descendants; RSS is a single-process
    # maximum. Separately sample simultaneous descendant RSS, without equating
    # it to PSS/private memory (shared pages are counted in each process).
    import resource
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    peak_tree = 0
    with log.open('w') as output:
        child = subprocess.Popen(command, cwd=root, env=env, stdout=output, stderr=output)
        while child.poll() is None:
            records = {}
            for proc in Path('/proc').glob('[0-9]*/stat'):
                try:
                    fields = proc.read_text().rsplit(')', 1)[1].split()
                    records[int(proc.parent.name)] = (int(fields[1]), int(fields[21]) * os.sysconf('SC_PAGE_SIZE'))
                except (OSError, ValueError, IndexError):
                    pass
            descendants = {child.pid}
            while True:
                found = {pid for pid, (parent, _) in records.items() if parent in descendants}
                if found <= descendants:
                    break
                descendants |= found
            peak_tree = max(peak_tree, sum(records[p][1] for p in descendants if p in records))
            if time.monotonic() - start > 300:
                child.kill()
                child.wait()
                raise TimeoutError(log)
            time.sleep(.02)
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    if (child.returncode == 0) != expected_success:
        raise RuntimeError(f'build exit {child.returncode}: {log}')
    return dict(wall_s=time.monotonic() - start,
                cpu_s=usage.ru_utime + usage.ru_stime - before.ru_utime - before.ru_stime,
                sampled_tree_rss_mib=peak_tree / 1048576)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'candidate', 'dart', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, nargs='+', default=[1, 2, 4])
    parser.add_argument('--cap', default='default')
    parser.add_argument('--shared-cache', choices=['0', '1'], default='1')
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--metrics', action='store_true')
    parser.add_argument('--reuse-fixture', type=Path, help='reuse a completed run\'s app and stock reference')
    args = parser.parse_args()
    if args.repeats < 1 or min(args.jobs) < 1:
        parser.error('positive repeats and jobs are required')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    root = args.reuse_fixture.resolve() if args.reuse_fixture else args.output / 'app'
    if args.reuse_fixture and not (root / 'pubspec.yaml').read_text().startswith('name: phase_worker_growth\n'):
        parser.error('--reuse-fixture must refer to this script\'s disposable app')
    memory_limit = Path('/sys/fs/cgroup/memory.max').read_text().strip()
    memory_current = int(Path('/sys/fs/cgroup/memory.current').read_text())
    meminfo = Path('/proc/meminfo').read_text()
    available = int(re.search(r'MemAvailable:\s+(\d+)', meminfo)[1]) * 1024
    if memory_limit != 'max':
        available = min(available, int(memory_limit) - memory_current)
    if not args.reuse_fixture:
        prepare_fixture(root)
    env = dict(os.environ, PUB_CACHE=str(REPO / '.pub-cache'),
               BUILD_RUNNER_ACCELERATOR_CACHE=str(root.parent / 'cache'),
               BUILD_RUNNER_ACCELERATOR_BYTE_STORE=args.shared_cache,
               BUILD_RUNNER_ACCELERATOR_METRICS='0', BUILD_RUNNER_ACCELERATOR_WALL_TRACE='0')
    if args.cap == 'default':
        env.pop('BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP', None)
    else:
        env['BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP'] = args.cap
    dart = str(args.dart.resolve())
    if not args.reuse_fixture:
        with (args.output / 'pub.log').open('w') as log:
            subprocess.run([dart, 'pub', 'get', '--offline'], cwd=root, env=env, check=True,
                           stdout=log, stderr=subprocess.STDOUT)

    def restore(case):
        for index in range(8):
            edit = 'Edited' if case == 'broad' or (case == 'one-file' and index == 0) else ''
            marker = '// OMIT\n' if case == 'delete' and index == 0 else ''
            if case == 'failure' and index == 0:
                marker = '// FAIL\n'
            (root / f'lib/input_{index}.seed.dart').write_text(f'class Input{index}{edit} {{}}\n{marker}')

    def clean():
        for path in (root / 'lib').glob('*.ready.dart*'):
            path.unlink()
        for name in ('build', 'build_runner_accelerator'):
            shutil.rmtree(root / '.dart_tool' / name, ignore_errors=True)

    reference = root.parent / 'stock-outputs.json'
    if args.reuse_fixture and reference.exists():
        expected = json.loads(reference.read_text())
    else:
        for path in (root / 'lib').glob('*.ready.dart*'):
            path.unlink()
        expected = {}
        stock = [dart, 'run', 'build_runner', 'build', '--delete-conflicting-outputs']
        restore('clean')
        for case in ('clean', 'no-op', 'one-file', 'broad', 'delete'):
            if case != 'no-op':
                restore(case)
            run(stock, root, env, args.output / f'stock-{case}.log')
            expected[case] = snapshot(root, True)
        if expected['one-file'] == expected['clean'] or expected['broad'] == expected['clean']:
            raise RuntimeError('edits did not change output')
        reference.write_text(json.dumps(expected, indent=2))
        if not args.reuse_fixture:
            clean()
    native = lambda binary, jobs: [str(binary.resolve()), 'build', '--root', str(root), '--dart', dart,
                                   '--mode', 'rust', '--jobs', str(jobs)]
    if not args.reuse_fixture:
        restore('clean')
        run(native(args.baseline, 1), root, env, args.output / 'prime.log')

    def native_clean():
        for path in (root / 'lib').glob('*.ready.dart*'):
            path.unlink()
        state = root / '.dart_tool/build_runner_accelerator'
        for name in ('graph-v3.bin', 'cache'):
            path = state / name
            if path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()

    rows = []
    for jobs in args.jobs:
        for repeat in range(args.repeats):
            lanes = ('baseline', 'candidate') if repeat % 2 == 0 else ('candidate', 'baseline')
            for lane in lanes:
                native_clean()
                for name in ('byte_store', 'dep_parse'):
                    shutil.rmtree(root.parent / 'cache' / name, ignore_errors=True)
                for case in ('clean', 'no-op', 'one-file', 'broad', 'failure', 'recovery', 'delete'):
                    if case != 'no-op':
                        restore('clean' if case == 'recovery' else case)
                    before_outputs = snapshot(root)
                    graph = root / '.dart_tool/build_runner_accelerator/graph-v3.bin'
                    before_graph = graph.read_bytes() if graph.exists() else None
                    log = args.output / f'{jobs}-{repeat}-{lane}-{case}.log'
                    run_env = dict(env, BUILD_RUNNER_ACCELERATOR_METRICS=str(int(args.metrics)),
                                   BUILD_RUNNER_ACCELERATOR_WALL_TRACE=str(int(args.metrics)))
                    row = run(native(getattr(args, lane), jobs), root, run_env, log, case != 'failure')
                    if case == 'failure':
                        if snapshot(root) != before_outputs or graph.read_bytes() != before_graph:
                            raise RuntimeError(f'failure committed transaction: {log}')
                    elif snapshot(root) != expected['clean' if case == 'recovery' else case]:
                        raise RuntimeError(f'output mismatch: {log}')
                    text = log.read_text()
                    rows.append(dict(row, jobs=jobs, repeat=repeat, lane=lane, case=case,
                                     metrics=re.findall(r'Rust (?:metrics: workers_active|phase workers:).*', text),
                                     command=native(getattr(args, lane), jobs)))
                    (args.output / 'samples.json').write_text(json.dumps(rows, indent=2))
                    print(jobs, repeat, lane, case, round(row['wall_s'], 3), flush=True)
    (args.output / 'metadata.json').write_text(json.dumps(dict(
        sdk=subprocess.check_output([dart, '--version'], text=True).strip(),
        quota=Path('/sys/fs/cgroup/cpu.max').read_text().strip(),
        memory_limit=memory_limit, memory_current_at_start=memory_current,
        available_memory_bytes_at_start=available, meminfo_at_start=meminfo,
        cap=args.cap, shared_cache=args.shared_cache,
        repeats=args.repeats, jobs=args.jobs,
        binaries={lane: hashlib.sha256(getattr(args, lane).read_bytes()).hexdigest()
                  for lane in ('baseline', 'candidate')},
        builder_sha256=hashlib.sha256((root / 'lib/builder.dart').read_bytes()).hexdigest(),
        cache_condition='prepared worker AOT/SDK summary; clear byte_store/dep_parse per clean series',
        metrics=args.metrics, outputs_match_stock=True), indent=2))


def prepare_fixture(root):
    (root / 'lib').mkdir(parents=True)
    (root / 'pubspec.yaml').write_text(f'''name: phase_worker_growth
publish_to: none
environment:
  sdk: ">=3.13.0 <4.0.0"
dependencies:
  build: 4.0.10
dev_dependencies:
  build_runner: 2.16.1
  build_runner_accelerator:
    path: {REPO}
''')
    shutil.copy2(REPO / 'fixtures/arbitrary_builder_app/pubspec.lock', root / 'pubspec.lock')
    shutil.copy2(REPO / 'scripts/fixtures/phase_worker_growth_builder.dart', root / 'lib/builder.dart')
    (root / 'build.yaml').write_text('''targets:
  $default:
    builders:
      phase_worker_growth:cache_stage:
        generate_for: [lib/*.seed.dart]
      phase_worker_growth:source_stage:
        generate_for: [lib/*.cache.dart]
      phase_worker_growth:finish_stage:
        generate_for: [lib/*.ready.dart]
builders:
  cache_stage:
    import: package:phase_worker_growth/builder.dart
    builder_factories: [cacheStage]
    build_extensions: {".seed.dart": [".cache.dart"]}
    build_to: cache
    auto_apply: none
  source_stage:
    import: package:phase_worker_growth/builder.dart
    builder_factories: [sourceStage]
    build_extensions: {".cache.dart": [".ready.dart"]}
    required_inputs: [".cache.dart"]
    build_to: source
    auto_apply: none
post_process_builders:
  finish_stage:
    import: package:phase_worker_growth/builder.dart
    builder_factory: finishStage
    input_extensions: [".ready.dart"]
    build_to: source
''')


if __name__ == '__main__':
    main()
