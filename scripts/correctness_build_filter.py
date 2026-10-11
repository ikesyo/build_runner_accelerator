#!/usr/bin/env python3
"""Compare build-filter bytes, deletion, status and real builder invocation history."""
from collections import Counter
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from correctness_cli import REPO, DART, ENV, launcher, live


RESOLVER_BUILD_YAML = """builders:
  dart_seed:
    import: 'package:build_filter_app/builder.dart'
    builder_factories: [dartSeed]
    build_extensions: {'.src': ['.dart']}
    auto_apply: root_package
    build_to: source
  resolve:
    import: 'package:build_filter_app/builder.dart'
    builder_factories: [resolve]
    build_extensions: {'.dart': ['.final']}
    auto_apply: root_package
    build_to: source
    required_inputs: ['.dart']
"""

def history_path(root):
    return root.parent / (root.name + '-history.log')


def fixture_env(root):
    return {**ENV, 'BUILD_FILTER_HISTORY': str(history_path(root))}


def execute(args, root):
    result = subprocess.run(args, cwd=root, env=fixture_env(root), text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=300)
    return result.returncode, result.stdout


def prepare(root):
    shutil.copytree(REPO / 'fixtures/build_filter_app', root,
                    ignore=shutil.ignore_patterns('.dart_tool', '.cache', '.pub-cache', '*.mid', '*.side', '*.final', '*.ignored', 'history.log'))
    file = root / 'pubspec.yaml'
    file.write_text(file.read_text().replace('path: ../..', f'path: {REPO}'))
    code, log = execute([DART, 'pub', 'get', '--offline'], root)
    assert code == 0, log


def outputs(root):
    result = {}
    for path in root.rglob('*'):
        if path.is_file() and (path.suffix in ('.mid', '.side', '.final', '.ignored', '.post') or path.name in ('one.dart', 'two.dart', 'shared.dart')):
            relative = str(path.relative_to(root))
            if relative.startswith('.dart_tool/'):
                # Native and stock artifact roots differ; compare logical paths.
                prefixes = ('.dart_tool/build/generated/', '.dart_tool/build_runner_accelerator/cache/')
                prefix = next((p for p in prefixes if relative.startswith(p)), None)
                if prefix is None: continue
                relative = 'cache/' + relative[len(prefix):]
            result[relative] = path.read_bytes()
    return result


def history(root):
    file = history_path(root)
    return Counter(line.removeprefix('build_filter_app|') for line in file.read_text().splitlines()) if file.exists() else Counter()


def check(stock, native, flags=(), mode='rust', same_history=True, compile_flag='--force-jit', native_expected=False):
    assert (stock / 'pubspec.lock').read_text() == (native / 'pubspec.lock').read_text()
    for root in (stock, native): history_path(root).unlink(missing_ok=True)
    reference = execute([DART, 'run', 'build_runner', 'build', compile_flag, *flags], stock)
    actual = execute(launcher(native, mode, flags=[compile_flag, *flags]), native)
    assert actual[0] == reference[0] == 0, (flags, reference, actual)
    assert outputs(stock) == outputs(native), (flags, outputs(stock), outputs(native), actual)
    if same_history: assert history(stock) == history(native), (flags, history(stock), history(native), actual)
    if mode == 'rust' or native_expected: assert '(Rust frontend)' in actual[1], actual
    return history(native)


def wait(predicate, proc, log, timeout=180):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert proc.poll() is None, f'{log.read_text()}\nwatch process exited with status {proc.returncode}'
        assert time.monotonic() < deadline, log.read_text()
        time.sleep(.1)


def watch(root, mode, flags, command=None):
    log = root.parent / (root.name + '-watch.log')
    args = command or ([DART, 'run', 'build_runner', 'watch', '--force-jit', *flags]
                       if mode == 'stock' else launcher(root, mode, 'watch', ['--force-jit', *flags]))
    stream = log.open('w')
    try:
        proc = subprocess.Popen(args, cwd=root, env=fixture_env(root), stdout=stream, stderr=stream, start_new_session=True)
    except BaseException:
        stream.close()
        raise
    handle = proc, log, stream
    try:
        wait(lambda: ('Built with build_runner' in log.read_text() if mode == 'stock' else 'Watching ' in log.read_text()), proc, log)
    except BaseException as failure:
        try:
            stop(handle)
        except BaseException as cleanup_error:
            raise failure from cleanup_error
        raise
    return handle


def stop(handle, timeout=15):
    proc, _, stream = handle
    try:
        try:
            os.killpg(proc.pid, signal.SIGINT)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            pass
    finally:
        try:
            # The group can outlive its leader. Always kill anything that did
            # not exit after SIGINT, even when proc.wait() returned promptly.
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        finally:
            stream.close()


def stop_all(handles):
    active_error = sys.exc_info()[1]
    errors = []
    for handle in handles:
        try:
            stop(handle)
        except BaseException as error:
            errors.append(error)
    if errors:
        if active_error is not None:
            raise active_error from errors[0]
        raise errors[0]


def process_handle(log, code):
    stream = log.open('w')
    try:
        proc = subprocess.Popen([sys.executable, '-c', code], stdout=stream, stderr=stream,
                                start_new_session=True)
    except BaseException:
        stream.close()
        raise
    return proc, log, stream


