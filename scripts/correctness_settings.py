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
    named = (root / 'build.named.yaml').read_text()
    for path, content in {
        'build.dir/name.yaml': named,
        'build.dir/target/name.yaml': named,
        'build.other/name.yaml': named.replace('named-dev', 'other-path-dev'),
        'name.yaml': named,
        'build.../name.yaml': named,
        'build./absolute/name.yaml': named,
        'build.=named.yaml': named,
        'build..yaml': named,
        'build.--force-aot.yaml': named,
        'build.off.yaml': '''targets:
  $default:
    builders:
      settings_builder_app:settings:
        enabled: false
      settings_builder_app:marker:
        enabled: false
''',
    }.items():
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
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


def watch_nested_reserved_directory(temporary):
    # Explicit config files must not disappear behind native's generic target
    # directory filter. Stock recognizes this canonical nested path directly.
    reference, native = temporary / 'nested-watch-stock', temporary / 'nested-watch-native'
    prepare(reference)
    prepare(native)
    flags = ['-cdir/target/name', '--force-jit']
    check(reference, native, flags[:-1])
    path = 'build.dir/target/name.yaml'
    before = (reference / path).read_text()
    after = before.replace('named-dev', 'nested-watch-new')
    def edit(root):
        (root / path).write_text(after)
    edit(reference)
    ok(stock(reference, flags), reference)
    expected = outputs(reference)
    (reference / path).write_text(before)
    actual_stock = watch(reference, stock(reference, flags, 'watch'), edit, expected)
    actual_native = watch(native, launcher(native, 'rust', 'watch', flags), edit, expected)
    assert actual_native == actual_stock
    print('settings nested config watch: PASS', flush=True)


