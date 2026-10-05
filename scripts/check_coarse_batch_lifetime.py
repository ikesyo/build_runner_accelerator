#!/usr/bin/env python3
"""Exercise real stateful Builders/Resources across coarse batches.

Use a new disposable --root. Checks stock bytes at jobs=1 (the conservative
path), then per-worker lifetimes, phase visibility and atomic failure at jobs=2.
Multiworker stateful output counters are deliberately not a stock-byte claim.
"""
import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'native', 'dart', 'cache'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parent.parent
    fixture = repo / 'fixtures/lifetime_builder_app'
    for name in ('pubspec.yaml', 'build.yaml'):
        shutil.copy2(fixture / name, root / name)
    spec = root / 'pubspec.yaml'
    spec.write_text(spec.read_text().replace('path: ../..', f'path: {repo}'))
    shutil.copy2(repo / 'fixtures/arbitrary_builder_app/pubspec.lock', root / 'pubspec.lock')
    lib = root / 'lib'
    lib.mkdir()
    builder = (fixture / 'lib/lifetime_builder.dart').read_text()
    builder = builder.replace(
        '    final resource = await buildStep.fetchResource(_sharedResource);',
        "    if (await buildStep.readAsString(buildStep.inputId) == 'FAIL') {\n"
        "      throw StateError('intentional coarse-batch failure');\n    }\n"
        "    if (await buildStep.canRead(AssetId(\n"
        "        buildStep.inputId.package, 'lib/input_00.lifetime.txt'))) {\n"
        "      throw StateError('same-phase output leaked across a batch');\n    }\n"
        '    final resource = await buildStep.fetchResource(_sharedResource);', 1)
    (lib / 'lifetime_builder.dart').write_text(builder)
    for n in range(64):
        (lib / f'input_{n:02}.txt').write_text(f'input {n}\n')
    environment = dict(os.environ, BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache.resolve()))
    records = []

    def run(command, name, **extra):
        log = root / f'{name}.log'
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=root, env=dict(environment, **extra),
                                    stdout=stream, stderr=stream, timeout=300)
        return result.returncode, log

    def outputs():
        return {p.name: p.read_bytes() for p in lib.glob('*.lifetime*.txt')}

    def clean():
        shutil.rmtree(root / '.dart_tool/build', ignore_errors=True)
        shutil.rmtree(root / '.dart_tool/build_runner_accelerator', ignore_errors=True)
        for p in lib.glob('*.lifetime*.txt'):
            p.unlink()

    dart = str(args.dart.resolve())
    assert run([dart, 'pub', 'get', '--offline'], 'pub')[0] == 0
    assert run([dart, 'run', 'build_runner', 'build', '--delete-conflicting-outputs'], 'stock')[0] == 0
    reference = outputs()
    assert len(reference) == 128
    clean()
    command = [str(args.native.resolve()), 'build', '--root', str(root), '--dart', dart, '--mode', 'rust']
    assert run(command + ['--jobs', '1'], 'single',
               BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER='tail')[0] == 0
    assert outputs() == reference
    records.append({'mode': 'single', 'stock_bytes_equal': True, 'outputs': 128})
    for mode in ('static', 'tail', 'tail2', 'queue'):
        clean()
        code, log = run(command + ['--jobs', '2'], mode,
                        BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER=mode,
                        BUILD_RUNNER_ACCELERATOR_METRICS='1',
                        BUILD_RUNNER_ACCELERATOR_WALL_TRACE='1')
        assert code == 0, log
        profiles = [json.loads(line.removeprefix('Dart action metrics: '))
                    for line in log.read_text().splitlines() if line.startswith('Dart action metrics: ')]
        grouped = defaultdict(list)
        for row in profiles:
            name = row['input'].split('|')[1].split('/')[-1]
            suffix = '.lifetime.final.txt' if name.endswith('.lifetime.txt') else '.lifetime.txt'
            path = lib / (name.removesuffix('.lifetime.txt') if suffix.endswith('final.txt') else name.removesuffix('.txt'))
            content = (path.with_name(path.name + suffix)).read_text()
            fields = dict(re.findall(r'(instance|build|resource|resource_use)=(\d+)', content.split(' upstream=')[0]))
            grouped[row['worker_pid']].append((row['builder'], fields))
        assert len(profiles) == 128 and len(outputs()) == 128
        for entries in grouped.values():
            uses = sorted(int(fields['resource_use']) for _, fields in entries)
            assert uses == list(range(1, len(entries) + 1)), (mode, uses)
            builders = defaultdict(list)
            for builder_id, fields in entries:
                assert fields['instance'] == fields['resource'] == '1', fields
                builders[builder_id].append(int(fields['build']))
            for numbers in builders.values():
                assert sorted(numbers) == list(range(1, len(numbers) + 1)), numbers
        for n in range(64):
            upstream = (lib / f'input_{n:02}.lifetime.txt').read_text().strip().replace(' ', '_')
            assert f'upstream={upstream}' in (lib / f'input_{n:02}.lifetime.final.txt').read_text()
        batches = sum(line.startswith('Rust wall trace: ') and '"stage":"worker_batch"' in line
                      for line in log.read_text().splitlines())
        assert batches == (4 if mode == 'static' else 8 if mode == 'tail2' else 12), (mode, batches)
        code, no_op_log = run(command + ['--jobs', '2'], mode + '-no-op',
                             BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER=mode)
        assert code == 0 and 'No work to do (Rust frontend)' in no_op_log.read_text(), no_op_log
        before = outputs()
        graphs = list((root / '.dart_tool/build_runner_accelerator').glob('*.bin'))
        assert graphs, 'graph file not found'
        graph_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in graphs}
        (lib / 'input_63.txt').write_text('FAIL')
        # Dirty all actions, including the failure in a later coarse piece.
        for n in range(63):
            (lib / f'input_{n:02}.txt').write_text(f'edited {n}\n')
        assert run(command + ['--jobs', '2'], mode + '-failure',
                   BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER=mode)[0] != 0
        assert outputs() == before
        assert {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in graphs} == graph_hashes
        for n in range(64):
            (lib / f'input_{n:02}.txt').write_text(f'input {n}\n')
        records.append({'mode': mode, 'actions': len(profiles), 'batches': batches,
                        'resident_lifetimes': True, 'phase_visibility': True,
                        'same_phase_hidden': True, 'no_op': True, 'atomic_failure': True})
    clean()
    assert run(command + ['--jobs', '2'], 'rename-before',
               BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER='tail2')[0] == 0
    (lib / 'input_00.txt').rename(lib / 'input_64.txt')
    (lib / 'input_01.txt').rename(lib / 'input_65.txt')
    (lib / 'input_02.txt').unlink()
    (lib / 'input_66.txt').write_text('new input\n')
    for n in range(3, 67):
        (lib / f'input_{n:02}.txt').write_text(f'renamed build {n}\n')
    code, log = run(command + ['--jobs', '2'], 'rename-after',
                    BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER='tail2',
                    BUILD_RUNNER_ACCELERATOR_WALL_TRACE='1')
    assert code == 0 and len(outputs()) == 128, log
    for n in range(3):
        assert not (lib / f'input_{n:02}.lifetime.txt').exists()
        assert not (lib / f'input_{n:02}.lifetime.final.txt').exists()
    for n in range(3, 67):
        assert (lib / f'input_{n:02}.lifetime.final.txt').is_file()
    batch_count = sum(line.startswith('Rust wall trace: ') and '"stage":"worker_batch"' in line
                      for line in log.read_text().splitlines())
    assert batch_count == 8, batch_count
    records.append({'mode': 'tail2-delete-rename', 'outputs': 128, 'batches': batch_count,
                    'stale_outputs_removed': True})
    for n in range(64, 67):
        (lib / f'input_{n:02}.txt').unlink()
    for n in range(64):
        (lib / f'input_{n:02}.txt').write_text(f'input {n}\n')
    clean()
    watch_log = args.cache.resolve() / 'coarse-lifetime-watch.log'
    watch_log.parent.mkdir(parents=True, exist_ok=True)
    with watch_log.open('w') as stream:
        process = subprocess.Popen(
            [str(args.native.resolve()), 'watch', '--root', str(root), '--dart', dart,
             '--mode', 'rust', '--jobs', '2', '--interval-ms', '200'], cwd=root,
            env=dict(environment, BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER='tail',
                     BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1',
                     BUILD_RUNNER_ACCELERATOR_METRICS='1', BUILD_RUNNER_ACCELERATOR_WALL_TRACE='1'),
            stdout=stream, stderr=stream, start_new_session=True)

        def wait(predicate):
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                text = watch_log.read_text()
                if predicate(text):
                    return text
                assert process.poll() is None, watch_log
                time.sleep(0.1)
            raise AssertionError(f'watch timeout: {watch_log}')

        try:
            first = wait(lambda text: 'Watching ' in text and len(outputs()) == 128)
            first_pids = {json.loads(line[len('Dart action metrics: '):])['worker_pid']
                          for line in first.splitlines() if line.startswith('Dart action metrics: ')}
            for n in range(64):
                (lib / f'input_{n:02}.txt').write_text(f'watch edited {n}\n')
            second = wait(lambda text: text.count('Build completed (Rust frontend)') >= 2
                          and sum(line.startswith('Rust wall trace: ') and '\"stage\":\"worker_batch\"' in line
                                  for line in text.splitlines()) >= 24)
            all_pids = {json.loads(line[len('Dart action metrics: '):])['worker_pid']
                        for line in second.splitlines() if line.startswith('Dart action metrics: ')}
            assert all_pids == first_pids and len(all_pids) == 2
            batch_count = sum(line.startswith('Rust wall trace: ') and '"stage":"worker_batch"' in line
                              for line in second.splitlines())
            assert batch_count == 24, batch_count
            before = outputs()
            graphs = list((root / '.dart_tool/build_runner_accelerator').glob('*.bin'))
            graph_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in graphs}
            for n in range(63):
                (lib / f'input_{n:02}.txt').write_text(f'watch failing {n}\n')
            (lib / 'input_63.txt').write_text('FAIL')
            wait(lambda text: 'watch build failed:' in text)
            assert outputs() == before
            assert {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in graphs} == graph_hashes
            records.append({'mode': 'tail-watch', 'resident_workers': 2,
                            'successful_batches': batch_count, 'atomic_failure': True})
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
    (root / 'validation.json').write_text(json.dumps(records, indent=2) + '\n')
    print(json.dumps(records, indent=2))


if __name__ == '__main__':
    main()