def watch_process_cleanup_comparison(tmp):
    # A process that fails before readiness must report its original startup
    # failure even when cleanup reports an error of its own.
    original_stop = stop
    failed_handle = []

    def failing_stop(handle):
        failed_handle.append(handle)
        original_stop(handle)
        raise RuntimeError('injected cleanup failure')

    try:
        globals()['stop'] = failing_stop
        try:
            (tmp / 'startup').mkdir()
            watch(tmp / 'startup', 'stock', (),
                  command=[sys.executable, '-c', 'raise SystemExit(17)'])
        except AssertionError as failure:
            assert 'status 17' in str(failure), failure
            assert isinstance(failure.__cause__, RuntimeError), failure
        else:
            raise AssertionError('a watch process that exits before readiness was accepted')
        assert len(failed_handle) == 1 and failed_handle[0][2].closed
    finally:
        globals()['stop'] = original_stop

    # A process that ignores SIGINT exercises the bounded wait and SIGKILL
    # escalation path.
    timeout_handle = process_handle(
        tmp / 'timeout.log',
        'import signal, time; signal.signal(signal.SIGINT, signal.SIG_IGN); print("ready", flush=True); time.sleep(60)')
    try:
        wait(lambda: 'ready' in timeout_handle[1].read_text(), timeout_handle[0], timeout_handle[1], timeout=3)
        stop(timeout_handle, timeout=.1)
        assert timeout_handle[0].returncode == -signal.SIGKILL, timeout_handle[0].returncode
        assert timeout_handle[2].closed
    finally:
        stop(timeout_handle, timeout=.1)

    # The parent exits after starting a child that ignores SIGINT. The child's
    # process group must still be killed after the parent has been reaped.
    child_pid_file = tmp / 'child.pid'
    child_code = (
        'import os, pathlib, signal, time; '
        'signal.signal(signal.SIGINT, signal.SIG_IGN); '
        f'pathlib.Path({str(child_pid_file)!r}).write_text(str(os.getpid())); '
        'time.sleep(60)')
    parent_code = (
        'import pathlib, subprocess, sys, time\n'
        f'subprocess.Popen([sys.executable, "-c", {child_code!r}])\n'
        f'ready = pathlib.Path({str(child_pid_file)!r})\n'
        'deadline = time.monotonic() + 5\n'
        'while not ready.exists() and time.monotonic() < deadline:\n'
        '    time.sleep(.01)\n')
    parent_handle = process_handle(tmp / 'parent.log', parent_code)
    try:
        deadline = time.monotonic() + 5
        while not child_pid_file.exists():
            assert time.monotonic() < deadline, parent_handle[1].read_text()
            time.sleep(.01)
        assert parent_handle[0].wait(timeout=5) == 0
        child_pid = int(child_pid_file.read_text())
        assert live(child_pid), child_pid
        stop(parent_handle, timeout=.1)
        deadline = time.monotonic() + 3
        while live(child_pid):
            assert time.monotonic() < deadline, f'child survived process-group cleanup: {child_pid}'
            time.sleep(.02)
        assert parent_handle[2].closed
    finally:
        stop(parent_handle, timeout=.1)

    # Cleanup errors from the first watcher must not prevent the second
    # process group from being stopped.
    pair = []
    attempts = []

    def fail_after_first(handle):
        attempts.append(handle)
        original_stop(handle, timeout=.1)
        if len(attempts) == 1:
            raise RuntimeError('injected first-watcher cleanup failure')

    try:
        pair.append(process_handle(
            tmp / 'pair-one.log', 'import time; print("ready", flush=True); time.sleep(60)'))
        pair.append(process_handle(
            tmp / 'pair-two.log', 'import time; print("ready", flush=True); time.sleep(60)'))
        for handle in pair:
            wait(lambda handle=handle: 'ready' in handle[1].read_text(), handle[0], handle[1], timeout=3)
        globals()['stop'] = fail_after_first
        try:
            stop_all(pair)
        except RuntimeError as failure:
            assert str(failure) == 'injected first-watcher cleanup failure', failure
        else:
            raise AssertionError('paired cleanup did not report its first failure')
        assert attempts == pair
        assert all(handle[0].poll() is not None and handle[2].closed for handle in pair)
    finally:
        globals()['stop'] = original_stop
        stop_all(pair)


def legacy_graph(root):
    """Remove format-2 location evidence while preserving real action history."""
    path = root / '.dart_tool/build_runner_accelerator/graph-v3.bin'
    data = bytearray(path.read_bytes())
    assert data[:5] == b'BRAG\x02', data[:5]
    offset = 9
    def integer():
        nonlocal offset
        value = int.from_bytes(data[offset:offset + 4], 'big'); offset += 4
        return value
    def string():
        nonlocal offset
        length = integer(); offset += length
    def strings():
        for _ in range(integer()): string()
    integer(); string()  # schema/config
    for _ in range(integer()):
        string(); offset += 1; string(); offset += 8
    for _ in range(integer()):
        string(); string(); string()  # key/builder/input
        strings(); strings(); strings()
        for _ in range(integer()): string(); string()
        strings()
        for _ in range(integer()): string(); string()
        string()
    for _ in range(integer()): string(); strings()
    data = data[:offset]
    data[4] = 1
    data[5:9] = (len(data) - 9).to_bytes(4, 'big')
    path.write_bytes(data)


def legacy_comparison(tmp):
    stock, native = tmp / 'legacy-stock', tmp / 'legacy-native'
    prepare(stock); prepare(native)
    flags = ['--build-filter=lib/a.final']
    check(stock, native, flags)
    # Populate stock's separate cache before exercising an unsupported
    # legacy transition; fallback remains a complete stock invocation.
    code, log = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], native)
    assert code == 0, log
    legacy_graph(native)
    before = outputs(native), history(native)
    code, log = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
    assert code != 0 and 'legacy state' in log, log
    assert (outputs(native), history(native)) == before
    assert check(stock, native, flags, mode='auto') == Counter()
    for root in (stock, native):
        file = root / 'build.yaml'; file.write_text(file.read_text() + '\n# new configuration\n')
    before = outputs(native), history(native)
    code, log = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
    assert code != 0 and 'legacy state' in log, log
    assert (outputs(native), history(native)) == before
    check(stock, native, flags, mode='auto')


def removed_declaration_comparison(tmp):
    stock, native = tmp / 'removed-stock', tmp / 'removed-native'
    prepare(stock); prepare(native)
    flags = ['--build-filter=lib/a.final']
    check(stock, native, flags)
    code, log = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], native)
    assert code == 0, log
    for root in (stock, native):
        file = root / 'build.yaml'
        file.write_text(file.read_text() + '\n# compatible stock plan, changed native fingerprint\n')
    before = outputs(native), history(native)
    code, log = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
    assert code != 0 and 'without a source/cache layout transition' in log, log
    assert (outputs(native), history(native)) == before
    check(stock, native, flags, mode='auto')
    for kind in ('declaration', 'application'):
        for root in (stock, native):
            file = root / 'build.yaml'
            text = file.read_text().split('targets:')[0]
            setting = "generate_for: ['lib/b.txt', 'lib/common.txt']" if kind == 'declaration' else 'enabled: false'
            file.write_text(text + 'targets:\n  $default:\n    builders:\n      build_filter_app:seed:\n        ' + setting + '\n')
        before = outputs(native), history(native)
        code, log = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
        reason = 'previous output declarations' if kind == 'declaration' else 'previous builder application'
        assert code != 0 and reason in log, (kind, log)
        assert (outputs(native), history(native)) == before
        check(stock, native, flags, mode='auto')


