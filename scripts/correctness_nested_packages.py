#!/usr/bin/env python3
"""Stock/native nested path-package source selection and transactional lifecycle."""
from collections import Counter
from functools import partial
from pathlib import Path
import os
import shutil
import sys
import struct
import subprocess
import tempfile
import time
from correctness_build_filter import (
    DART, copy_fixture, execute, launcher, outputs, history,
    history_path, check, watch, wait, stop_all, fixture_env,
)


def setup(root, sources='default', enabled=True, location='cache'):
    copy_fixture(root)
    dep = root / 'dep'
    (dep / 'lib').mkdir(parents=True)
    (dep / 'pubspec.yaml').write_text('name: filter_dep\nenvironment:\n  sdk: ">=3.11.0 <4.0.0"\n')
    (dep / 'build.yaml').write_text('targets:\n  $default:\n    builders:\n' + ''.join(
        f'      build_filter_app:{builder}:\n        enabled: {str(enabled).lower()}\n'
        for builder in ('seed', 'finish')))
    for name in ('a', 'common'):
        (dep / f'lib/{name}.txt').write_text(f'dependency {name}\n')
    pub = root / 'pubspec.yaml'
    pub.write_text(pub.read_text().replace('dependencies:\n', 'dependencies:\n  filter_dep:\n    path: dep\n', 1))
    cfg = root / 'build.yaml'
    # Dependencies can only build to cache. Keep the final root phase a source
    # output in the mixed lane, without enabling that phase in the dependency.
    text = cfg.read_text().replace('build_to: source', 'build_to: cache')
    if location == 'source':
        text = text.replace("build_to: cache\n    required_inputs", "build_to: source\n    required_inputs")
    text += '''  view:
    import: 'package:build_filter_app/builder.dart'
    builder_factories: [nestedView]
    build_extensions: {'.probe': ['.final']}
    auto_apply: root_package
    build_to: source
'''
    if sources != 'default':
        patterns = '["lib/**", "dep/**"]' if sources == 'overlap' else f'["{sources}"]'
        text += f'\ntargets:\n  $default:\n    sources: {patterns}\n'
    cfg.write_text(text)
    (root / 'lib/view.probe').write_text('a\n')
    (root / 'lib/.hidden.txt').write_text('hidden root source\n')
    (dep / 'lib/.hidden.txt').write_text('hidden dependency source\n')
    code, log = execute([DART, 'pub', 'get', '--offline'], root)
    assert code == 0, log


def pair(tmp, name, **kwargs):
    roots = [tmp / (name + suffix) for suffix in ('-stock', '-native')]
    for root in roots: setup(root, **kwargs)
    return roots


def lifecycle(tmp, sources, enabled, location):
    print(f'nested-packages: RUN lifecycle {sources} dependency={enabled} {location}', flush=True)
    name = sources.replace('/', '_').replace('*', 'all')
    stock, native = pair(tmp, f'{name}-{enabled}-{location}', sources=sources, enabled=enabled, location=location)
    check(stock, native)
    alias = 'cache/build_filter_app/dep/lib/a.mid'
    assert (alias in outputs(native)) == (sources == 'overlap')
    assert ('cache/filter_dep/lib/a.mid' in outputs(native)) == enabled
    assert check(stock, native) == Counter()
    for root in (stock, native): (root / 'dep/lib/a.txt').write_text('changed dependency\n')
    check(stock, native)
    for root in (stock, native): (root / 'dep/lib/new.txt').write_text('new dependency\n')
    check(stock, native)
    for root in (stock, native): (root / 'dep/lib/a.txt').write_text('empty\n')
    check(stock, native)
    for root in (stock, native): (root / 'dep/lib/new.txt').unlink()
    check(stock, native)
    assert check(stock, native) == Counter()
    cold_recovery = sources == 'default' and enabled and location == 'cache'
    define = ['--define=:finish=glob_names=true'] if cold_recovery else []
    if cold_recovery:
        # A fresh graph with existing cache files must not revive removed aliases.
        for root in (stock, native):
            state = root / '.dart_tool' / ('build' if root == stock else 'build_runner_accelerator')
            if root == stock:
                shutil.rmtree(state)
            else:
                (state / 'graph-v3.bin').unlink()
        check(stock, native, define)
        assert check(stock, native, define) == Counter()
    flags = ['--build-filter=lib/a.final,package:filter_dep/a.final'] if location == 'cache' else ['--build-filter=lib/a.final']
    flags += define
    check(stock, native, flags)
    assert check(stock, native, flags) == Counter()
    check(stock, native, define)
    assert check(stock, native, define) == Counter()
    print(f'nested-packages: PASS lifecycle {sources} dependency={enabled} {location}', flush=True)


