#!/usr/bin/env python3
"""SDK-specific resolution and real stock/native worker lifecycle comparison."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resolution', choices=('downgrade', 'upgrade'), required=True)
    parser.add_argument('--results', type=Path)
    args = parser.parse_args()
    results = (args.results or Path(tempfile.mkdtemp(prefix='sdk-compat-'))).resolve()
    results.mkdir(parents=True, exist_ok=True)
    print(f'SDK compatibility logs and lockfiles: {results}', flush=True)
    dart = os.environ['DART_BIN']
    native = os.environ['BUILD_RUNNER_ACCELERATOR_BIN']
    env = {**os.environ, 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT': '0',
           'BUILD_RUNNER_ACCELERATOR_CACHE': str(results / 'cache'),
           'DART_SUPPRESS_ANALYTICS': 'true'}
    processes = []
    sequence = 0

    def run(command, root, expected=0):
        nonlocal sequence
        sequence += 1
        log = results / f'{sequence:02d}-{root.name}-{command[-1].replace("/", "_")}.log'
        with log.open('w') as output:
            output.write(f'{command!r}\n')
            output.flush()
            process = subprocess.Popen(command, cwd=root, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=240)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f'timeout: {log}') from error
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # The child exited between poll and killpg.
                    process.wait()
        assert (code == 0) if expected == 0 else (code != 0), (command, code, log.read_text())
        return log.read_text().split('\n', 1)[1]

    def stock(root, command='build'):
        return [dart, 'run', 'build_runner', command]

    def accelerator(root, command='build'):
        return [native, command, '--root', str(root), '--dart', dart,
                '--jobs', '1', '--force-jit']

    def outputs(root):
        # Compare the entire generated inventory, including unexpected files.
        sources = {'lib/builder.dart', 'lib/model.dart', 'lib/model_renamed.dart'}
        return {str(p.relative_to(root)): p.read_bytes()
                for p in (root / 'lib').rglob('*')
                if p.is_file() and str(p.relative_to(root)) not in sources}

    def compare(label):
        left, right = outputs(stock_root), outputs(native_root)
        assert left == right, (label, left, right)
        print(f'{label}: stock/native file sets and bytes match ({len(left)})', flush=True)

    try:
        print(run([dart, '--version'], results).strip(), flush=True)
        print('Worker: --force-jit (SDK-specific kernel/script); jobs=1', flush=True)
        stock_root, native_root = results / 'stock', results / 'native'
        for root in (stock_root, native_root):
            shutil.copytree(REPO / 'fixtures/sdk_compat_app', root,
                            ignore=shutil.ignore_patterns('.dart_tool', '*.summary'))
            pubspec = root / 'pubspec.yaml'
            pubspec.write_text(pubspec.read_text().replace('path: ../..', f'path: {REPO}'))
        run([dart, 'pub', args.resolution], stock_root)
        shutil.copy2(stock_root / 'pubspec.lock', native_root / 'pubspec.lock')
        run([dart, 'pub', 'get', '--enforce-lockfile'], native_root)
        assert (stock_root / 'pubspec.lock').read_bytes() == (native_root / 'pubspec.lock').read_bytes()
        deps = json.loads(run([dart, 'pub', 'deps', '--json'], stock_root))
        for package in deps['packages']:
            if package['name'] in ('build_runner', 'analyzer', 'build'):
                print(f"{package['name']}: {package['version']}", flush=True)

        def build(label, expected=0):
            stock_log = run(stock(stock_root), stock_root, expected)
            native_log = run(accelerator(native_root), native_root, expected)
            if expected == 0:
                compare(label)
                if label == 'no-op':
                    assert 'No work to do (Rust frontend)' in native_log, native_log
            else:
                assert 'requested SDK compatibility failure' in stock_log, stock_log
                assert 'requested SDK compatibility failure' in native_log, native_log

        def write(text):
            for root in (stock_root, native_root):
                (root / 'lib/model.dart').write_text(text)

        build('initial')
        assert outputs(native_root) == {'lib/model.summary': b'Model\n'}
        build('no-op')
        write('class Changed {}\n')
        build('input change')
        assert outputs(native_root)['lib/model.summary'] == b'Changed\n'
        for root in (stock_root, native_root):
            (root / 'lib/model.dart').rename(root / 'lib/model_renamed.dart')
        build('rename')
        assert set(outputs(native_root)) == {'lib/model_renamed.summary'}
        for root in (stock_root, native_root):
            (root / 'lib/model_renamed.dart').unlink()
        build('input deletion')
        assert not outputs(native_root)
        write('class BeforeFailure {}\n')
        build('before failure')
        previous = outputs(native_root)
        graph = native_root / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        previous_graph = graph.read_bytes()
        write('class Failed {} // fail\n')
        build('builder failure', expected=1)
        assert outputs(native_root) == previous
        assert graph.read_bytes() == previous_graph
        write('class Recovered {}\n')
        build('recovery')
        assert outputs(native_root)['lib/model.summary'] == b'Recovered\n'

        for root, command in ((stock_root, stock(stock_root, 'watch')),
                              (native_root, accelerator(native_root, 'watch'))):
            log = (results / f'{root.name}-watch.log').open('w')
            process = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            processes.append((process, log))

        def wait(predicate):
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                assert all(p.poll() is None for p, _ in processes), 'watch exited'
                if predicate():
                    return
                time.sleep(0.1)
            raise AssertionError('watch timeout; inspect watch logs')

        wait(lambda: 'native filesystem events' in (results / 'native-watch.log').read_text()
             and 'Built with build_runner' in (results / 'stock-watch.log').read_text())
        # The second edit exercises the resident worker's resolver reset too.
        for name in ('Watched', 'WatchedAgain'):
            expected = f'{name}\n'.encode()
            write(f'class {name} {{}}\n')
            wait(lambda expected=expected: all((r / 'lib/model.summary').read_bytes() == expected
                             for r in (stock_root, native_root)
                             if (r / 'lib/model.summary').exists())
                 and all((r / 'lib/model.summary').exists() for r in (stock_root, native_root)))
            compare(f'watch regeneration ({name})')
        assert all(p.poll() is None for p, _ in processes), 'watch exited after final regeneration'
    finally:
        for process, log in processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            log.close()
        print(f'Evidence retained: {results}', flush=True)


if __name__ == '__main__':
    main()
