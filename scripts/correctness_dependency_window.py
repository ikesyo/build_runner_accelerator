#!/usr/bin/env python3
"""Exercise old runner resolutions, including dart-lang/build#5197, end to end."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
from urllib.parse import unquote, urljoin, urlparse

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default=os.environ.get('DART_BIN', 'dart'))
    parser.add_argument('--frontend', default=os.environ.get(
        'BUILD_RUNNER_ACCELERATOR_BIN', str(REPO / 'rust/target/debug/build_runner_accelerator')))
    parser.add_argument('--runner', action='append', choices=['2.15.3', '2.16.0', '2.16.1'])
    parser.add_argument('--analyzer', choices=['13.3.0', '14.5.0'])
    args = parser.parse_args()
    # Retain evidence on failure. This also keeps watcher bookkeeping outside
    # the workspaces and avoids changing files under the checkout or Pub cache.
    results = Path(tempfile.mkdtemp(prefix='dependency-window-'))
    print(f'dependency-window: evidence={results}', flush=True)
    env = os.environ.copy()
    env.setdefault('PUB_CACHE', str(REPO / '.pub-cache'))
    env.setdefault('BUILD_RUNNER_ACCELERATOR_CACHE', str(results / 'shared-cache'))

    def run(command, root, label, success=True):
        log = results / f'{root.name}-{label}.log'
        with log.open('w') as output:
            result = subprocess.run(command, cwd=root, env=env,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=300)
        if (result.returncode == 0) != success:
            raise AssertionError(f'{command} returned {result.returncode}; see {log}')
        return log.read_text()

    def configure(root, runner, analyzer):
        shutil.copytree(REPO / 'fixtures/json_serializable_app/lib', root / 'lib')
        for generated in (root / 'lib').glob('*.g.dart'):
            generated.unlink()
        spec = (REPO / 'fixtures/json_serializable_app/pubspec.yaml').read_text()
        spec = spec.replace('build_runner: 2.16.2', f'build_runner: {runner}\n  analyzer: {analyzer}')
        # Keep the published JSON generator's tested helper; 1.4.0 has
        # ambiguous extensions with json_serializable 6.14.1 on old Analyzer.
        spec += '\n  source_helper: 1.3.13\n'
        spec = spec.replace('path: ../..', f'path: {REPO.as_posix()}')
        (root / 'pubspec.yaml').write_text(spec)
        run([args.dart, '--suppress-analytics', 'pub', 'get'], root, 'pub-get')

    def outputs(root):
        return {p.name: p.read_bytes() for p in (root / 'lib').glob('*.g.dart')}

    def protected_files(root):
        config = root / '.dart_tool/package_config.json'
        runner = next(p for p in json.loads(config.read_text())['packages']
                      if p['name'] == 'build_runner')
        runner_root = Path(unquote(urlparse(urljoin(config.as_uri(), runner['rootUri'])).path))
        files = [config, runner_root / 'lib/src/build/resolver/resolvers_impl.dart']
        return {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}

    try:
        for runner, analyzer, stock_runner in [
                ('2.15.3', '13.3.0', '2.15.3'),
                ('2.15.3', '14.5.0', '2.16.2'),
                ('2.16.0', '13.3.0', '2.16.0'),
                ('2.16.0', '14.5.0', '2.16.2'),
                ('2.16.1', '14.5.0', '2.16.2')]:
            if args.runner and runner not in args.runner:
                continue
            if args.analyzer and analyzer != args.analyzer:
                continue
            case_started = time.monotonic()
            print(f'dependency-window: START runner={runner} analyzer={analyzer}', flush=True)
            stock = results / f'stock-{runner}-{analyzer}'
            native = results / f'native-{runner}-{analyzer}'
            configure(stock, stock_runner, analyzer)
            configure(native, runner, analyzer)
            originals = protected_files(native)
            stock_cmd = [args.dart, '--suppress-analytics', 'run', 'build_runner', 'build', '--force-jit']
            if runner == '2.15.3' and stock_runner != runner:
                stock_cmd.append('--keep-modified-outputs')

            def build(label, mode='--force-jit', success=True):
                stock_log = run(stock_cmd, stock, label, success)
                native_log = run([args.frontend, 'build', '--dart', args.dart, mode], native, label, success)
                if not success:
                    assert 'Could not generate' in stock_log, stock_log
                    assert 'Could not generate' in native_log, native_log
                if label == 'noop':
                    assert 'No work to do (Rust frontend)' in native_log, native_log
                if success:
                    assert outputs(native) == outputs(stock), label
                    assert outputs(native), label
                assert protected_files(native) == originals, 'application config/Pub source was modified'

            build('clean')
            build('noop')
            if runner == '2.15.3' and analyzer == '13.3.0':
                # A retained output whose producer is reusable still requires
                # the existing resolver guard when another action runs.
                for root in [stock, native]:
                    text = (root / 'lib/model.dart').read_text()
                    (root / 'lib/other.dart').write_text(
                        text.replace('User', 'Other').replace('model.g.dart', 'other.g.dart'))
                build('guard-baseline')
                saved = outputs(native)
                for root in [stock, native]:
                    generated = root / 'lib/other.g.dart'
                    generated.write_bytes(saved['other.g.dart'] + b'\n// retained other\n')
                    model = root / 'lib/model.dart'
                    model.write_text(model.read_text().replace('final int id;', 'final String id;'))
                before = outputs(native)
                graph = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
                graph_bytes = graph.read_bytes()
                log = run([args.frontend, 'build', '--dart', args.dart, '--force-jit'],
                          native, 'retained-api-guard', success=False)
                assert 'digest/resolver APIs with retained modified outputs' in log
                assert outputs(native) == before
                assert graph.read_bytes() == graph_bytes
                for root in [stock, native]:
                    (root / 'lib/other.g.dart').write_bytes(saved['other.g.dart'])
                    model = root / 'lib/model.dart'
                    model.write_text(model.read_text().replace('final String id;', 'final int id;'))
                build('guard-recovery')
                for root in [stock, native]:
                    (root / 'lib/other.dart').unlink()
                build('guard-cleanup')
            if runner == '2.15.3':
                # The default retains edits across fresh processes, without a
                # user-facing --keep-modified-outputs argument on native.
                for root in [stock, native]:
                    generated = root / 'lib/model.g.dart'
                    generated.write_bytes(generated.read_bytes() + b'\n// retained edit\n')
                build('retained-default')
                build('retained-restart')
                assert b'// retained edit' in outputs(native)['model.g.dart']
            for root in [stock, native]:
                model = root / 'lib/model.dart'
                model.write_text(model.read_text().replace('final int id;', 'final String id;'))
            build('incremental')
            assert b'// retained edit' not in outputs(native)['model.g.dart']
            # Compile and execute the same catalog through the AOT route.
            for root in [stock, native]:
                model = root / 'lib/model.dart'
                model.write_text(model.read_text().replace('final String id;', 'final double id;'))
            build('aot', '--force-aot')
            prior = outputs(native)
            for root in [stock, native]:
                model = root / 'lib/model.dart'
                model.write_text(model.read_text().replace('final double id;', 'final Future<int> id;'))
            build('failure', success=False)
            assert outputs(native) == prior, 'failed generation published outputs'
            for root in [stock, native]:
                model = root / 'lib/model.dart'
                model.write_text(model.read_text().replace('final Future<int> id;', 'final double id;'))
            build('recovery')
            watch_log = results / f'{native.name}-watch.log'
            with watch_log.open('w') as output:
                watcher = subprocess.Popen(
                    [args.frontend, 'watch', '--dart', args.dart, '--force-aot', '--interval-ms', '50'],
                    cwd=native, env=env, stdout=output, stderr=subprocess.STDOUT)
                try:
                    def wait_for(predicate):
                        deadline = time.monotonic() + 90
                        while not predicate():
                            assert watcher.poll() is None, watch_log
                            if time.monotonic() > deadline:
                                raise AssertionError(f'watch timeout: {watch_log}')
                            time.sleep(0.05)
                    wait_for(lambda: 'Watching ' in watch_log.read_text())
                    for root in [stock, native]:
                        model = root / 'lib/model.dart'
                        model.write_text(model.read_text().replace('final double id;', 'final bool id;'))
                    run(stock_cmd, stock, 'watch-reference')
                    wait_for(lambda: outputs(native) == outputs(stock))
                finally:
                    watcher.send_signal(signal.SIGINT)
                    try:
                        watcher.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        watcher.kill()
                        watcher.wait()
            for root in [stock, native]:
                model = root / 'lib/model.dart'
                renamed = root / 'lib/renamed.dart'
                renamed.write_text(model.read_text().replace("part 'model.g.dart';", "part 'renamed.g.dart';"))
                model.unlink()
            build('rename')
            assert set(outputs(native)) == {'renamed.g.dart'}, 'rename retained old output'
            for root in [stock, native]:
                (root / 'lib/renamed.dart').unlink()
            run(stock_cmd, stock, 'delete')
            run([args.frontend, 'build', '--dart', args.dart, '--force-jit'], native, 'delete')
            assert outputs(native) == outputs(stock) == {}, 'deleted source retained output'
            assert protected_files(native) == originals
            if runner == '2.15.3' and analyzer == '14.5.0':
                for root in [stock, native]:
                    shutil.copy(REPO / 'fixtures/json_serializable_app/lib/model.dart', root / 'lib/model.dart')
                build('recreate')
                # Upgrading the resolved runner changes the default without
                # introducing a sticky demand-policy history or manual reset.
                for root in [stock, native]:
                    generated = root / 'lib/model.g.dart'
                    generated.write_bytes(generated.read_bytes() + b'\n// old-policy edit\n')
                spec = native / 'pubspec.yaml'
                spec.write_text(spec.read_text().replace('build_runner: 2.15.3', 'build_runner: 2.16.2'))
                run([args.dart, '--suppress-analytics', 'pub', 'get'], native, 'upgrade-pub-get')
                originals = protected_files(native)
                stock_cmd.remove('--keep-modified-outputs')
                build('modern-policy-upgrade')
                assert b'// old-policy edit' not in outputs(native)['model.g.dart']
                assert not (native / '.dart_tool/build_runner_accelerator/runner-package_config.json').exists()
            print(f'dependency-window: PASS runner={runner} analyzer={analyzer} '
                  f'elapsed={time.monotonic() - case_started:.1f}s', flush=True)
    except BaseException:
        print(f'dependency-window: retained evidence at {results}', flush=True)
        raise
    shutil.rmtree(results)


if __name__ == '__main__':
    main()