def graph(root):
    return root / '.dart_tool/build_runner_accelerator/graph-v3.bin'


def obsolete_state(tmp, location):
    stock, native = [tmp / f'obsolete-{location}-{lane}' for lane in ('stock', 'native')]
    enabled = location == 'cache'
    setup(stock, enabled=enabled, location=location)
    setup(native, sources='overlap', enabled=enabled, location=location)
    sentinel = b'dependency file that must survive obsolete source-output records'
    suffix = 'asset' if location == 'cache' else 'final'
    (stock / f'dep/lib/a.{suffix}').write_bytes(sentinel)
    code, log = execute(launcher(native, 'rust', flags=['--force-jit']), native)
    assert code == 0, log
    assert 'cache/build_filter_app/dep/lib/a.mid' in outputs(native)
    # Disposable graphs cannot authorize deleting old source outputs. Give
    # stock the same pre-existing files; neither build may remove them.
    for source in (native / 'dep/lib').glob('*.final'):
        shutil.copyfile(source, stock / 'dep/lib' / source.name)
    (stock / f'dep/lib/a.{suffix}').write_bytes(sentinel)
    code, log = execute([DART, 'run', 'build_runner', 'build', '--force-jit'], stock)
    assert code == 0, log
    # The binary layout is unchanged: schema 4 records the former overbroad
    # defaults. Include real alias actions, not just an empty old header.
    data = bytearray(graph(native).read_bytes())
    data[9:13] = struct.pack('>I', 4)
    graph(native).write_bytes(data)
    cfg = native / 'build.yaml'
    cfg.write_text(cfg.read_text().split('\ntargets:')[0])
    real = native / f'dep/lib/a.{suffix}'
    real.write_bytes(sentinel)
    stale = native / '.dart_tool/build_runner_accelerator/cache/build_filter_app/dep/lib/a.mid'
    before_graph = graph(native).read_bytes()
    before_outputs = outputs(native)
    (native / 'lib/common.txt').write_text('fail\n')
    code, log = execute(launcher(native, 'rust', flags=['--force-jit']), native)
    assert code != 0 and 'fixture failure' in log, (code, log)
    assert 'invalidating graph schema 4' in log, log
    assert graph(native).read_bytes() == before_graph and outputs(native) == before_outputs
    (native / 'lib/common.txt').write_text('common\n')
    history_path(native).unlink(missing_ok=True)
    code, log = execute(launcher(native, 'rust', flags=['--force-jit']), native)
    assert code == 0, log
    assert not stale.exists() and real.read_bytes() == sentinel
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), log)
    assert history(stock) == history(native), (history(stock), history(native))
    assert check(stock, native) == Counter()
    if location == 'cache': empty_cold_recovery(stock, native)
    print(f'nested-packages: PASS obsolete {location} state/cache recovery', flush=True)


def empty_cold_recovery(stock, native):
    for root in (stock, native):
        for folder in ('lib', 'dep/lib'):
            for source in (root / folder).glob('*.txt'): source.unlink()
        (root / 'lib/view.probe').unlink(missing_ok=True)
        (root / 'lib/other.noise').unlink()
    check(stock, native)
    data = bytearray(graph(native).read_bytes())
    data[9:13] = struct.pack('>I', 4)
    graph(native).write_bytes(data)
    stale = native / '.dart_tool/build_runner_accelerator/cache/build_filter_app/dep/lib/a.mid'
    stale.parent.mkdir(parents=True, exist_ok=True)
    stale.write_text('obsolete output without any current actions')
    assert check(stock, native) == Counter()
    assert not stale.exists()
    assert check(stock, native) == Counter()
    print('nested-packages: PASS empty cold-build artifact cleanup', flush=True)