def resolver_generated_comparison(tmp):
    stock, native = tmp / 'resolver-generated-stock', tmp / 'resolver-generated-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        (root / 'build.yaml').write_text(RESOLVER_BUILD_YAML)
        for name in ('one', 'two', 'shared'): (root / f'lib/{name}.src').write_text('source\n')
        (root / 'lib/transitive.dart').write_text('class Shared {}\n')
    flags = ['--build-filter=lib/one.final,lib/two.final']
    assert check(stock, native, flags) == Counter({'lib/one.src': 1, 'lib/two.src': 1,
        'lib/shared.src': 1, 'lib/one.dart': 1, 'lib/two.dart': 1})
    assert check(stock, native, flags) == Counter()
    for root in (stock, native): (root / 'lib/transitive.dart').write_text('class Shared { int get value => 1; }\n')
    assert check(stock, native, flags) == Counter({'lib/one.dart': 1, 'lib/two.dart': 1})
    for root in (stock, native): (root / 'lib/shared.src').write_text('edited producer, unchanged output\n')
    assert check(stock, native, flags) == Counter({'lib/shared.src': 1})


def watch_comparison(tmp, cache=False):
    # Watch continuing edits/deletes and restart use different conflict rules.
    prefix = 'watch-cache' if cache else 'watch'
    stock, native = tmp / (prefix + '-stock'), tmp / (prefix + '-native')
    prepare(stock); prepare(native)
    for root in (stock, native): (root / 'lib/c.txt').write_text('outside watch target\n')
    if cache:
        for root in (stock, native):
            file = root / 'build.yaml'
            file.write_text(file.read_text().replace('build_to: source', 'build_to: cache', 1))
    check(stock, native)
    for pattern in ('lib/a.final', 'lib/b.final'):
        handles = []
        try:
            handles.append(watch(stock, 'stock', ['--build-filter=' + pattern]))
            handles.append(watch(native, 'rust', ['--build-filter=' + pattern]))
            assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
            for root in (stock, native): history_path(root).unlink(missing_ok=True)
            # An excluded source edit must trigger a watch cycle without
            # dispatching the unrelated builder or changing generated files.
            before = outputs(stock)
            positions = [handle[1].stat().st_size for handle in handles]
            for root in (stock, native): (root / 'lib/other.noise').write_text(pattern + '\n')
            for index, handle in enumerate(handles):
                marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                wait(lambda handle=handle, index=index, marker=marker: marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
            assert outputs(stock) == outputs(native) == before
            assert history(stock) == history(native) == Counter()
            if pattern == 'lib/a.final':
                before = outputs(stock)
                for mutation in ('edit', 'delete'):
                    positions = [handle[1].stat().st_size for handle in handles]
                    for root in (stock, native):
                        file = root / 'lib/c.txt'
                        if mutation == 'edit': file.write_text('edited outside watch target\n')
                        else: file.unlink()
                    for index, handle in enumerate(handles):
                        marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                        wait(lambda handle=handle, index=index, marker=marker: marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
                    assert outputs(stock) == outputs(native), (mutation, outputs(stock), outputs(native))
                    if mutation == 'edit': assert outputs(stock) == before
                    assert history(stock) == history(native) == Counter()
            # A previously retained, unrecorded generated file becomes a
            # conflict when an external edit arrives during the same watch.
            mutations = ('same-bytes', 'different-bytes') if pattern == 'lib/a.final' else ('different-bytes',)
            for mutation in mutations:
                positions = [handle[1].stat().st_size for handle in handles]
                for root in (stock, native):
                    file = root / 'lib/other.ignored'
                    contents = file.read_bytes() if mutation == 'same-bytes' else b'external conflict\n'
                    file.write_bytes(contents)
                for index, (root, handle) in enumerate(zip((stock, native), handles)):
                    marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                    wait(lambda root=root, handle=handle, index=index, marker=marker:
                        not (root / 'lib/other.ignored').exists() and marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
                assert outputs(stock) == outputs(native)
                assert history(stock) == history(native) == Counter()
            before = outputs(stock)
            positions = [handle[1].stat().st_size for handle in handles]
            value = 'watch shared edit: ' + pattern + '\n'
            for root in (stock, native): (root / 'lib/common.txt').write_text(value)
            for index, handle in enumerate(handles):
                marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                wait(lambda handle=handle, index=index, marker=marker: marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
            for root, handle in zip((stock, native), handles):
                wait(lambda root=root: value.encode() in (root / pattern).read_bytes(), handle[0], handle[1])
            assert outputs(stock) == outputs(native) != before, (pattern, before, outputs(stock), outputs(native))
            name = pattern.split('/')[-1].split('.')[0]
            assert history(stock) == history(native) == Counter({'lib/common.txt': 1, f'lib/{name}.mid': 1}), (pattern, history(stock), history(native))
            for root in (stock, native): history_path(root).unlink(missing_ok=True)
            positions = [handle[1].stat().st_size for handle in handles]
            for root in (stock, native): (root / 'lib/common.txt').unlink()
            for index, handle in enumerate(handles):
                marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                wait(lambda handle=handle, index=index, marker=marker: marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
            for root, handle in zip((stock, native), handles):
                wait(lambda root=root: value.encode() not in (root / pattern).read_bytes()
                    and not any(path.endswith('/lib/common.' + suffix) or path == 'lib/common.' + suffix
                        for path in outputs(root) for suffix in ('side', 'mid')), handle[0], handle[1])
            assert outputs(stock) == outputs(native), (pattern, outputs(stock), outputs(native))
            assert history(stock) == history(native) == Counter({f'lib/{name}.mid': 1}), (pattern, history(stock), history(native))
            for root in (stock, native): (root / f'lib/{name}.txt').unlink()
            for root, handle in zip((stock, native), handles):
                wait(lambda root=root: not (root / pattern).exists(), handle[0], handle[1])
            assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        finally:
            stop_all(handles)


def resolver_cycle_comparison(tmp):
    stock, native = tmp / 'cycle-stock', tmp / 'cycle-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        (root / 'build.yaml').write_text(RESOLVER_BUILD_YAML)
        for name in ('one', 'shared'): (root / f'lib/{name}.src').write_text('source\n')
        (root / 'lib/transitive.dart').write_text("export 'shared.dart';\nclass Shared {}\n")
    flags = ['--build-filter=lib/one.final']
    check(stock, native, flags)
    before = outputs(native), history(native)
    code, log = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
    assert code != 0 and 'incremental resolver cycles' in log, log
    assert (outputs(native), history(native)) == before
    code, log = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], native)
    assert code == 0, log
    assert check(stock, native, flags, mode='auto') == Counter()


def recursive_combination_comparison(tmp):
    stock, native = tmp / 'recursive-stock', tmp / 'recursive-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        (root / 'lib/nested').mkdir()
        (root / 'lib/nested/c.txt').write_text('nested source\n')
    flags = ['--build-filter=lib/a.final,lib/no-match.final',
             '--build-filter=lib/nested/*.final', '--build-filter=package:build_filter_app/b.final']
    assert check(stock, native, flags) == Counter({
        'lib/a.txt': 1, 'lib/b.txt': 1, 'lib/nested/c.txt': 1, 'lib/common.txt': 1,
        'lib/a.mid': 1, 'lib/b.mid': 1, 'lib/nested/c.mid': 1})
    check(stock, native, ['--build-filter=lib/**/*.final'])
    assert 'lib/nested/c.final' in outputs(native)
    assert check(stock, native, ['--build-filter=package:build_filter_*/**/*.final']) == Counter()


def glob_membership_comparison(tmp):
    stock, native = tmp / 'members-stock', tmp / 'members-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        file = root / 'build.yaml'
        file.write_text(file.read_text().replace('builder_factories: [seed]', 'builder_factories: [seedGlob]'))
        for name in ('plain', '\ue000', '\U0001f600'):
            (root / f'lib/{name}.side').write_text('plain source side\n')
    flags = ['--build-filter=lib/a.final', '--define=:finish=glob_names=true']
    check(stock, native, ['--define=:finish=glob_names=true'])
    assert check(stock, native, flags) == Counter()
    check(stock, native, flags)
    assert check(stock, native, flags) == Counter()
    for root in (stock, native): (root / 'lib/plain.side').write_text('edited unread glob content\n')
    assert check(stock, native, flags) == Counter()
    for root in (stock, native): (root / 'lib/b.txt').write_text('edited generated glob content\n')
    assert check(stock, native, flags) == Counter({'lib/b.txt': 1})
    for root in (stock, native): (root / 'lib/new.side').write_text('new glob member\n')
    check(stock, native, flags)


def dart_mode_comparison(tmp):
    stock, dart = tmp / 'dart-mode-stock', tmp / 'dart-mode-launcher'
    prepare(stock); prepare(dart)
    flags = ['--build-filter', 'lib/a.final,lib/b.final',
             '--build-filter=package:build_filter_app/common.side']
    check(stock, dart, flags, mode='dart')
    assert check(stock, dart, flags, mode='dart') == Counter()
    assert not (dart / '.dart_tool/build_runner_accelerator').exists()


def undeclared_artifact_comparison(tmp):
    stock, native = tmp / 'artifact-stock', tmp / 'artifact-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        file = root / 'build.yaml'
        file.write_text(file.read_text().replace('build_to: source', 'build_to: cache', 1))
    flags = ['--build-filter=lib/a.final', '--define=:finish=orphan=true']
    check(stock, native, flags)
    for root, prefix in ((stock, '.dart_tool/build/generated'),
                         (native, '.dart_tool/build_runner_accelerator/cache')):
        (root / prefix / 'build_filter_app/lib/orphan.side').write_text('undeclared artifact\n')
        (root / 'lib/a.txt').write_text('edit demanding orphan canRead\n')
    check(stock, native, flags)
    assert b'no orphan\n' in (native / 'lib/a.final').read_bytes()
    assert not any(path.endswith('/orphan.side') for path in outputs(native))


def watch_source_classification_comparison(tmp):
    watch_process_cleanup_comparison(tmp)
    stock, native = tmp / 'classification-stock', tmp / 'classification-native'
    prepare(stock); prepare(native)
    for root in (stock, native): (root / 'lib/c.txt').write_text('retained c source\n')
    define = '--define=:finish=conditional_glob=true'
    check(stock, native, [define])
    flags = ['--build-filter=lib/a.final', define]
    for restart in (False, True):
        handles = []
        try:
            handles.append(watch(stock, 'stock', flags))
            handles.append(watch(native, 'rust', flags))
            assert outputs(stock) == outputs(native)
            if restart:
                assert b'externally edited c' in (native / 'lib/a.final').read_bytes()
                continue
            for root in (stock, native): history_path(root).unlink(missing_ok=True)
            for mutation in ('delete', 'restore', 'delete-again', 'idle', 'glob'):
                positions = [handle[1].stat().st_size for handle in handles]
                for root in (stock, native):
                    if mutation in ('delete', 'delete-again'): (root / 'lib/c.txt').unlink()
                    elif mutation == 'restore': (root / 'lib/c.txt').write_text('restored undemanded c\n')
                    elif mutation == 'idle': (root / 'lib/other.noise').write_text('excluded event\n')
                    else: (root / 'lib/a.txt').write_text('use-glob\n')
                for index, handle in enumerate(handles):
                    marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                    wait(lambda handle=handle, index=index, marker=marker:
                         marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
                if mutation == 'glob':
                    for root, handle in zip((stock, native), handles):
                        wait(lambda root=root: (root / 'lib/a.final').read_bytes().startswith(b'use-glob\n'), handle[0], handle[1])
                assert outputs(stock) == outputs(native), (mutation, outputs(stock), outputs(native))
                assert history(stock) == history(native), (mutation, history(stock), history(native))
            assert (native / 'lib/c.side').exists()
            assert b'retained c source' not in (native / 'lib/a.final').read_bytes()
            # Stock ignores modifications of an unknown, no-longer-declared
            # asset. A later relevant rebuild must still exclude its bytes.
            positions = [handle[1].stat().st_size for handle in handles]
            for root in (stock, native):
                (root / 'lib/c.side').write_text('externally edited c\n')
                (root / 'lib/a.txt').write_text('use-glob-again\n')
            for index, handle in enumerate(handles):
                marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
                wait(lambda handle=handle, index=index, marker=marker:
                     marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
            for root, handle in zip((stock, native), handles):
                wait(lambda root=root: (root / 'lib/a.final').read_bytes().startswith(b'use-glob-again\n'), handle[0], handle[1])
            assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
            assert history(stock) == history(native), (history(stock), history(native))
            assert b'externally edited c' not in (native / 'lib/a.final').read_bytes()
        finally:
            stop_all(handles)


def source_selection_comparison(tmp):
    stock, native = tmp / 'stock', tmp / 'native'
    prepare(stock); prepare(native)
    # Clean selection requires both a primary chain and a shared secondary producer.
    h = check(stock, native, ['--build-filter=lib/a.final'])
    assert h == Counter({'lib/a.txt': 1, 'lib/a.mid': 1, 'lib/common.txt': 1}), h
    assert check(stock, native, ['--build-filter=lib/a.final']) == Counter()
    for root in (stock, native): (root / 'lib/a.txt').write_text('a\n# same output\n')
    assert check(stock, native, ['--build-filter=lib/a.final']) == Counter({'lib/a.txt': 1})
    assert check(stock, native, ['--build-filter=lib/a.final'], mode='auto', native_expected=True) == Counter()
    for root in (stock, native): (root / 'lib/a.txt').write_text('no-shared\n')
    assert check(stock, native, ['--build-filter=lib/a.final']) == Counter({'lib/a.txt': 1, 'lib/a.mid': 1})
    assert check(stock, native, ['--build-filter=lib/a.final']) == Counter()
    for root in (stock, native): (root / 'lib/a.txt').write_text('a\n')
    assert check(stock, native, ['--build-filter=lib/a.final']) == Counter({'lib/a.txt': 1, 'lib/a.mid': 1, 'lib/common.txt': 1})
    for flags in (
        ['--build-filter', 'lib/a.final,lib/b.final'],
        ['--build-filter=lib/a.final', '--build-filter=lib/b.final'],
        ['--build-filter=lib/*.final'],
        ['--build-filter=package:build_filter_*/a.final'],
        ['--build-filter=asset:*/lib/b.final'],
        ['--build-filter=lib/no-match.final'],
        [], ['--build-filter=lib/a.final'], ['--build-filter=lib/b.final'], [],
    ): check(stock, native, flags)
    # A reused empty producer must not expose a conflicting intermediate
    # that it never generated; stock skips the dependent builder entirely.
    for root in (stock, native):
        for suffix in ('mid', 'side', 'final'):
            (root / f'lib/empty.{suffix}').write_text('stray generated file\n')
    assert check(stock, native, ['--build-filter=lib/empty.final']) == Counter()
    assert not any(path.startswith('lib/empty.') for path in outputs(native))
    # Conflicting outputs that were not in the previous graph are deleted on restart.
    for root in (stock, native):
        (root / 'lib/empty.final').write_text('conflict\n')
    check(stock, native, ['--build-filter=lib/a.final'])
    assert not (native / 'lib/empty.final').exists()
    for name, value in [('a', 'edited\n'), ('b', 'outside\n'), ('common', 'shared change\n'), ('a', 'empty\n')]:
        for root in (stock, native): (root / f'lib/{name}.txt').write_text(value)
        check(stock, native, ['--build-filter=lib/a.final'])
    for root in (stock, native): (root / 'lib/b.txt').unlink()
    check(stock, native, ['--build-filter=lib/a.final'])
    check(stock, native)
    # Deleting a shared secondary producer invalidates surviving consumers;
    # its old on-disk output is logically missing before the commit.
    # Restore a selected primary so both lanes demand the secondary edge.
    for root in (stock, native): (root / 'lib/b.txt').write_text('restored b\n')
    check(stock, native, ['--build-filter=lib/b.final'])
    for root in (stock, native): (root / 'lib/common.txt').unlink()
    assert check(stock, native, ['--build-filter=lib/b.final']) == Counter({'lib/b.mid': 1})
    for root in (stock, native): (root / 'lib/common.txt').write_text('restored shared\n')
    check(stock, native, ['--build-filter=lib/b.final'])
    # Native source/cache chains use the same logical demand edges.
    for root in (stock, native):
        config = root / 'build.yaml'
        config.write_text(config.read_text().replace('build_to: source', 'build_to: cache', 1))
    check(stock, native, ['--build-filter=lib/b.final'])


def cache_selection_comparison(tmp):
    cs, cn = tmp / 'cache-stock', tmp / 'cache-native'
    prepare(cs); prepare(cn)
    for root in (cs, cn):
        file = root / 'build.yaml'
        file.write_text(file.read_text().replace('build_to: source', 'build_to: cache', 1))
    check(cs, cn, ['--build-filter=lib/a.final'])
    assert any(path.startswith('cache/') for path in outputs(cn)), outputs(cn)
    assert check(cs, cn, ['--build-filter=lib/a.final']) == Counter()
    for root in (cs, cn): (root / 'lib/common.txt').write_text('cache edit\n')
    check(cs, cn, ['--build-filter=lib/a.final'])
    # A clean plan replaces the whole artifact tree, including files
    # outside the current declarations. Incremental restarts also classify
    # unrecorded declared artifacts as conflicts.
    check(cs, cn)
    for root, prefix in ((cs, '.dart_tool/build/generated'), (cn, '.dart_tool/build_runner_accelerator/cache')):
        (root / prefix / 'build_filter_app/lib/orphan.mid').write_text('orphan artifact\n')
    (cs / '.dart_tool/build/asset_graph.json').unlink()
    (cn / '.dart_tool/build_runner_accelerator/graph-v3.bin').unlink()
    check(cs, cn, ['--build-filter=lib/a.final'])
    assert not any(path.startswith('cache/') and ('/b.' in path or '/orphan.' in path) for path in outputs(cn))
    check(cs, cn, ['--build-filter=lib/a.final'])
    # Cache/source layout changes delete the old physical output tree,
    # including siblings omitted from the preceding filtered state.
    check(cs, cn)
    check(cs, cn, ['--build-filter=lib/a.final'])
    for root in (cs, cn):
        file = root / 'build.yaml'
        file.write_text(file.read_text().replace('build_to: cache', 'build_to: source', 1))
    check(cs, cn, ['--build-filter=lib/a.final'])
    assert not any(path.startswith('cache/') for path in outputs(cn)), outputs(cn)
    # Primary source edits alone do not force a step that never read it.
    us, un = tmp / 'unread-stock', tmp / 'unread-native'
    prepare(us); prepare(un)
    for root in (us, un):
        file = root / 'build.yaml'
        file.write_text(file.read_text().replace('builder_factories: [seed]', 'builder_factories: [constant]'))
    check(us, un, ['--build-filter=lib/a.final'])
    for root in (us, un):
        for name in ('a', 'common'): (root / f'lib/{name}.txt').write_text('changed unread primary\n')
    assert check(us, un, ['--build-filter=lib/a.final']) == Counter()
    parallel_history_comparison(tmp)


def parallel_history_comparison(tmp):
    stock, native = tmp / 'parallel-history-stock', tmp / 'parallel-history-native'
    prepare(stock); prepare(native)
    parallel_inputs = [f'parallel_{index:02}' for index in range(40)]
    for root in (stock, native):
        for name in parallel_inputs:
            (root / f'lib/{name}.txt').write_text(f'{name} input\n')

    # Each selected finish action requests the same generated secondary input.
    # The common seed and each selected producer must be recorded once.
    filtered_flags = ['--force-jit', '--build-filter=lib/parallel_*.final']

    def rust_four_jobs(flags):
        args = launcher(native, 'rust', flags=flags)
        args[args.index('--jobs=1')] = '--jobs=4'
        return args

    for root in (stock, native): history_path(root).unlink(missing_ok=True)
    reference = execute([DART, 'run', 'build_runner', 'build', *filtered_flags], stock)
    actual = execute(rust_four_jobs(filtered_flags), native)
    assert actual[0] == reference[0] == 0, (reference, actual)
    assert '(Rust frontend)' in actual[1], actual
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), actual)
    filtered_history = (
        Counter({f'lib/{name}.txt': 1 for name in parallel_inputs})
        + Counter({f'lib/{name}.mid': 1 for name in parallel_inputs})
        + Counter({'lib/common.txt': 1})
    )
    assert history(stock) == history(native) == filtered_history, (
        'filtered jobs=4 action history', history(stock), history(native), filtered_history)

    # Start from empty action/output state and fan out enough actions to exercise
    # concurrent writes from multiple workers to the shared history file.
    generated_suffixes = {'.mid', '.side', '.final', '.ignored', '.post'}
    for root in (stock, native):
        history_path(root).unlink(missing_ok=True)
        (root / '.dart_tool/build/asset_graph.json').unlink(missing_ok=True)
        (root / '.dart_tool/build_runner_accelerator/graph-v3.bin').unlink(missing_ok=True)
        for path in (root / 'lib').rglob('*'):
            if path.is_file() and path.suffix in generated_suffixes:
                path.unlink()

    all_text_inputs = ['a', 'b', 'common', 'empty', *parallel_inputs]
    full_history = (
        Counter({f'lib/{name}.txt': 1 for name in all_text_inputs})
        + Counter({f'lib/{name}.mid': 1 for name in all_text_inputs if name != 'empty'})
        + Counter({'lib/other.noise': 1})
    )
    full_flags = ['--force-jit']
    reference = execute([DART, 'run', 'build_runner', 'build', *full_flags], stock)
    actual = execute(rust_four_jobs(full_flags), native)
    assert actual[0] == reference[0] == 0, (reference, actual)
    assert '(Rust frontend)' in actual[1], actual
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), actual)
    assert history(stock) == history(native) == full_history, (
        'unfiltered jobs=4 action history', history(stock), history(native), full_history)


def package_selection_comparison(tmp):
    # Explicit dependency targets exercise real package selection, not just
    # a package-qualified spelling for the root package.
    ps, pn = tmp / 'package-stock', tmp / 'package-native'
    prepare(ps); prepare(pn)
    for root in (ps, pn):
        dep = root / 'dep'; (dep / 'lib').mkdir(parents=True)
        (dep / 'pubspec.yaml').write_text('name: filter_dep\nenvironment:\n  sdk: ">=3.11.0 <4.0.0"\n')
        (dep / 'build.yaml').write_text('targets:\n  $default:\n    builders:\n      build_filter_app:seed:\n        enabled: true\n      build_filter_app:finish:\n        enabled: true\n')
        for name in ('a', 'common'): (dep / f'lib/{name}.txt').write_text('dependency ' + name + '\n')
        pub = root / 'pubspec.yaml'; pub.write_text(pub.read_text().replace('dependencies:\n', 'dependencies:\n  filter_dep:\n    path: dep\n', 1))
        cfg = root / 'build.yaml'; cfg.write_text(cfg.read_text().replace('build_to: source', 'build_to: cache'))
        code, log = execute([DART, 'pub', 'get', '--offline'], root); assert code == 0, log
    ph = check(ps, pn, ['--build-filter=package:filter_*/a.final'])
    assert ph == Counter({'filter_dep|lib/a.txt': 1, 'filter_dep|lib/common.txt': 1, 'filter_dep|lib/a.mid': 1}), ph
    assert 'cache/filter_dep/lib/a.final' in outputs(pn), outputs(pn)
    check(ps, pn, ['--build-filter=asset:filter_dep/lib/a.final'])
    for root in (ps, pn): (root / 'dep/lib/a.mid').write_text('dependency source conflict\n')
    before = outputs(pn)
    conflict_flags = ['--build-filter=package:filter_dep/a.final']
    reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *conflict_flags], ps)
    actual = execute(launcher(pn, 'auto', flags=['--force-jit', *conflict_flags]), pn)
    assert reference[0] == actual[0] != 0, (reference, actual)
    assert 'using Dart fallback' in actual[1], actual
    assert outputs(ps) == outputs(pn) == before
    rejected = execute(launcher(pn, 'rust', flags=conflict_flags), pn)
    assert rejected[0] != 0 and 'output conflicts in dependencies' in rejected[1], rejected
    for root in (ps, pn): (root / 'dep/lib/a.mid').unlink()
    # Globs demand all visible producing steps, including excluded roots,
    # and a no-op reuses consumers after reevaluating generated candidates.


