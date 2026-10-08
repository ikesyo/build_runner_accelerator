#!/usr/bin/env python3
"""Compare observable configuration semantics with resolved stock build_runner.

Each lane keeps its workspace between builds: compare bytes AND absent outputs,
including mapping/enabling changes, no-op, restoring configuration, watch and AOT.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from correctness_cli import REPO, DART, NATIVE, ENV, launcher

ENV = {**ENV, 'BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM': '0'}


def execute(args, root, env=ENV):
    result = subprocess.run(args, cwd=root, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
    return result.returncode, result.stdout


def ok(args, root):
    code, output = execute(args, root)
    assert code == 0, (args, code, output)
    return output


def outputs(root):
    return {str(p.relative_to(root)): p.read_bytes()
            for p in (root / 'lib').rglob('*')
            if p.suffix in ('.out', '.alternate', '.marker', '.wrong')}


def prepare(root):
    shutil.copytree(REPO / 'fixtures/settings_builder_app', root,
                    ignore=shutil.ignore_patterns('.dart_tool', '*.out', '*.alternate', '*.marker'))
    pubspec = root / 'pubspec.yaml'
    pubspec.write_text(pubspec.read_text().replace('path: ../..', f'path: {REPO}'))
    ok([DART, 'pub', 'get', '--offline'], root)


def stock(root, flags=(), command='build'):
    return [DART, 'run', 'build_runner', command, *flags]


def check(stock_root, native_root, flags, compile_flag='--force-jit', mode='rust'):
    flags = [*flags, compile_flag]
    reference = ok(stock(stock_root, flags), stock_root)
    actual = ok(launcher(native_root, mode, flags=flags), native_root)
    assert outputs(stock_root) == outputs(native_root), (flags, reference, actual,
                                                         outputs(stock_root), outputs(native_root))
    if mode == 'rust':
        assert '(Rust frontend)' in actual, actual
    return actual


def wait(predicate, proc, log):
    deadline = time.monotonic() + 180
    while not predicate():
        assert proc.poll() is None, log.read_text()
        assert time.monotonic() < deadline, log.read_text()
        time.sleep(.1)


def watch(root, args, edit, expected):
    log = root / 'settings-watch.log'
    with log.open('w') as stream:
        proc = subprocess.Popen(args, cwd=root, env=ENV, stdout=stream, stderr=stream,
                                start_new_session=True)
        try:
            markers = ('Watching ', 'Built with build_runner')
            wait(lambda: any(m in log.read_text() for m in markers), proc, log)
            edit(root)
            wait(lambda: outputs(root) == expected, proc, log)
            # A later input edit must use the newly selected options/catalog.
            (root / 'lib/a.txt').write_text('watched input\n')
            wait(lambda: all(json.loads(data)['input'] == 'watched input\n'
                             for path, data in outputs(root).items() if path.startswith('lib/a.')), proc, log)
            return outputs(root)
        finally:
            os.killpg(proc.pid, signal.SIGINT)
            proc.wait(timeout=15)


def watch_topology_boundary(temporary):
    # Stock 2.16.2's resident reload is not a fresh build when the mapping and
    # enabled applications change. Record stock's observable behavior, then
    # require a full stock handoff/error rather than partial native execution.
    flags = ['--config=named', '--release', '--define=:settings=value=watch-boundary', '--force-jit']
    fresh = temporary / 'watch-fresh-stock'
    prepare(fresh)
    before = (fresh / 'build.named.yaml').read_text()
    after = before.replace('suffix: .alternate', 'suffix: .out').replace('enabled: false', 'enabled: true')
    (fresh / 'build.named.yaml').write_text(after)
    ok(stock(fresh, flags), fresh)
    expected = outputs(fresh)
    for mode in ('stock', 'rust', 'auto'):
        root = temporary / f'watch-topology-{mode}'
        prepare(root)
        log = root / 'topology-watch.log'
        args = stock(root, flags, 'watch') if mode == 'stock' else launcher(root, mode, 'watch', flags)
        with log.open('w') as stream:
            proc = subprocess.Popen(args, cwd=root, env=ENV, stdout=stream, stderr=stream,
                                    start_new_session=True)
            try:
                wait(lambda: ('Built with build_runner' in log.read_text() if mode == 'stock'
                              else 'Watching ' in log.read_text()), proc, log)
                original = outputs(root)
                assert list(original) == ['lib/a.alternate'], original
                (root / 'build.named.yaml').write_text(after)
                if mode == 'stock':
                    wait(lambda: 'Starting build #2' in log.read_text()
                         and 'wrote 0 outputs' in log.read_text() and outputs(root) == {}, proc, log)
                elif mode == 'rust':
                    deadline = time.monotonic() + 180
                    while proc.poll() is None:
                        assert time.monotonic() < deadline, log.read_text()
                        time.sleep(.1)
                    assert proc.returncode != 0
                    assert 'watch configuration changed builder applications or output topology' in log.read_text()
                    assert outputs(root) == original
                else:
                    # A fresh stock handoff sees native outputs as files, not
                    # entries in its private graph. Compare that exact input
                    # state too, including stock's retention of old files.
                    for relative, data in original.items():
                        (fresh / relative).write_bytes(data)
                    ok(stock(fresh, flags), fresh)
                    expected = outputs(fresh)
                    wait(lambda: outputs(root) == expected, proc, log)
                    assert 'using Dart fallback' in log.read_text()
                    assert 'watch configuration changed builder applications or output topology' in log.read_text()
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGINT)
                proc.wait(timeout=15)


def main():
    temporary = Path(tempfile.mkdtemp(prefix='settings-correctness-'))
    ENV.setdefault('BUILD_RUNNER_ACCELERATOR_CACHE', str(temporary / 'accelerator-cache'))
    print(f'settings workspaces: {temporary}', flush=True)
    try:
        reference, native = temporary / 'stock', temporary / 'native'
        prepare(reference)
        prepare(native)
        for root in (reference, native):
            named = (root / 'build.named.yaml').read_text()
            (root / 'build..yaml').write_text(named)
            (root / 'build.--force-aot.yaml').write_text(named)
        # The same workspace switches configuration repeatedly. Runtime mapping
        # overrides, disappearing applications and zero-output deletion are real.
        cases = [[], [], ['--release'], ['--no-release'],
                 ['--define', ':settings=value=cli'],
                 ['--define=:settings=nested={"z":[1,true,null],"a":{"y":2,"b":3}}',
                  '--define=:settings=text=a=b,c', '--define=:settings=empty='],
                 ['--config', 'named'], ['--config=named', '--release'],
                 ['--config='], ['--config', '--force-aot'],
                 ['--config=named', '--define=:marker=enabled=true'],
                 ['--config=missing', '-c', 'named', '-r', '--no-release', '--release',
                  '--define=settings_builder_app|settings=value=combined'],
                 ['--define=:settings=emit=false'], [], ['--config=named'], [], []]
        for index, flags in enumerate(cases):
            output = check(reference, native, flags)
            if index in (1, len(cases) - 1):
                assert 'No work to do (Rust frontend)' in output, output
            print(f'settings case {index}: PASS {flags}', flush=True)
        # Edit and restore build.yaml without touching primary inputs.
        base = (reference / 'build.yaml').read_text()
        for yaml in (base.replace('global-dev', 'edited'), base):
            for root in (reference, native):
                (root / 'build.yaml').write_text(yaml)
            check(reference, native, [])
        # Root-level package overrides also replace configs and definitions.
        for root in (reference, native):
            (root / 'settings_builder_app.build.yaml').write_text(base.replace('global-dev', 'override'))
        check(reference, native, [])
        for root in (reference, native):
            (root / 'settings_builder_app.build.yaml').unlink()
        check(reference, native, [])

        # Only files are package config overrides, not similarly named dirs.
        for root in (reference, native):
            (root / 'ignored.build.yaml').mkdir()
        check(reference, native, [])
        for root in (reference, native):
            (root / 'ignored.build.yaml').rmdir()

        # Errors preserve stock codes/output retention in auto/dart, and rust
        # fails explicitly. Syntax failures route before native acquisition.
        bad_cases = [['--define'], ['--define=x=y'], ['--release=true'], ['--config'],
                     ['--config=missing'], ['--define=:settings=x=1',
                       '--define=settings_builder_app|settings=x=2']]
        for flags in bad_cases:
            code, _ = execute(stock(reference, [*flags, '--force-jit']), reference)
            assert code != 0, flags
            for mode in ('auto', 'dart'):
                actual, output = execute(launcher(native, mode, flags=[*flags, '--force-jit']), native)
                assert actual == code, (flags, mode, code, actual, output)
                assert outputs(reference) == outputs(native), (flags, mode)
            actual, _ = execute(launcher(native, 'rust', flags=[*flags, '--force-jit']), native)
            assert actual != 0, flags
        # Unknown builder is a stock warning, not an enabling switch.
        output = check(reference, native, ['--define=absent=x=42'])
        assert 'Ignoring options overrides for unknown builder' in output, output
        # Non-JSON values are exact strings, invalid builder option types fail
        # as a whole (probe refuses the mapping, then auto invokes stock).
        for mode in ('auto', 'dart'):
            flags = ['--config=named', '--release', '--define=:settings=value=forwarded']
            check(reference, native, flags, mode=mode)
        for flags in (['--define=:settings=suffix=42'],):
            code, _ = execute(stock(reference, [*flags, '--force-jit']), reference)
            actual, output = execute(launcher(native, 'auto', flags=[*flags, '--force-jit']), native)
            assert actual == code != 0, output
            assert outputs(reference) == outputs(native)

        # Missing/invalid configuration never partially applies options.
        for root in (reference, native):
            (root / 'build.invalid.yaml').write_text('targets: [invalid yaml')
        flags = ['--config=invalid', '--release', '--force-jit']
        code, _ = execute(stock(reference, flags), reference)
        actual, output = execute(launcher(native, 'auto', flags=flags), native)
        assert actual == code != 0, output
        assert outputs(reference) == outputs(native)

        # Early fallback: an unsupported filter plus all configuration flags.
        early, early_stock = temporary / 'early', temporary / 'early-stock'
        prepare(early)
        prepare(early_stock)
        flags = ['--config=named', '--release', '--define=:settings=value=early',
                 '--build-filter=lib/a.alternate', '--force-jit']
        expected_code, _ = execute(stock(early_stock, flags), early_stock)
        code, output = execute(launcher(early, 'auto', flags=flags), early,
                               {**ENV, 'BUILD_RUNNER_ACCELERATOR_BIN': '/missing-native-frontend'})
        assert 'unsupported native CLI' in output and 'unavailable' not in output, output
        assert code == expected_code == 0, output
        assert not (early / '.dart_tool/build_runner_accelerator/builder-manifest.json').exists()
        assert outputs(early_stock) == outputs(early)
        # A missing selected file is known before acquisition or generation.
        missing = temporary / 'missing'
        prepare(missing)
        flags = ['--config=missing', '--release', '--define=:settings=value=missing', '--force-jit']
        expected_code, _ = execute(stock(missing, flags), missing)
        code, output = execute(launcher(missing, 'auto', flags=flags), missing,
                               {**ENV, 'BUILD_RUNNER_ACCELERATOR_BIN': '/missing-native-frontend'})
        assert code == expected_code != 0, output
        assert 'configuration file not found' in output and 'unavailable' not in output, output
        assert not (missing / '.dart_tool/build_runner_accelerator/builder-manifest.json').exists()
        ok(launcher(missing, 'auto', command='prewarm', flags=flags), missing)
        assert outputs(missing) == {}

        # Late fallback: stock supports root-relative factory imports, native
        # rejects this manifest. Config replaces targets but not the factory.
        late, late_stock = temporary / 'late', temporary / 'late-stock'
        for root in (late, late_stock):
            prepare(root)
            path = root / 'build.yaml'
            path.write_text(path.read_text().replace('package:settings_builder_app/builder.dart', 'lib/builder.dart'))
        flags = ['--config=named', '--release', '--define=:settings=value=late']
        check(late_stock, late, flags, mode='auto')
        assert (late / '.dart_tool/build_runner_accelerator/dynamic_worker.dart').exists()
        code, _ = execute(launcher(late, 'rust', flags=flags), late)
        assert code != 0

        # Successfully generated empty manifest also takes the late fallback.
        empty, empty_stock = temporary / 'empty', temporary / 'empty-stock'
        for root in (empty, empty_stock):
            prepare(root)
            (root / 'build.empty.yaml').write_text(
                'targets:\n  $default:\n    builders:\n'
                '      settings_builder_app:settings: {enabled: false}\n'
                '      settings_builder_app:marker: {enabled: false}\n')
        flags = ['--config=empty', '--release', '--define=:settings=value=empty']
        check(empty_stock, empty, flags, mode='auto')
        manifest = json.loads((empty / '.dart_tool/build_runner_accelerator/builder-manifest.json').read_text())
        assert manifest['builders'] == []
        code, _ = execute(launcher(empty, 'rust', flags=flags), empty)
        assert code != 0

        # Prewarm writes no outputs, including detached prewarm. AOT and JIT
        # are compared after changing settings in the same workspace/cache.
        warmed = temporary / 'prewarm'
        prepare(warmed)
        flags = ['--config=named', '--release', '--define=:settings=value=warmed']
        ok(launcher(warmed, 'rust', command='prewarm', flags=flags), warmed)
        assert outputs(warmed) == {}
        check(reference, warmed, flags, compile_flag='--force-aot')
        check(reference, warmed, [], compile_flag='--force-aot')
        check(reference, warmed, flags)
        ok(launcher(warmed, 'rust', command='prewarm', flags=[*flags, '--background']), warmed)
        deadline = time.monotonic() + 180
        prewarm_log = warmed / '.dart_tool/build_runner_accelerator/prewarm.log'
        while not prewarm_log.exists() or 'AOT prewarm ready:' not in prewarm_log.read_text():
            assert time.monotonic() < deadline, prewarm_log.read_text() if prewarm_log.exists() else ''
            time.sleep(.1)
        manifest = json.loads((warmed / '.dart_tool/build_runner_accelerator/builder-manifest.json').read_text())
        assert manifest['builders'][0]['options']['value'] == 'warmed'
        check(reference, warmed, flags, compile_flag='--force-aot')

        # Watch reloads selected configuration and default configuration. Keep
        # an AOT worker resident to exercise artifact/catalog invalidation.
        for selected in (False, True):
            flags = ['--config=named'] if selected else []
            check(reference, native, flags, compile_flag='--force-aot')
            path = 'build.named.yaml' if selected else 'build.yaml'
            before = (reference / path).read_text()
            after = (before.replace('named-dev', 'watch-new') if selected
                     else before.replace('global-dev', 'watch-new'))
            def edit(root):
                (root / path).write_text(after)
            edit(reference)
            ok(stock(reference, [*flags, '--force-aot']), reference)
            expected = outputs(reference)
            (reference / path).write_text(before)
            ref_watch = watch(reference, stock(reference, [*flags, '--force-aot'], 'watch'), edit, expected)
            actual = watch(native, launcher(native, 'rust', 'watch', [*flags, '--force-aot']), edit, expected)
            assert actual == ref_watch
            # Restore input/config then ensure the restored build matches.
            for root in (reference, native):
                (root / path).write_text(before)
                (root / 'lib/a.txt').write_text('a\n')
            check(reference, native, flags)
        watch_topology_boundary(temporary)
        print('settings-compatibility: PASS', flush=True)
    except BaseException:
        print(f'retained failing settings workspaces: {temporary}', flush=True)
        raise
    else:
        shutil.rmtree(temporary)


if __name__ == '__main__':
    main()