def failure_and_cancel(tmp):
    stock, native = pair(tmp, 'failure')
    check(stock, native)
    before = outputs(native); saved = graph(native).read_bytes()
    for root in (stock, native):
        (root / 'dep/lib/a.txt').write_text('changed before failure\n')
        (root / 'dep/lib/common.txt').write_text('fail\n')
        history_path(root).unlink(missing_ok=True)
    results = [execute([DART, 'run', 'build_runner', 'build', '--force-jit'], stock),
               execute(launcher(native, 'rust', flags=['--force-jit']), native)]
    assert results[0][0] == results[1][0] != 0, results
    # Stock continues independent downstream actions after a failure; native
    # stops at the failed phase and discards the successful sibling's outputs.
    assert history(native) <= history(stock), (history(stock), history(native), results)
    assert history(native)['filter_dep|lib/a.txt'] == 1
    assert history(native)['filter_dep|lib/common.txt'] == 1
    assert outputs(native) == before and graph(native).read_bytes() == saved
    for root in (stock, native): (root / 'dep/lib/common.txt').write_text('recovered\n')
    native_history = check(stock, native, same_history=False)
    # Stock can retain successful actions from a failed build. Native must
    # additionally redo work whose transaction was discarded.
    assert history(stock) <= native_history, (history(stock), native_history)
    assert check(stock, native) == Counter()
    before = outputs(native); saved = graph(native).read_bytes()
    handles = []
    try:
        for root, mode in ((stock, 'stock'), (native, 'rust')):
            (root / 'dep/lib/common.txt').write_text('cancelled change\n')
            history_path(root).unlink(missing_ok=True)
            log = tmp / (root.name + '-cancel.log'); stream = log.open('w')
            args = [DART, 'run', 'build_runner', 'build', '--force-jit'] if mode == 'stock' else launcher(root, mode, flags=['--force-jit'])
            activity = tmp / (root.name + '-cancel-activity.jsonl')
            proc = subprocess.Popen(args, cwd=root, env=fixture_env(root, {
                'BUILD_FILTER_DELAY_MS': '600000',
                'BUILD_FILTER_ACTIVITY_LOG': str(activity),
            }), stdout=stream, stderr=stream, start_new_session=True)
            handles.append((proc, log, stream))
            wait(lambda p=activity: p.exists() and 'start' in p.read_text(), proc, log)
    finally:
        stop_all(handles)
    codes = [handle[0].returncode for handle in handles]
    normalized = [128 - code if code < 0 else code for code in codes]
    assert normalized[0] == normalized[1] == 130, codes
    assert history(stock) == history(native) == Counter()
    assert outputs(native) == before and graph(native).read_bytes() == saved
    check(stock, native)
    assert check(stock, native) == Counter()
    print('nested-packages: PASS failure/cancellation and subsequent builds', flush=True)


def assert_watch_ignores_outside_sources(roots, handles):
    positions = [handle[1].stat().st_size for handle in handles]
    before_outputs = outputs(roots[0])
    before_history = history(roots[0])
    for value in ('created', 'edited', None):
        for root in roots:
            for folder in ('.git', 'build', 'target'):
                path = root / folder / 'watch-unrelated.txt'
                path.parent.mkdir(exist_ok=True)
                if value is None: path.unlink()
                else: path.write_text(value)
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            for (proc, log, _), position in zip(handles, positions):
                assert proc.poll() is None, log.read_text()
                added = log.read_text()[position:]
                assert 'Change detected; rebuilding' not in added and 'Built with build_runner' not in added, added
            time.sleep(.05)
        for root in roots:
            assert outputs(root) == before_outputs
            assert history(root) == before_history


def read_barrier_env(root):
    return {f'BUILD_FILTER_READ_BARRIER_{name.upper()}': str(root.parent / f'{root.name}-{name}')
            for name in ('arm', 'reached', 'release')}


def watch_recovers_removed_source_output(roots, handles):
    for index, (root, handle) in enumerate(zip(roots, handles)):
        env = read_barrier_env(root)
        arm, reached, release = (Path(env[f'BUILD_FILTER_READ_BARRIER_{name}'])
                                 for name in ('ARM', 'REACHED', 'RELEASE'))
        output = root / 'lib/view.final'
        expected = output.read_bytes()
        marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
        old = handle[1].read_text().count(marker)
        arm.write_text('pause after reading common.side')
        (root / 'dep/lib/common.txt').write_text('changed during watch build\n')
        try:
            wait(reached.exists, handle[0], handle[1])
            output.unlink()
        finally:
            release.write_text('continue build')
        wait(lambda: output.exists() and output.read_bytes() == expected
             and handle[1].read_text().count(marker) >= old + 2,
             handle[0], handle[1], timeout=20)
    assert outputs(roots[0]) == outputs(roots[1])
    assert history(roots[0]) == history(roots[1])