def glob_comparison(tmp):
    gs, gn = tmp / 'glob-stock', tmp / 'glob-native'
    prepare(gs); prepare(gn)
    gf = ['--build-filter=lib/a.final', '--define=:finish=glob=true']
    check(gs, gn, gf)
    assert check(gs, gn, gf) == Counter()
    for root in (gs, gn): (root / 'lib/new.txt').write_text('new\n')
    check(gs, gn, gf)
    for root in (gs, gn): (root / 'lib/b.txt').unlink()
    check(gs, gn, gf)
    # Resolver imports must invalidate consumers even when the resident
    # analyzer observed no new IO for a previously loaded shared library.
    glob_membership_comparison(tmp)


def resolver_comparison(tmp):
    rs, rn = tmp / 'resolver-stock', tmp / 'resolver-native'
    prepare(rs); prepare(rn)
    for root in (rs, rn):
        (root / 'build.yaml').write_text(RESOLVER_BUILD_YAML)
        for name in ('one', 'two'): (root / f'lib/{name}.src').write_text('source\n')
        (root / 'lib/shared.dart').write_text("export 'transitive.dart';\n")
        (root / 'lib/transitive.dart').write_text('class Shared {}\n')
    rf = ['--build-filter=lib/one.final,lib/two.final']
    assert check(rs, rn, rf) == Counter({'lib/one.src': 1, 'lib/one.dart': 1, 'lib/two.src': 1, 'lib/two.dart': 1})
    assert check(rs, rn, rf) == Counter()
    for root in (rs, rn): (root / 'lib/transitive.dart').write_text('class Shared { int get value => 1; }\n')
    assert check(rs, rn, rf) == Counter({'lib/one.dart': 1, 'lib/two.dart': 1})
    assert check(rs, rn, rf) == Counter()
    resolver_generated_comparison(tmp)
    resolver_cycle_comparison(tmp)
    recursive_combination_comparison(tmp)


