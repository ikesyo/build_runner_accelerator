#!/usr/bin/env python3
"""Compare native librarySourceSink phases and publication with stock runner."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from shared_parts_reference import prepare_stock_reference

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker-mode', choices=('jit', 'aot'), default='jit')
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--resolution', choices=('upgrade', 'downgrade'), default='upgrade')
    parser.add_argument('--results', type=Path)
    parser.add_argument('--stock-reference', choices=('corrected', 'raw'), default='corrected')
    args = parser.parse_args()
    results = (args.results or Path(tempfile.mkdtemp(prefix='shared-parts-'))).resolve()
    results.mkdir(parents=True, exist_ok=True)
    print(f'shared-parts: evidence={results}', flush=True)
    dart = os.environ['DART_BIN']
    frontend = os.environ['BUILD_RUNNER_ACCELERATOR_BIN']
    env = {**os.environ, 'BUILD_RUNNER_ACCELERATOR_CACHE': str(results / 'cache'),
           'DART_SUPPRESS_ANALYTICS': 'true'}
    roots = [results / 'stock', results / 'native']
    sequence = 0
    experiment_args = []

    def run(command, root, success=True):
        nonlocal sequence
        sequence += 1
        log = results / f'{sequence:03d}-{root.name}.log'
        with log.open('w') as output:
            output.write(f'{command!r}\n'); output.flush()
            process = subprocess.Popen(command, cwd=root, env={**env, 'SHARED_OPTIONAL_HISTORY': str(results / f'{root.name}-optional.history'), 'SHARED_ACTION_HISTORY': str(results / f'{root.name}-actions.history')}, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=300)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
        assert (code == 0) == success, f'{command}: {code}, see {log}\n{log.read_text()}'
        return log.read_text()

    for root in roots:
        shutil.copytree(REPO / 'fixtures/shared_parts_app', root,
                        ignore=shutil.ignore_patterns('.dart_tool', 'pubspec.lock', '.cache'))
        spec = root / 'pubspec.yaml'
        spec.write_text(spec.read_text().replace('path: ../..', f'path: {REPO}'))
    print(run([dart, '--version'], results).strip(), flush=True)
    run([dart, 'pub', args.resolution], roots[0])
    shutil.copy2(roots[0] / 'pubspec.lock', roots[1] / 'pubspec.lock')
    run([dart, 'pub', 'get', '--enforce-lockfile'], roots[1])
    if args.stock_reference == 'corrected':
        prepare_stock_reference(roots[0], results)

    def command(root, action='build', extra=()):
        if root == roots[0]:
            return [dart, 'run', 'build_runner', action, f'--force-{args.worker_mode}', *experiment_args, *extra]
        return [frontend, action, '--root', str(root), '--dart', dart,
                '--jobs', str(args.jobs), f'--force-{args.worker_mode}', *experiment_args, *extra]

    def inventory(root):
        return {str(p.relative_to(root)): p.read_bytes()
                for folder in ('lib', 'bin') for p in (root / folder).rglob('*') if p.is_file()}

    def clean_stock_reference(label):
        clean = results / f'clean-stock-{label}'
        clean.mkdir()
        for name in ('pubspec.yaml', 'pubspec.lock', 'build.yaml'):
            shutil.copy2(roots[0] / name, clean / name)
        for folder in ('lib', 'bin'):
            for source in (roots[0] / folder).rglob('*.dart'):
                relative = source.relative_to(roots[0])
                if '_br_' in relative.parts:
                    continue
                target = clean / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        run([dart, 'pub', 'get', '--enforce-lockfile'], clean)
        run([dart, 'run', 'build_runner', 'build', f'--force-{args.worker_mode}', *experiment_args], clean)
        assert inventory(clean) == inventory(roots[1]), f'{label}: native differs from unmodified clean stock'
        print(f'shared-parts: {label}: unmodified clean stock matches', flush=True)

    def build(label, extra=(), success=True):
        logs = [run(command(root, extra=extra), root, success) for root in roots]
        if success:
            assert inventory(roots[0]) == inventory(roots[1]), (label, inventory(roots[0]), inventory(roots[1]))
        print(f'shared-parts: {label}: PASS', flush=True)
        return logs

    def write(source, path='lib/model.dart'):
        for root in roots:
            target = root / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(source)

    def edit(old, new):
        for root in roots:
            p = root / 'lib/model.dart'; p.write_text(p.read_text().replace(old, new))

    part = roots[1] / 'lib/_br_/model.part.dart'
    graph = roots[1] / '.dart_tool/build_runner_accelerator/graph-v3.bin'
    build('initial / automatic directive / intermediate resolver view')
    assert 'const seesFirst = true;' in part.read_text(), part.read_text()
    assert (roots[1] / 'lib/model.summary').read_text() == 'FirstGenerated,Model,SecondGenerated\n'
    previous_graph = graph.read_bytes()
    logs = build('no-op')
    assert 'No work to do (Rust frontend)' in logs[1], logs[1]
    assert graph.read_bytes() == previous_graph
    unrelated_calls = (results / 'native-actions.history').read_text().count('summary:shared_parts_app|lib/unrelated.dart')
    edit('class Model {}', 'class Changed {}')
    build('incremental')
    assert (results / 'native-actions.history').read_text().count('summary:shared_parts_app|lib/unrelated.dart') == unrelated_calls, 'unrelated action rebuilt'
    edit('class Changed {}', 'class Changed {} // empty')
    build('empty contribution / automatic directive removal')
    assert not part.exists()
    assert "part '_br_/model.part.dart';" not in (roots[1] / 'lib/model.dart').read_text()
    build('empty no-op')
    edit('// empty', '// emit')
    build('contribution recovery / automatic directive addition')
    for root in roots:
        (root / 'lib/_br_/model.part.dart').unlink()
    build('deleted shared output repair')
    for root in roots:
        (root / 'lib/_br_/model.part.dart').write_text('// corrupt\n')
    build('modified shared output repair')
    for root in roots:
        p = root / 'lib/model.dart'
        p.write_text(p.read_text().replace("part '_br_/model.part.dart';\n", ''))
    before, saved_graph = inventory(roots[1]), graph.read_bytes()
    build('only-check missing directive', extra=('--only-check',), success=False)
    assert inventory(roots[1]) == before and graph.read_bytes() == saved_graph
    build('only-check recovery')
    build('only-check clean', extra=('--only-check',))
    write('class Nested {}\n', 'lib/nested/model.dart')
    write('class Executable {}\n', 'bin/model.dart')
    build('multiple inputs / nested and non-lib paths')
    clean_stock_reference('addition')
    for root in roots:
        old = root / 'lib/nested/model.dart'
        old.rename(old.with_name('model_renamed.dart'))
    build('rename / stale part cleanup')
    clean_stock_reference('rename')
    for root in roots:
        (root / 'lib/nested/model_renamed.dart').unlink()
    build('input deletion / stale part cleanup')
    clean_stock_reference('deletion')
    write('class Failure {} // fail\n')
    before, saved_graph = inventory(roots[1]), graph.read_bytes()
    build('failure after contribution', success=False)
    assert inventory(roots[1]) == before and graph.read_bytes() == saved_graph
    write('class Recovered {}\n')
    build('failure recovery')
    write('class Recovered {} // imports\n')
    before, saved_graph = inventory(roots[1]), graph.read_bytes()
    logs = build('imports require enhanced-parts', success=False)
    assert all('Imports in parts need' in log for log in logs)
    assert inventory(roots[1]) == before and graph.read_bytes() == saved_graph
    histories = [results / f'{root.name}-optional.history' for root in roots]
    assert all(not history.exists() for history in histories), 'undemanded optional builder ran'
    # Both lazy producers run in the first pass, but only model.dart needs a
    # directive replay. The other producer must retain its completed result.
    for root in roots:
        path = root / 'bin/model.dart'
        path.write_text(path.read_text().replace('class Executable {}', 'class OptionalExecutable {} // optional'))
    write('class OptionalReplay {} // optional\n')
    build('optional demand after staged directive edit')
    expected_length = len((roots[1] / 'lib/model.dart').read_text())
    assert f'const optionalLength = {expected_length};' in part.read_text()
    def per_input_history(history):
        events = {}
        for line in history.read_text().splitlines():
            asset, length = line.rsplit(':', 1)
            events.setdefault(asset, []).append(int(length))
        return events
    assert per_input_history(histories[0]) == per_input_history(histories[1]), 'optional demand/replay history differs'
    assert len(per_input_history(histories[1])['shared_parts_app|bin/model.dart']) == 1, 'unaffected optional producer replayed'
    previous_history = histories[1].read_bytes()
    build('optional demand no-op')
    assert histories[1].read_bytes() == previous_history
    assert per_input_history(histories[0]) == per_input_history(histories[1])
    write('class ReplayFailure {} // replay-failure\n')
    before, saved_graph = inventory(roots[1]), graph.read_bytes()
    logs = build('failure after staged directive edit', success=False)
    assert all('requested shared-part failure' in log for log in logs)
    assert inventory(roots[1]) == before and graph.read_bytes() == saved_graph
    write('class Recovered {}\n')
    build('staged directive failure recovery')
    write('class Recovered {} // imports\n')
    experiment_args.append('--enable-experiment=enhanced-parts')
    build('imports / reserved prefix / enhanced-parts')
    assert "import 'dart:math' as " in part.read_text()
    build('imports no-op')
    write('class Recovered {} // imports-only\n')
    build('imports-only ignored / source removal')
    assert not part.exists()
    assert "part '_br_/model.part.dart';" not in (roots[1] / 'lib/model.dart').read_text()
    assert (roots[1] / 'lib/model.summary').read_text() == 'Recovered\n'
    build('imports-only no-op')
    write('class Recovered {} // imports\n')
    build('source contributions restored after imports-only')
    processes = []
    try:
        for root in roots:
            log = (results / f'{root.name}-watch.log').open('w')
            processes.append((subprocess.Popen(command(root, 'watch'), cwd=root, env=env,
                              stdout=log, stderr=subprocess.STDOUT, start_new_session=True), log))
        def wait(predicate):
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                assert all(p.poll() is None for p, _ in processes), 'watch exited'
                if predicate(): return
                time.sleep(.1)
            raise AssertionError(f'watch timeout: {results}')
        wait(lambda: 'native filesystem events' in (results / 'native-watch.log').read_text()
             and 'Built with build_runner' in (results / 'stock-watch.log').read_text())
        for old, new in [('Recovered', 'Watched'), ('Watched', 'WatchedAgain')]:
            completions = [(results / 'stock-watch.log').read_text().count('Built with build_runner'),
                           (results / 'native-watch.log').read_text().count('Build completed (Rust frontend)')]
            edit(f'class {old}', f'class {new}')
            expected = f'class {new}'.encode()
            wait(lambda: all(expected in (root / 'lib/model.first.txt').read_bytes() for root in roots)
                 and (results / 'stock-watch.log').read_text().count('Built with build_runner') > completions[0]
                 and (results / 'native-watch.log').read_text().count('Build completed (Rust frontend)') > completions[1])
            assert inventory(roots[0]) == inventory(roots[1])
            print(f'shared-parts: watch {new}: PASS', flush=True)
    finally:
        for process, log in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                try: process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
            log.close()
    print('shared-parts: PASS', flush=True)


if __name__ == '__main__':
    main()