def watch_lifecycle(tmp, sources='default', overlap=False, excluded=False, input_path='dep/lib/new.txt'):
    name = 'overlap' if overlap else 'excluded' if excluded else sources.replace('/', '_').replace('*', 'all')
    stock, native = pair(tmp, 'watch-' + name, sources=sources)
    for root in (stock, native): (root / input_path).parent.mkdir(parents=True, exist_ok=True)
    if sources == 'lib/**':
        for root in (stock, native):
            cfg = root / 'build.yaml'
            cfg.write_text(cfg.read_text().replace('sources: ["lib/**"]',
                'sources: {include: ["lib/**"], exclude: ["lib/view.final"]}'))
    if excluded:
        for root in (stock, native):
            cfg = root / 'build.yaml'
            cfg.write_text(cfg.read_text().replace('sources: ["**"]', 'sources:\n      include: ["**"]\n      exclude: ["**/.dart_tool/**", "dep/**"]'))
    if overlap:
        code, log = execute(launcher(native, 'rust', 'watch', ['--force-jit']), native)
        assert code != 0 and 'watch source sets may overlap' in log, (code, log)
        assert not graph(native).exists() and outputs(native) == {}
    def start(root, stock_lane):
        env = read_barrier_env(root) if sources == 'lib/**' else None
        if stock_lane or overlap:
            command = None if stock_lane else launcher(root, 'auto', 'watch', ['--force-jit'])
            handle = watch(root, 'stock', (), command=command, extra_env=env)
            if not stock_lane:
                assert 'using Dart fallback' in handle[1].read_text()
                assert not graph(root).exists()
            return handle
        return watch(root, 'rust', (), extra_env=env)
    handles = []
    try:
        for root in (stock, native): handles.append(start(root, root == stock))
        assert outputs(stock) == outputs(native)
        if sources == 'default': assert_watch_ignores_outside_sources((stock, native), handles)
        for relative, value in [(input_path, 'watch add\n'), (input_path, 'watch edit\n'), (input_path, None)]:
            for root, handle in zip((stock, native), handles):
                old = handle[1].read_text().count('Built with build_runner' if root == stock or overlap else 'Build completed (Rust frontend)')
                p = root / relative
                if value is None: p.unlink()
                else: p.write_text(value)
                marker = 'Built with build_runner' if root == stock or overlap else 'Build completed (Rust frontend)'
                wait(lambda h=handle, n=old, m=marker: h[1].read_text().count(m) > n, handle[0], handle[1])
            assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native), (history(stock), history(native))
        if sources == 'lib/**': watch_recovers_removed_source_output((stock, native), handles)
    finally:
        stop_all(handles)
    handles = []
    try:
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
            handles.append(start(root, root == stock))
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native), (history(stock), history(native))
        if not overlap: assert history(native) == Counter(), history(native)
        if sources == 'default': assert_watch_ignores_outside_sources((stock, native), handles)
    finally:
        stop_all(handles)
    print(f'nested-packages: PASS watch {name} add/edit/delete/restart', flush=True)


def builder_transition(tmp):
    stock, native = pair(tmp, 'builder-transition')
    check(stock, native)
    for enabled in (False, True):
        for root in (stock, native):
            cfg = root / 'dep/build.yaml'
            old, new = ('true', 'false') if not enabled else ('false', 'true')
            cfg.write_text(cfg.read_text().replace('enabled: ' + old, 'enabled: ' + new))
        check(stock, native)
        assert ('cache/filter_dep/lib/a.mid' in outputs(native)) == enabled
        assert check(stock, native) == Counter()
    print('nested-packages: PASS incremental dependency builder enablement', flush=True)