def state_comparison(tmp):
    legacy_comparison(tmp)
    removed_declaration_comparison(tmp)
    ats, atn = tmp / 'aot-stock', tmp / 'aot-native'
    prepare(ats); prepare(atn)
    check(ats, atn, ['--build-filter=lib/a.final'], compile_flag='--force-aot')
    assert check(ats, atn, ['--build-filter=lib/a.final'], compile_flag='--force-aot') == Counter()
    assert check(ats, atn, ['--build-filter=lib/a.final'], compile_flag='--force-jit') == Counter()
    assert check(ats, atn, ['--build-filter=lib/a.final', '-d'], compile_flag='--force-jit') == Counter()
    # Traced fixtures verify optional/post-process demand and output lifecycle
    # even when the entire invocation deliberately uses stock fallback.


def caught_demand_failure_comparison(tmp):
    def selected_outputs(root):
        current = outputs(root)
        selected = ('lib/a.final', 'lib/a.mid', 'lib/a.side', 'lib/common.mid', 'lib/common.side')
        return {path: current[path] for path in selected if path in current}

    def recover(stock, native, flags, expected_stock_history, expected_native_history):
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
        reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
        actual = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
        assert actual[0] == reference[0] == 0, (flags, reference, actual)
        assert selected_outputs(stock) == selected_outputs(native), (
            flags, selected_outputs(stock), selected_outputs(native), actual)
        assert history(stock) == expected_stock_history, (
            flags, 'stock recovery history', history(stock), actual)
        assert history(native) == expected_native_history, (
            flags, 'native recovery history', history(native), actual)
        return history(native)

    def restore_full_state(stock, native, flags):
        # Stock may remove unselected outputs before reporting its failed
        # build. A successful unfiltered build restores that physical baseline
        # so the complete output set, bytes, and histories can be compared.
        check(stock, native, [flags[-1]])
        assert check(stock, native, flags) == Counter()

    for rpc, option in (('can-read', 'catch_can_read_error'), ('read', 'catch_read_error')):
        stock, native = tmp / f'caught-{rpc}-stock', tmp / f'caught-{rpc}-native'
        prepare(stock)
        prepare(native)
        catch_flag = f'--define=:finish={option}=true'
        check(stock, native, [catch_flag])
        flags = ['--build-filter=lib/a.final', catch_flag]
        previous_outputs = outputs(native)
        graph = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        previous_graph = graph.read_bytes()

        for root in (stock, native):
            (root / 'lib/common.txt').write_text('fail\n')
            history_path(root).unlink(missing_ok=True)
        reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
        actual = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
        assert reference[0] == actual[0] != 0, (rpc, reference, actual)
        assert 'intentional build-filter fixture failure' in actual[1], (rpc, actual)
        # Stock may write the consumer's caught-error output before reporting
        # its failed build. Native keeps its all-success transaction boundary.
        assert outputs(native) == previous_outputs, (rpc, outputs(native), previous_outputs)
        assert graph.read_bytes() == previous_graph, rpc

        for root in (stock, native):
            (root / 'lib/common.txt').write_text('recovered common\n')
        rebuilt = recover(stock, native, flags,
                          Counter({'lib/common.txt': 1, 'lib/a.mid': 1}),
                          Counter({'lib/common.txt': 1, 'lib/a.mid': 1}))
        assert rebuilt == Counter({'lib/common.txt': 1, 'lib/a.mid': 1}), (rpc, rebuilt)
        assert b'recovered common' in (native / 'lib/a.final').read_bytes(), rpc
        restore_full_state(stock, native, flags)

        fresh_stock, fresh_native = tmp / f'fresh-caught-{rpc}-stock', tmp / f'fresh-caught-{rpc}-native'
        prepare(fresh_stock)
        prepare(fresh_native)
        fresh_flags = ['--build-filter=lib/a.final', catch_flag]
        for root in (fresh_stock, fresh_native):
            (root / 'lib/common.txt').write_text('fail\n')
        fresh_reference = execute(
            [DART, 'run', 'build_runner', 'build', '--force-jit', *fresh_flags], fresh_stock)
        fresh_actual = execute(
            launcher(fresh_native, 'rust', flags=['--force-jit', *fresh_flags]), fresh_native)
        fresh_graph = fresh_native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        assert fresh_reference[0] == fresh_actual[0] != 0, (rpc, fresh_reference, fresh_actual)
        assert 'intentional build-filter fixture failure' in fresh_actual[1], (rpc, fresh_actual)
        assert outputs(fresh_native) == {}, (rpc, outputs(fresh_native))
        assert not fresh_graph.exists(), (rpc, fresh_graph)

        for root in (fresh_stock, fresh_native):
            (root / 'lib/common.txt').write_text('recovered fresh common\n')
        first_success = recover(
            fresh_stock, fresh_native, fresh_flags,
            Counter({'lib/common.txt': 1, 'lib/a.mid': 1}),
            Counter({'lib/a.txt': 1, 'lib/common.txt': 1, 'lib/a.mid': 1}))
        assert first_success == Counter({
            'lib/a.txt': 1, 'lib/common.txt': 1, 'lib/a.mid': 1}), (rpc, first_success)
        assert b'recovered fresh common' in (fresh_native / 'lib/a.final').read_bytes(), rpc
        restore_full_state(fresh_stock, fresh_native, fresh_flags)


