#!/usr/bin/env python3
"""Bounded resolver diagnostics; retains workspaces and raw metrics, no A/B claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--extra-inputs', type=int, default=24)
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--native', type=Path, required=True)
    args = parser.parse_args()
    if args.extra_inputs < 0 or args.jobs < 1:
        parser.error('--extra-inputs must be nonnegative and --jobs must be positive')
    repo = Path(__file__).resolve().parents[1]
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=False)
    dart, native = args.dart.resolve(), args.native.resolve()
    env = dict(os.environ, PUB_CACHE=str(repo / '.pub-cache'),
               BUILD_RUNNER_ACCELERATOR_CACHE=str(results / 'tool-cache'),
               ANALYZER_STATE_LOCATION_OVERRIDE=str(results / 'analyzer-cache'),
               BUILD_RUNNER_ACCELERATOR_METRICS='1',
               BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1')
    # The SDK CLI needs a writable analytics location in restricted environments.
    env.pop('HOME', None)
    roots = {lane: results / lane for lane in ('stock', 'native')}
    fixture = repo / 'fixtures/riverpod_app'
    for root in roots.values():
        root.mkdir()
        for name in ('pubspec.yaml', 'pubspec.lock', 'build.yaml'):
            shutil.copyfile(fixture / name, root / name)
        spec = root / 'pubspec.yaml'
        spec.write_text(spec.read_text().replace('path: ../..', f'path: {repo}'))
        shutil.copytree(fixture / 'lib', root / 'lib',
                        ignore=shutil.ignore_patterns('*.g.dart', '*.freezed.dart'))
        for i in range(args.extra_inputs):
            (root / f'lib/provider_{i:03}.dart').write_text(
                "import 'package:riverpod_annotation/riverpod_annotation.dart';\n"
                f"part 'provider_{i:03}.g.dart';\n"
                f'@riverpod\nint value{i}(Ref ref) => {i};\n')

    def run(command, root, label):
        with (results / f'{label}.log').open('w') as log:
            start = time.perf_counter()
            with subprocess.Popen(command, cwd=root, env=env, stdout=log,
                                  stderr=subprocess.STDOUT) as process:
                watchdog = threading.Timer(600, process.kill)
                watchdog.start()
                try:
                    status = process.wait()
                finally:
                    watchdog.cancel()
                if status:
                    raise subprocess.CalledProcessError(status, command)
            return time.perf_counter() - start

    for lane, root in roots.items():
        run([str(dart), '--suppress-analytics', 'pub', 'get', '--offline'],
            root, f'{lane}-pub-get')
    configurations = [json.loads((r / '.dart_tool/package_config.json').read_text())
                      for r in roots.values()]
    deps = [{p['name']: p['rootUri'] for p in c['packages']
             if p['name'] != 'riverpod_app'} for c in configurations]
    assert deps[0] == deps[1], 'Dependency roots differ'
    stock_command = [str(dart), '--suppress-analytics', 'run', 'build_runner',
                     'build', '--delete-conflicting-outputs']
    native_command = [str(native), 'build', '--root', str(roots['native']),
                      '--dart', str(dart), '--jobs', str(args.jobs)]
    metadata = dict(revision=subprocess.check_output(
        ['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        dart=subprocess.check_output([str(dart), '--version'], text=True).strip(),
        native_sha256=hashlib.sha256(native.read_bytes()).hexdigest(),
        jobs=args.jobs, extra_inputs=args.extra_inputs, dependencies=deps[0],
        native_command=native_command, samples=[],
        source_hashes={str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (repo / 'lib').rglob('*.dart')})

    def outputs(root, lane):
        found = {str(p.relative_to(root)): p.read_bytes()
                 for p in (root / 'lib').rglob('*.dart')
                 if p.name.endswith(('.g.dart', '.freezed.dart'))}
        cache = root / ('.dart_tool/build/generated/riverpod_app' if lane == 'stock'
                        else '.dart_tool/build_runner_accelerator/cache/riverpod_app')
        found.update({'parts/' + str(p.relative_to(cache)): p.read_bytes()
                      for p in cache.rglob('*.g.part')})
        return found

    def measure(case):
        wall = run(native_command, roots['native'], case)
        reference = outputs(roots['stock'], 'stock')
        actual = outputs(roots['native'], 'native')
        assert reference and reference == actual, f'Output mismatch: {case}'
        sample = dict(case=case, wall_s=wall, byte_identical_files=len(actual))
        rows = []
        for line in (results / f'{case}.log').read_text().splitlines():
            prefix = 'Dart action metrics: '
            if line.startswith(prefix):
                rows.append(json.loads(line[len(prefix):]))
        (results / f'{case}-actions.json').write_text(json.dumps(rows, indent=2))
        riverpod = [r for r in rows if r['builder'] == 'riverpod_generator:riverpod_generator']
        sample['riverpod_actions'] = len(riverpod)
        sample['riverpod_library_for_us'] = sum(
            r['resolver_call_us'].get('libraryFor', 0) for r in riverpod)
        sample['riverpod_first_action'] = riverpod[0] if riverpod else None
        sample['riverpod_later_totals'] = {
            key: sum(r[key] for r in riverpod[1:])
            for key in ('cycle_graph_walk_us', 'cycle_graph_file_loads',
                        'apply_pending_changes_us', 'filesystem_phase_sync_us',
                        'byte_store_get_us', 'byte_store_gets', 'byte_store_put_us',
                        'file_content_get_us', 'ipc_read_us', 'ipc_can_read_us',
                        'ipc_resolve_assets_us')}
        metadata['samples'].append(sample)
        (results / 'metadata.json').write_text(json.dumps(metadata, indent=2))
        print(json.dumps({k: v for k, v in sample.items()
                          if k not in ('riverpod_first_action', 'riverpod_later_totals')}),
              flush=True)

    run(stock_command, roots['stock'], 'stock-clean')
    measure('cold-tool-cache')  # includes manifest/AOT/SDK/cache population
    root = roots['native']
    for p in list((root / 'lib').rglob('*.dart')):
        if p.name.endswith(('.g.dart', '.freezed.dart')):
            p.unlink()
    tool = root / '.dart_tool/build_runner_accelerator'
    (tool / 'graph-v3.bin').unlink(missing_ok=True)
    for name in ('cache', 'overlay'):
        shutil.rmtree(tool / name, ignore_errors=True)
    measure('warm-clean')
    measure('noop')
    for lane_root in roots.values():
        with (lane_root / 'lib/secondary.dart').open('a') as f:
            f.write('\n// resolver diagnostic one-file edit\n')
    run(stock_command, roots['stock'], 'stock-one-file')
    measure('one-file')
    for lane_root in roots.values():
        for p in (lane_root / 'lib').glob('*.dart'):
            if not p.name.endswith(('.g.dart', '.freezed.dart')):
                with p.open('a') as f:
                    f.write('\n// resolver diagnostic broad edit\n')
    run(stock_command, roots['stock'], 'stock-broad')
    measure('broad')


if __name__ == '__main__':
    main()