def dependency_glob(tmp):
    stock, native = pair(tmp, 'dependency-glob')
    for root in (stock, native):
        cfg = root / 'build.yaml'
        head, view = cfg.read_text().split('  view:')
        cfg.write_text(head + '  view:' + view.replace('build_to: source', 'build_to: cache') +
                       "    required_inputs: ['.post']\n" + '''  private_seed:
    import: 'package:build_filter_app/builder.dart'
    builder_factories: [nestedPrivateSeed]
    build_extensions: {'^lib/{{}}.txt': ['lib/{{}}.post', 'test/{{}}.post']}
    auto_apply: root_package
    build_to: cache
''')
        dep_cfg = root / 'dep/build.yaml'
        dep_cfg.write_text('additional_public_assets: [test/published/**]\n' + dep_cfg.read_text().replace(
            '  $default:\n', '  $default:\n    sources: [lib/**, test/**]\n') +
            '      build_filter_app:view:\n        enabled: true\n' +
            '      build_filter_app:private_seed:\n        enabled: true\n')
        for path in ('lib/view.probe', 'dep/lib/view.probe'):
            (root / path).write_text('a\nprivate-outputs\n')
        (root / 'dep/test/published').mkdir(parents=True)
        (root / 'dep/test/a.txt').write_text('private dependency input\n')
        (root / 'dep/test/published/a.txt').write_text('published dependency input\n')
    check(stock, native)
    assert b'filter_dep|lib/a.txt' in outputs(native)['cache/filter_dep/lib/view.final']

    def check_dependency_visibility(published):
        result = outputs(native)
        expected_private = b'filter_dep|test/a.post:false:<invalid>'
        assert expected_private in result['cache/filter_dep/test/a.post']
        assert expected_private in result['cache/filter_dep/lib/view.final']
        for suffix in ('mid', 'side', 'final'):
            assert f'cache/filter_dep/test/a.{suffix}' not in result
            assert (f'cache/filter_dep/test/published/a.{suffix}' in result) == published
        expected = (b'filter_dep|test/published/a.txt:true:published dependency input' if published
                    else b'filter_dep|test/published/a.txt:false:<missing>')
        for path in ('cache/filter_dep/lib/view.final', 'cache/build_filter_app/lib/view.final'):
            content = result[path]
            assert b'filter_dep|test/a.txt:false:<invalid>' in content, content
            assert expected in content, content
            if path == 'cache/filter_dep/lib/view.final':
                assert b'filter_dep|test/a.txt\n' not in content, content
                assert (b'filter_dep|test/published/a.txt\n' in content) == published, content

    check_dependency_visibility(True)
    assert history(native)['filter_dep|test/a.txt'] == 0
    assert history(native)['filter_dep|test/published/a.txt'] == 1
    assert history(native)['private_seed|filter_dep|lib/a.txt'] == 1
    assert check(stock, native) == Counter()
    for root in (stock, native):
        (root / 'dep/lib/new.txt').write_text('glob addition\n')
        (root / 'dep/test/published/a.txt').write_text('published dependency input edited\n')
    check(stock, native, ['--build-filter=lib/view.final,package:filter_dep/view.final'])
    check_dependency_visibility(True)
    for root in (stock, native):
        (root / 'dep/lib/new.txt').unlink()
        (root / 'dep/test/published/a.txt').unlink()
    check(stock, native)
    check_dependency_visibility(False)
    assert check(stock, native) == Counter()
    print('nested-packages: PASS dependency-package glob/read identity', flush=True)


def implementation_sources_boundary(tmp):
    stock, native = pair(tmp, 'implementation-inputs', sources='**')
    code, log = execute(launcher(native, 'rust', flags=['--force-aot']), native)
    assert code != 0 and 'build implementation directories' in log, (code, log)
    assert not graph(native).exists() and outputs(native) == {}
    for _ in range(2):
        check(stock, native, mode='auto')
        assert not graph(native).exists()
    print('nested-packages: PASS implementation-directory input boundary', flush=True)


def modes(tmp):
    for mode in ('auto', 'dart'):
        stock, native = pair(tmp, 'mode-' + mode)
        check(stock, native, mode=mode, native_expected=mode == 'auto')
    print('nested-packages: PASS auto/dart mode selection', flush=True)


def case_groups(tmp):
    return {
        'default-on': (partial(lifecycle, tmp, 'default', True, 'cache'),),
        'default-off': (partial(lifecycle, tmp, 'default', False, 'cache'),),
        'narrow': tuple(partial(lifecycle, tmp, 'lib/**', enabled, 'cache') for enabled in (True, False)),
        'explicit-cache': tuple(partial(lifecycle, tmp, 'overlap', enabled, 'cache') for enabled in (True, False)),
        'source': tuple(partial(lifecycle, tmp, sources, False, 'source') for sources in ('default', 'overlap')),
        'glob': (partial(dependency_glob, tmp),),
        'boundary': (partial(implementation_sources_boundary, tmp),),
        'modes': (partial(modes, tmp),),
        'recovery-state': tuple(partial(obsolete_state, tmp, location) for location in ('cache', 'source')),
        'recovery-actions': (partial(failure_and_cancel, tmp), partial(builder_transition, tmp)),
        'watch-native': (partial(watch_lifecycle, tmp, input_path='dep/lib/build/.new.txt'),
                         partial(watch_lifecycle, tmp, 'lib/**')),
        'watch-boundary': (partial(watch_lifecycle, tmp, 'overlap', overlap=True),
                           partial(watch_lifecycle, tmp, '**', excluded=True)),
    }


def main():
    tmp = Path(tempfile.mkdtemp(prefix='accelerator-nested-'))
    try:
        groups = case_groups(tmp)
        selection = os.environ.get('NESTED_PACKAGE_CASE_GROUP', 'all')
        selected = tuple(groups) if selection == 'all' else tuple(selection.split(','))
        assert len(set(selected)) == len(selected) and set(selected) <= groups.keys(), selection
        for group in selected:
            for case in groups[group]: case()
    except BaseException:
        print(f'nested-packages: retaining failure fixture {tmp}', file=sys.stderr)
        raise
    else:
        shutil.rmtree(tmp)
    print('nested-packages: PASS', flush=True)


if __name__ == '__main__': main()