def traced_fallback_comparison(tmp, kinds):
    for kind in kinds:
        ts, tn = tmp / (kind + '-traced-stock'), tmp / (kind + '-traced-auto')
        prepare(ts); prepare(tn)
        for root in (ts, tn):
            file = root / 'build.yaml'
            config = file.read_text()
            if kind == 'optional':
                config = config.replace('build_to: source', 'build_to: cache\n    is_optional: true', 1)
            elif kind == 'trigger':
                config += """targets:
  $default:
    builders:
      build_filter_app:finish:
        options: {run_only_if_triggered: true}
"""
            elif kind == 'post':
                config += """post_process_builders:
  post:
    import: 'package:build_filter_app/builder.dart'
    builder_factory: post
    input_extensions: ['.final']
    build_to: source
targets:
  $default:
    builders:
      build_filter_app:post:
        enabled: true
"""
            else:
                config += """  zero:
    import: 'package:build_filter_app/builder.dart'
    builder_factories: [zero]
    build_extensions: {'.txt': []}
    auto_apply: root_package
    build_to: source
"""
            file.write_text(config)
        check(ts, tn, ['--build-filter=lib/a.final'], mode='auto')
        assert check(ts, tn, ['--build-filter=lib/a.final'], mode='auto') == Counter()
        check(ts, tn, ['--build-filter=lib/*.side'], mode='auto')
        check(ts, tn, ['--build-filter=lib/b.final'], mode='auto')
        if kind == 'optional': check(ts, tn, ['--build-filter=lib/a.final'], mode='auto', compile_flag='--force-aot')
        if kind == 'zero':
            assert check(ts, tn, ['--build-filter=lib/a.txt'], mode='auto') == Counter({'lib/a.txt': 1})
        before_outputs, before_history = outputs(tn), history(tn)
        code, log = execute(launcher(tn, 'rust', flags=['--build-filter=lib/a.final']), tn)
        assert outputs(tn) == before_outputs and history(tn) == before_history
        assert code != 0 and 'outside the supported subset' in log, (kind, log)