def watch_normalized_config_paths(temporary, only=None):
    # 2.16.2 reload detection compares the raw spelling, while config loading
    # uses a normalized AssetId. A source edit keeps the old plan; build.yaml
    # subsequently reloads the selected file. Compare each observable state.
    for index, (key, path) in enumerate(((r'dir\name', 'build.dir/name.yaml'),
                                        ('dir/../name', 'name.yaml'),
                                        ('dir/name', 'build.dir/name.yaml'))):
        if only is not None and index not in only:
            continue
        snapshots = []
        for mode in ('stock', 'rust'):
            root = temporary / f'normalized-watch-{index}-{mode}'
            prepare(root)
            if index == 2:
                # Watch attributes nested package events to the child package,
                # so this selected root AssetId doesn't trigger a root reload.
                child = root / 'build.dir'
                (child / 'lib').mkdir()
                (child / 'pubspec.yaml').write_text(
                    'name: settings_configs\nenvironment:\n  sdk: ">=3.11.0 <4.0.0"\n')
                pubspec = root / 'pubspec.yaml'
                pubspec.write_text(pubspec.read_text().replace('dev_dependencies:\n',
                    'dev_dependencies:\n  settings_configs:\n    path: build.dir\n'))
                ok([DART, 'pub', 'get', '--offline'], root)
            flags = [f'-c{key}', '-rr', '--force-jit']
            log = root / 'normalized-watch.log'
            args = stock(root, flags, 'watch') if mode == 'stock' else launcher(root, mode, 'watch', flags)
            with log.open('w') as stream:
                proc = subprocess.Popen(args, cwd=root, env=ENV, stdout=stream,
                                        stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    wait(lambda: ('Built with build_runner' in log.read_text() if mode == 'stock'
                                  else 'Watching ' in log.read_text()), proc, log)
                    stages = [outputs(root)]
                    selected = root / path
                    selected.write_text(selected.read_text().replace('named-release', 'normalized-new'))
                    # An unrelated Dart source change is not a config reload
                    # (nor a build-script change), even though watch sees it.
                    (root / 'lib/unrelated.dart').write_text('void main() {}\n')
                    (root / 'lib/a.txt').write_text('normalized input\n')
                    wait(lambda: outputs(root) and all(json.loads(data)['input'] == 'normalized input\n'
                                                       for data in outputs(root).values()), proc, log)
                    stages.append(outputs(root))
                    assert all(json.loads(data)['options']['value'] == 'named-release'
                               for data in stages[-1].values()), (mode, stages, log.read_text())
                    ordinary = root / 'build.yaml'
                    ordinary.write_text(ordinary.read_text() + '\n# recognized config change\n')
                    wait(lambda: outputs(root) and all(json.loads(data)['options']['value'] == 'normalized-new'
                                                       for data in outputs(root).values()), proc, log)
                    stages.append(outputs(root))
                    snapshots.append(stages)
                finally:
                    if proc.poll() is None:
                        os.killpg(proc.pid, signal.SIGINT)
                    proc.wait(timeout=15)
        assert snapshots[0] == snapshots[1], (key, snapshots)




SETTINGS_CASES = [[], [], ['--release'], ['--no-release'],
         ['--define', ':settings=value=cli'],
         ['--define=:settings=nested={"z":[1,true,null],"a":{"y":2,"b":3}}',
          '--define=:settings=text=a=b,c', '--define=:settings=empty='],
         ['--config', 'named'], ['--config=named', '--release'],
         ['--config='], ['--config', '--force-aot'],
         ['-cnamed', '-rr'], ['-dr', '-cdir/name'],
         [r'-cdir\name'], ['--config=other/name'], ['-cdir/name'],
         ['--config=dir/../name'], ['--config=../name'],
         ['-c/absolute/name'], ['-c=named'],
         ['--config=x/../../invalid', '-cnamed'],
         ['--config=named', '--define=:marker=enabled=true'],
         ['--config=missing', '-c', 'named', '-r', '--no-release', '--release',
          '--define=settings_builder_app|settings=value=combined'],
         ['--define=:settings=emit=false'], [], ['--config=named'], [], [],
         ['--config=off'], ['--config=off'], [], []]

CASE_GROUPS = {
    'values': tuple(range(0, 8)),
    'compact': tuple(range(8, 13)),
    'paths': tuple(range(13, 20)),
    'precedence': tuple(range(20, len(SETTINGS_CASES))),
}
WATCH_CONFIGS = {'watch-default': None, 'watch-named': 'named', 'watch-nested': 'dir/name'}
NORMALIZED_WATCH = {'watch-backslash': 0, 'watch-dot': 1, 'watch-package': 2}
GROUPS = (*CASE_GROUPS, 'files', 'errors', 'fallback', 'compile',
          *WATCH_CONFIGS, 'watch-reserved', *NORMALIZED_WATCH, 'watch-topology')


def configuration_cases(reference, native, indices):
    # A sequence owns one pair of workspaces. Never parallelize transitions
    # within a lane: manifests, graph state and output ownership must persist.
    for index in indices:
        flags = SETTINGS_CASES[index]
        output = check(reference, native, flags)
        if index in (1, 26, 28, len(SETTINGS_CASES) - 1):
            assert 'No work to do (Rust frontend)' in output, output
        if index in (27, 28):
            assert outputs(reference) == outputs(native) == {}, (flags, output)
        if index == 29:
            assert outputs(native), output
        print(f'settings case {index}: PASS {flags}', flush=True)


def configuration_inactive_factories(reference, native):
    # Stock does not instantiate disabled factories. Keep this regression on
    # the same workspaces so the old per-factory action outputs really exist.
    for root in (reference, native):
        builder = root / 'lib/builder.dart'
        builder.write_text(builder.read_text().replace(
            'Builder settings(BuilderOptions options) => SettingsBuilder(options);',
            "Builder settings(BuilderOptions options) {\n"
            "  if (options.config['must_not_instantiate'] == true) {\n"
            "    throw StateError('disabled factory was instantiated');\n"
            "  }\n"
            "  return SettingsBuilder(options);\n"
            "}"))
        disabled = root / 'build.off.yaml'
        disabled.write_text(disabled.read_text() + '''global_options:
  settings_builder_app:settings:
    options: {must_not_instantiate: true}
''')
        (root / 'build.partial.yaml').write_text(disabled.read_text().replace(
            'settings_builder_app:marker:\n        enabled: false',
            'settings_builder_app:marker:\n        enabled: true'))
        config = root / 'build.yaml'
        config.write_text(config.read_text()
            .replace('builder_factories: [settings]', 'builder_factories: [settings, marker]')
            .replace("build_extensions: {'.txt': ['.out']}",
                     "build_extensions: {'.txt': ['.out', '.marker']}")
            .replace('    auto_apply: root_package\n    build_to: source\nglobal_options:',
                     '    auto_apply: none\n    build_to: source\nglobal_options:'))
    check(reference, native, [])
    check(reference, native, ['--config=partial'])
    assert set(outputs(native)) == {'lib/a.marker', 'lib/b.marker'}
    check(reference, native, ['--config=off'])
    assert outputs(reference) == outputs(native) == {}
    output = check(reference, native, ['--config=off'])
    assert 'No work to do (Rust frontend)' in output, output
    check(reference, native, [])
    assert outputs(native)
    output = check(reference, native, [])
    assert 'No work to do (Rust frontend)' in output, output
    print('settings inactive multi-factory lifecycle: PASS', flush=True)


def configuration_files(reference, native):
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


def configuration_errors(reference, native):
    # Errors preserve stock codes/output retention in auto/dart, and rust
    # fails explicitly. Syntax failures route before native acquisition.
    bad_cases = [['--define'], ['--define=x=y'], ['--release=true'], ['--config'],
                 ['--config=missing'], ['-cdir/missing'], ['--config=x/../../outside'],
                 ['-rcnamed'], ['-rd=1'], ['--define=:settings=x=1',
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
        flags = ['-cdir/name', '-rr', '--define=:settings=value=forwarded']
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


def configuration_fallback(temporary):
    # Early fallback: an unsupported filter plus all configuration flags.
    early, early_stock = temporary / 'early', temporary / 'early-stock'
    prepare(early)
    prepare(early_stock)
    flags = ['-cdir/name', '-rr', '--define=:settings=value=early',
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
    flags = [r'-cdir\missing', '-rr', '--define=:settings=value=missing', '--force-jit']
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
    flags = [r'-cdir\name', '-rr', '--define=:settings=value=late']
    check(late_stock, late, flags, mode='auto')
    assert (late / '.dart_tool/build_runner_accelerator/dynamic_worker.dart').exists()
    code, _ = execute(launcher(late, 'rust', flags=flags), late)
    assert code != 0

    # A valid empty manifest stays native after disabling all builders.
    empty, empty_stock = temporary / 'empty', temporary / 'empty-stock'
    for root in (empty, empty_stock):
        prepare(root)
        (root / 'build.dir/empty.yaml').write_text(
            'targets:\n  $default:\n    builders:\n'
            '      settings_builder_app:settings: {enabled: false}\n'
            '      settings_builder_app:marker: {enabled: false}\n')
    flags = ['-cdir/empty', '-rr', '--define=:settings=value=empty']
    check(empty_stock, empty, flags, mode='auto')
    manifest = json.loads((empty / '.dart_tool/build_runner_accelerator/builder-manifest.json').read_text())
    assert manifest['builders'] == []
    check(empty_stock, empty, flags, mode='rust')
    assert outputs(empty) == {}
    configuration_inactive_factories(empty_stock, empty)


def configuration_compile(temporary, reference):
    # Prewarm writes no outputs, including detached prewarm. AOT and JIT
    # are compared after changing settings in the same workspace/cache.
    warmed = temporary / 'prewarm'
    prepare(warmed)
    flags = [r'-cdir\name', '-rr', '--define=:settings=value=warmed']
    ok(launcher(warmed, 'rust', command='prewarm', flags=flags), warmed)
    assert outputs(warmed) == {}
    check(reference, warmed, flags, compile_flag='--force-aot')
    check(reference, warmed, ['-cother/name', '-rr'], compile_flag='--force-aot')
    check(reference, warmed, ['-cdir/../name'], compile_flag='--force-aot')
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
    retained = outputs(warmed)
    ok(launcher(warmed, 'rust', command='prewarm',
                flags=['--config=off', '--force-aot']), warmed)
    assert outputs(warmed) == retained
    check(reference, warmed, ['--config=off'], compile_flag='--force-aot')
    assert outputs(reference) == outputs(warmed) == {}
    check(reference, warmed, [])
    assert outputs(warmed)


def configuration_watch(reference, native, selected, compile_flag='--force-aot'):
    flags = [f'-c{selected}'] if selected else []
    check(reference, native, flags, compile_flag=compile_flag)
    path = f'build.{selected}.yaml' if selected else 'build.yaml'
    before = (reference / path).read_text()
    after = (before.replace('named-dev', 'watch-new') if selected
             else before.replace('global-dev', 'watch-new'))
    def edit(root):
        (root / path).write_text(after)
    edit(reference)
    ok(stock(reference, [*flags, compile_flag]), reference)
    expected = outputs(reference)
    (reference / path).write_text(before)
    ref_watch = watch(reference, stock(reference, [*flags, compile_flag], 'watch'), edit, expected)
    actual = watch(native, launcher(native, 'rust', 'watch', [*flags, compile_flag]), edit, expected)
    assert actual == ref_watch
    # Restore input/config then ensure the restored build matches.
    for root in (reference, native):
        (root / path).write_text(before)
        (root / 'lib/a.txt').write_text('a\n')
    check(reference, native, flags)


def watch_parent_dependency(temporary, compile_flag='--force-jit'):
    """A root example config belongs to the app, despite its ancestor dependency."""
    roots = []
    for mode in ('stock', 'native'):
        parent = temporary / f'parent-watch-{mode}'
        parent.mkdir()
        (parent / 'lib').mkdir()
        (parent / 'pubspec.yaml').write_text(
            'name: settings_parent\nenvironment:\n  sdk: ">=3.11.0 <4.0.0"\n')
        root = parent / 'example'
        prepare(root)
        pubspec = root / 'pubspec.yaml'
        pubspec.write_text(pubspec.read_text().replace('dev_dependencies:\n',
            'dev_dependencies:\n  settings_parent:\n    path: ..\n'))
        ok([DART, 'pub', 'get', '--offline'], root)
        roots.append(root)
    configuration_watch(*roots, 'named', compile_flag=compile_flag)
    print('settings parent dependency watch: PASS', flush=True)


def workspace_pair(temporary):
    reference, native = temporary / 'stock', temporary / 'native'
    prepare(reference)
    prepare(native)
    return reference, native


def run_group(group, temporary):
    if group == 'all':
        reference, native = workspace_pair(temporary)
        configuration_cases(reference, native, range(len(SETTINGS_CASES)))
        configuration_files(reference, native)
        configuration_errors(reference, native)
        configuration_fallback(temporary)
        configuration_compile(temporary, reference)
        for selected in WATCH_CONFIGS.values():
            configuration_watch(reference, native, selected)
        watch_parent_dependency(temporary)
        watch_nested_reserved_directory(temporary)
        watch_normalized_config_paths(temporary)
        watch_topology_boundary(temporary)
    elif group in CASE_GROUPS:
        reference, native = workspace_pair(temporary)
        configuration_cases(reference, native, CASE_GROUPS[group])
        # Also restore the default and prove a no-op within every CI sequence.
        if SETTINGS_CASES[CASE_GROUPS[group][-1]]:
            check(reference, native, [])
        output = check(reference, native, [])
        assert 'No work to do (Rust frontend)' in output, output
    elif group in ('files', 'errors'):
        reference, native = workspace_pair(temporary)
        # Error retention must compare real existing outputs, not empty sets.
        check(reference, native, [])
        if group == 'files':
            configuration_files(reference, native)
        else:
            configuration_errors(reference, native)
    elif group == 'fallback':
        configuration_fallback(temporary)
    elif group == 'compile':
        reference = temporary / 'stock'
        prepare(reference)
        configuration_compile(temporary, reference)
    elif group == 'watch-named':
        # Exercise the same named/AOT sequence with an ancestor dependency;
        # don't duplicate the full sequence on the CI runner.
        watch_parent_dependency(temporary, compile_flag='--force-aot')
    elif group in WATCH_CONFIGS:
        reference, native = workspace_pair(temporary)
        configuration_watch(reference, native, WATCH_CONFIGS[group])
    elif group == 'watch-reserved':
        watch_nested_reserved_directory(temporary)
    elif group in NORMALIZED_WATCH:
        watch_normalized_config_paths(temporary, only=(NORMALIZED_WATCH[group],))
    elif group == 'watch-topology':
        watch_topology_boundary(temporary)
    else:
        raise ValueError(f'Unknown settings case group: {group}')


def main():
    group = os.environ.get('SETTINGS_CASE_GROUP', 'all')
    if group != 'all' and group not in GROUPS:
        raise ValueError(f'Unknown SETTINGS_CASE_GROUP: {group}; expected all or {GROUPS}')
    temporary = Path(tempfile.mkdtemp(prefix=f'settings-{group}-'))
    ENV.setdefault('BUILD_RUNNER_ACCELERATOR_CACHE', str(temporary / 'accelerator-cache'))
    print(f'settings group={group} workspaces: {temporary}', flush=True)
    started = time.monotonic()
    try:
        run_group(group, temporary)
        print(f'settings-compatibility: PASS group={group} elapsed={time.monotonic() - started:.1f}s', flush=True)
    except BaseException:
        print(f'retained failing settings workspaces: {temporary}', flush=True)
        raise
    else:
        shutil.rmtree(temporary)


if __name__ == '__main__':
    main()