def existing_fallback_comparison(tmp):
    # Optional/post-process combinations are whole-invocation late fallback.
    for fixture in ('optional_builder_app', 'post_process_builder_app'):
        left, right = tmp / (fixture + '-stock'), tmp / (fixture + '-auto')
        shutil.copytree(REPO / 'fixtures' / fixture, left, ignore=shutil.ignore_patterns('.dart_tool'))
        shutil.copytree(left, right)
        for root in (left, right):
            pub = root / 'pubspec.yaml'; pub.write_text(pub.read_text().replace('path: ../..', f'path: {REPO}'))
            code, log = execute([DART, 'pub', 'get', '--offline'], root); assert code == 0, log
        flags = ['--build-filter=lib/**', '--force-jit']
        ref = execute([DART, 'run', 'build_runner', 'build', *flags], left)
        actual = execute(launcher(right, 'auto', flags=flags), right)
        assert ref[0] == actual[0] == 0, (fixture, ref, actual)
        def content(root):
            return {str(p.relative_to(root)): p.read_bytes() for p in (root / 'lib').rglob('*') if p.is_file()}
        assert content(left) == content(right), fixture
        assert 'using Dart fallback' in actual[1], actual
        rejected = execute(launcher(right, 'rust', flags=flags), right)
        assert rejected[0] != 0 and 'outside the supported subset' in rejected[1], rejected


def routing_comparison(tmp):
    caught_demand_failure_comparison(tmp)
    stock, native = tmp / 'routing-stock', tmp / 'routing-native'
    prepare(stock); prepare(native)
    # Early fallback preserves unknown/invalid values, separators and compile flags.
    for flags in (['--build-filter='], ['--build-filter=http:bad'], ['--build-filter=[bad'], ['--', '--build-filter=lib/a.final'], ['--build-filter=lib/{a,b}.final'], ['--build-filter']):
        for mode in ('auto', 'dart'):
            ref = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
            actual = execute(launcher(native, mode, flags=['--force-jit', *flags]), native)
            assert ref[0] == actual[0], (mode, flags, ref, actual)
        code, log = execute(launcher(native, 'rust', flags=flags), native)
        assert code != 0, (flags, log)
    dart_mode_comparison(tmp)
    undeclared_artifact_comparison(tmp)


GROUPS = {
    'selection-source': source_selection_comparison,
    'selection-cache': cache_selection_comparison,
    'selection-packages': package_selection_comparison,
    'glob': glob_comparison,
    'resolver': resolver_comparison,
    'state': state_comparison,
    'fallback-optional-post': lambda tmp: traced_fallback_comparison(tmp, ('optional', 'post')),
    'fallback-zero-trigger': lambda tmp: (traced_fallback_comparison(tmp, ('zero', 'trigger')), existing_fallback_comparison(tmp)),
    'routing': routing_comparison,
    'watch-source': watch_comparison,
    'watch-cache': lambda tmp: watch_comparison(tmp, cache=True),
    'watch-classification': watch_source_classification_comparison,
}


def main():
    selected = os.environ.get('BUILD_FILTER_CASE_GROUP', 'all')
    if selected != 'all' and selected not in GROUPS:
        raise ValueError(f'unknown build-filter case group: {selected}')
    groups = GROUPS if selected == 'all' else {selected: GROUPS[selected]}
    with tempfile.TemporaryDirectory(prefix='build-filter-') as temporary:
        tmp = Path(temporary)
        ENV.setdefault('BUILD_RUNNER_ACCELERATOR_CACHE', str(tmp / 'accelerator-cache'))
        for name, run_group in groups.items():
            started = time.monotonic()
            print(f'build-filter: start group={name}', flush=True)
            run_group(tmp)
            print(f'build-filter: PASS group={name} elapsed={time.monotonic() - started:.1f}s', flush=True)
    print('build-filter stock/native comparisons passed', flush=True)


if __name__ == '__main__': main()
