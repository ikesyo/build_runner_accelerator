#!/usr/bin/env python3
"""Compare build-filter bytes, deletion, status and real builder invocation history."""
from collections import Counter
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from correctness_cli import REPO, DART, ENV, NATIVE, descendants, launcher, live


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


def activity_path(root):
    return root.parent / (root.name + '-activity.jsonl')


def fixture_env(root, extra_env=None):
    env = {**ENV, 'BUILD_FILTER_HISTORY': str(history_path(root))}
    env.pop('BUILD_FILTER_ACTIVITY_LOG', None)
    env.pop('BUILD_FILTER_DELAY_MS', None)
    if extra_env:
        env.update(extra_env)
    return env


def execute(args, root, extra_env=None):
    result = subprocess.run(args, cwd=root, env=fixture_env(root, extra_env), text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=300)
    return result.returncode, result.stdout


def activity_intervals(root):
    path = activity_path(root)
    assert path.exists(), f'missing builder activity log: {path}'
    active = {}
    intervals = []
    for line in path.read_text().splitlines():
        event = json.loads(line)
        key = event['pid'], event['builder'], event['asset']
        if event['event'] == 'start':
            assert key not in active, event
            active[key] = event['timestamp_us']
        else:
            assert event['event'] == 'end' and key in active, event
            start = active.pop(key)
            end = event['timestamp_us']
            assert end >= start, (*key, start, end)
            intervals.append({
                'pid': event['pid'],
                'builder': event['builder'],
                'asset': event['asset'],
                'start': start,
                'end': end,
            })
    assert not active, ('unfinished builder activity intervals', active)
    return intervals


def has_cross_worker_overlap(intervals):
    return any(
        left['pid'] != right['pid']
        and left['start'] < right['end']
        and right['start'] < left['end']
        for index, left in enumerate(intervals)
        for right in intervals[index + 1:]
    )


def wall_events(output):
    prefix = 'Rust wall trace: '
    return [json.loads(line.split(prefix, 1)[1])
            for line in output.splitlines() if prefix in line]


def worker_metrics(output):
    prefix = 'Rust metrics: '
    line = next((line.split(prefix, 1)[1] for line in output.splitlines()
                 if prefix in line), None)
    assert line is not None, f'missing filtered worker metrics:\n{output}'
    fields = dict(field.split('=', 1) for field in line.split() if '=' in field)
    return {key: int(value) for key, value in fields.items()}


def prepare(root):
    shutil.copytree(REPO / 'fixtures/build_filter_app', root,
                    ignore=shutil.ignore_patterns('.dart_tool', '.cache', '.pub-cache', '*.mid', '*.side', '*.final', '*.ignored', 'history.log'))
    file = root / 'pubspec.yaml'
    file.write_text(file.read_text().replace('path: ../..', f'path: {REPO}'))
    code, log = execute([DART, 'pub', 'get', '--offline'], root)
    assert code == 0, log


def add_external_fixture_package(root, contents):
    # Keep the package outside Workspace's package scan, but inside the watched
    # workspace tree so its edit is a real watch event. Its source asset is
    # observed only when the builder first reads it.
    package_root = root / 'external_fixture'
    (package_root / 'lib').mkdir(parents=True, exist_ok=True)
    (package_root / 'lib/shared.asset').write_text(contents)
    (package_root / 'pubspec.yaml').write_text(
        'name: build_filter_external\n'
        'publish_to: none\n'
        'environment:\n'
        '  sdk: ">=3.11.0 <4.0.0"\n')
    pubspec = root / 'pubspec.yaml'
    pubspec_contents = pubspec.read_text()
    dependency = '  build_filter_external:\n    path: external_fixture\n'
    assert '  glob: ^2.1.3\n' in pubspec_contents
    pubspec.write_text(pubspec_contents.replace(
        '  glob: ^2.1.3\n', '  glob: ^2.1.3\n' + dependency, 1))
    code, log = execute([DART, 'pub', 'get', '--offline'], root)
    assert code == 0, log
    return package_root


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


def check(stock, native, flags=(), mode='rust', same_history=True, compile_flag='--force-jit', native_expected=False,
          jobs=1, extra_env=None):
    assert (stock / 'pubspec.lock').read_text() == (native / 'pubspec.lock').read_text()
    for root in (stock, native): history_path(root).unlink(missing_ok=True)
    # The pinned stock build_runner has no --jobs option; `jobs` controls the
    # native scheduler while stock runs at its built-in concurrency.
    reference = execute([DART, 'run', 'build_runner', 'build', compile_flag, *flags], stock)
    args = launcher(native, mode, flags=[compile_flag, *flags])
    args[args.index('--jobs=1')] = f'--jobs={jobs}'
    actual = execute(args, native, extra_env)
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


def watch(root, mode, flags, command=None, jobs=1, extra_env=None, wait_ready=True):
    log = root.parent / (root.name + '-watch.log')
    if command is not None:
        args = command
    elif mode == 'stock':
        args = [DART, 'run', 'build_runner', 'watch', '--force-jit']
        # build_runner's watch command has no --jobs option; it uses its
        # internal watch concurrency while the native side honors the value.
        args.extend(flags)
    else:
        args = launcher(root, mode, 'watch', ['--force-jit', *flags])
        args[args.index('--jobs=1')] = f'--jobs={jobs}'
    environment = fixture_env(root, extra_env)
    stream = log.open('w')
    try:
        proc = subprocess.Popen(args, cwd=root, env=environment, stdout=stream, stderr=stream, start_new_session=True)
    except BaseException:
        stream.close()
        raise
    handle = proc, log, stream
    try:
        if wait_ready:
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


def native_waiting_for_fifo_writer(launcher_pid):
    # graph::save opens graph-v3.bin.tmp for writing. With a FIFO in that path
    # and no reader, Linux reports the Rust process in wait_for_partner while
    # its open(2) is blocked. Some procfs configurations hide wchan or child
    # process metadata; in that case the caller's committed-output, unchanged-
    # graph, existing-FIFO, and live-launcher checks provide the fallback.
    try:
        children = descendants(launcher_pid)
    except OSError:
        return launcher_pid
    if not children:
        return launcher_pid
    for pid in children:
        try:
            executable = os.readlink(f'/proc/{pid}/exe')
        except FileNotFoundError:
            continue
        except OSError:
            return pid
        if Path(executable).name != NATIVE.name:
            continue
        try:
            wait_channel = Path(f'/proc/{pid}/wchan').read_text().strip()
        except OSError:
            return pid
        if 'wait_for_partner' in wait_channel or wait_channel in ('', '0', '0x0', '-'):
            return pid
    return None


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
    assert data[:4] == b'BRAG' and data[4] in (2, 3), data[:5]
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
    activity_path(native).unlink(missing_ok=True)
    assert check(stock, native, flags, jobs=4, extra_env={
        'BUILD_FILTER_ACTIVITY_LOG': str(activity_path(native)),
        'BUILD_FILTER_DELAY_MS': '60',
    }) == Counter({'lib/one.src': 1, 'lib/two.src': 1,
        'lib/shared.src': 1, 'lib/one.dart': 1, 'lib/two.dart': 1})
    previous_resolver_bytes = {
        name: outputs(native)[f'lib/{name}.final'] for name in ('one', 'two')
    }
    assert all(b'value' not in contents for contents in previous_resolver_bytes.values()), (
        previous_resolver_bytes)
    resolver_intervals = activity_intervals(native)
    resolve_intervals = [item for item in resolver_intervals if item['builder'] == 'resolve']
    shared_seed = [item for item in resolver_intervals
                   if item['builder'] == 'dartSeed' and item['asset'].endswith('|lib/shared.src')]
    assert len(resolve_intervals) == 2, resolve_intervals
    assert len(shared_seed) == 1, shared_seed
    assert has_cross_worker_overlap(resolve_intervals), (
        'generated-Dart resolver roots overlap on separate workers', resolve_intervals)
    assert any(root['pid'] != shared_seed[0]['pid']
               and root['start'] < shared_seed[0]['end']
               and shared_seed[0]['start'] < root['end'] for root in resolve_intervals), (
        'a root resolver overlapped the generated secondary Dart producer on another worker',
        resolve_intervals, shared_seed)
    assert check(stock, native, flags, jobs=4) == Counter()
    for root in (stock, native): (root / 'lib/transitive.dart').write_text('class Shared { int get value => 1; }\n')
    assert check(stock, native, flags, jobs=4) == Counter({'lib/one.dart': 1, 'lib/two.dart': 1})
    updated_resolver_bytes = outputs(native)
    for name in ('one', 'two'):
        current = updated_resolver_bytes[f'lib/{name}.final']
        assert current != previous_resolver_bytes[name] and b'value' in current, (
            name, previous_resolver_bytes[name], current)

    # With the analyzer byte store disabled, two dirty resolver roots must
    # obey the pool's single-worker boundary while retaining stock bytes and
    # action history.
    for root in (stock, native):
        (root / 'lib/transitive.dart').write_text(
            'class Shared { int get value => 2; int get extra => 3; }\n')
        history_path(root).unlink(missing_ok=True)
    stock_result = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
    native_args = launcher(native, 'rust', flags=['--force-jit', *flags])
    native_args[native_args.index('--jobs=1')] = '--jobs=4'
    native_result = execute(native_args, native, {
        'BUILD_RUNNER_ACCELERATOR_BYTE_STORE': 'off',
        'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
    })
    assert native_result[0] == stock_result[0] == 0, (stock_result, native_result)
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), native_result)
    resolver_edit_history = Counter({'lib/one.dart': 1, 'lib/two.dart': 1})
    assert history(stock) == history(native) == resolver_edit_history, (
        history(stock), history(native), resolver_edit_history)
    assert all(b'extra' in outputs(native)[f'lib/{name}.final'] for name in ('one', 'two'))
    resolver_metrics = worker_metrics(native_result[1])
    assert resolver_metrics.get('worker_starts_total', 5) <= 1, (
        resolver_metrics, native_result)
    assert resolver_metrics.get('workers_active', 5) <= 1, (resolver_metrics, native_result)

    for root in (stock, native): (root / 'lib/shared.src').write_text('edited producer, unchanged output\n')
    assert check(stock, native, flags, jobs=4) == Counter({'lib/shared.src': 1})


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
    if not cache:
        parallel_watch_comparison(stock, native)
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
            assert history(stock) == history(native) == Counter(), (
                pattern, outputs(stock), outputs(native), history(stock), history(native),
                handles[0][1].read_text(), handles[1][1].read_text())
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


def parallel_watch_comparison(stock, native):
    flags = ['--build-filter=lib/a.final,lib/b.final']
    native_activity = activity_path(native)
    native_log = native.parent / (native.name + '-watch.log')
    native_env = {
        'BUILD_FILTER_ACTIVITY_LOG': str(native_activity),
        'BUILD_FILTER_DELAY_MS': '80',
        'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
        'BUILD_RUNNER_ACCELERATOR_WALL_TRACE': '1',
    }
    handles = []
    try:
        for root in (stock, native): history_path(root).unlink(missing_ok=True)
        native_activity.unlink(missing_ok=True)
        handles.append(watch(stock, 'stock', flags, jobs=4))
        handles.append(watch(native, 'rust', flags, jobs=4, extra_env=native_env))
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, marker=marker: marker in handle[1].read_text(),
                 handle[0], handle[1])
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native) == Counter(), (history(stock), history(native))
        initial_trace = wall_events(native_log.read_text())
        assert not any(event.get('stage') in ('worker_start', 'worker_initialize', 'worker_build_lazy')
                       for event in initial_trace), initial_trace
        initial_metrics = worker_metrics(native_log.read_text())
        assert initial_metrics.get('worker_starts_total') == 0, (initial_metrics, native_log.read_text())
        assert initial_metrics.get('worker_initializes_total') == 0, (
            initial_metrics, native_log.read_text())
        assert not native_activity.exists() or not native_activity.read_text(), (
            native_activity.read_text() if native_activity.exists() else '')

        for root in (stock, native): history_path(root).unlink(missing_ok=True)
        native_activity.unlink(missing_ok=True)
        positions = [handle[1].stat().st_size for handle in handles]
        value = 'parallel watch common edit\n'
        for root in (stock, native): (root / 'lib/common.txt').write_text(value)
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
        intervals = activity_intervals(native)
        finish_intervals = [item for item in intervals if item['builder'] == 'finish'
                            and item['asset'] in ('build_filter_app|lib/a.mid',
                                                  'build_filter_app|lib/b.mid')]
        common_seed = [item for item in intervals if item['builder'] == 'seed'
                       and item['asset'] == 'build_filter_app|lib/common.txt']
        assert len(finish_intervals) == 2 and has_cross_worker_overlap(finish_intervals), (
            'filtered watch executes both selected roots concurrently', finish_intervals)
        assert len(common_seed) == 1 and history(native)['lib/common.txt'] == 1, (
            'filtered watch shares the common producer once', common_seed, history(native))
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        expected_history = Counter({
            'lib/common.txt': 1, 'lib/a.mid': 1, 'lib/b.mid': 1,
        })
        assert history(stock) == history(native) == expected_history, (
            history(stock), history(native), expected_history)

        for root in (stock, native): history_path(root).unlink(missing_ok=True)
        positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native): (root / 'lib/a.txt').unlink()
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
        after_delete = outputs(native)
        assert outputs(stock) == after_delete, (outputs(stock), after_delete)
        assert all(f'lib/a.{suffix}' not in after_delete for suffix in ('mid', 'side', 'final')), (
            'deleted selected source removes its outputs', after_delete)
        assert all(f'lib/b.{suffix}' in after_delete for suffix in ('mid', 'side', 'final')), (
            'other selected root keeps its outputs', after_delete)
        assert history(stock) == history(native), (history(stock), history(native))

        for root in (stock, native): history_path(root).unlink(missing_ok=True)
        activity_before_idle = native_activity.read_bytes() if native_activity.exists() else b''
        log_before_idle = native_log.read_text()
        trace_before_idle = wall_events(log_before_idle)
        counts_before_idle = Counter(event.get('stage') for event in trace_before_idle)
        positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native): (root / 'lib/other.noise').write_text('unrelated watch event\n')
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
        assert outputs(stock) == outputs(native) == after_delete, (
            outputs(stock), outputs(native), after_delete)
        assert history(stock) == history(native) == Counter(), (history(stock), history(native))
        activity_after_idle = native_activity.read_bytes() if native_activity.exists() else b''
        assert activity_after_idle == activity_before_idle, (
            'unrelated watch event invoked no builders', activity_before_idle, activity_after_idle)
        trace_after_idle = wall_events(native_log.read_text())
        counts_after_idle = Counter(event.get('stage') for event in trace_after_idle)
        for stage in ('worker_start', 'worker_initialize', 'worker_build_lazy'):
            assert counts_after_idle[stage] == counts_before_idle[stage], (
                'unrelated watch event starts or initializes no worker and runs no build',
                stage, counts_before_idle, counts_after_idle)
    finally:
        stop_all(handles)

    for root in (stock, native):
        (root / 'lib/a.txt').write_text('a\n')
        (root / 'lib/common.txt').write_text('common\n')
    check(stock, native)


def watch_resolver_failure_graph_comparison(tmp):
    stock, native = tmp / 'resolver-failure-stock', tmp / 'resolver-failure-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        (root / 'build.yaml').write_text(RESOLVER_BUILD_YAML)
        (root / 'lib/one.src').write_text('import-old\n')
        (root / 'lib/two.src').write_text('import-new\n')
        (root / 'lib/old.dart').write_text('class Old {}\n')
        (root / 'lib/new.dart').write_text('class New {}\n')

    flags = ['--build-filter=lib/one.final,lib/two.final']
    check(stock, native, flags)
    before_stock_outputs = outputs(stock)
    before_outputs = outputs(native)
    assert before_stock_outputs == before_outputs, (before_stock_outputs, before_outputs)
    graph_path = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
    before_graph = graph_path.read_bytes()

    handles = []
    barriers = {}
    error_marker = 'intentional resolver fixture failure'
    try:
        for root, mode in ((stock, 'stock'), (native, 'rust')):
            arm = tmp / (root.name + '-resolver-failure-arm')
            reached = tmp / (root.name + '-resolver-failure-reached')
            release = tmp / (root.name + '-resolver-failure-release')
            barriers[root] = (arm, reached, release)
            arm.write_text('armed\n')
            extras = {
                'BUILD_FILTER_RESOLVER_FAILURE_ARM': str(arm),
                'BUILD_FILTER_RESOLVER_FAILURE_REACHED': str(reached),
                'BUILD_FILTER_RESOLVER_FAILURE_RELEASE': str(release),
            }
            handles.append(watch(root, mode, flags, jobs=4, extra_env=extras))
        assert outputs(stock) == outputs(native) == before_outputs
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)

        # Change the first root's resolver closure, then fail the second root
        # after resolver work. The initial watch build succeeded, so watch keeps
        # the filtered graph while processing this failed cycle and recovery.
        for root in (stock, native):
            (root / 'lib/one.src').write_text('import-new\n')
            (root / 'lib/two.src').write_text(
                'import-new fail-after-resolver\n')
        for root, handle in zip((stock, native), handles):
            reached = barriers[root][1]
            wait(lambda reached=reached: reached.exists(), handle[0], handle[1])

        attempted_actions = {
            'lib/one.src': 1,
            'lib/one.dart': 1,
            'lib/two.src': 1,
            'lib/two.dart': 1,
        }
        # Once released, watch may retry the failed cycle while the triggering
        # edits are pending. Require each stage to have run, without prescribing
        # a failure retry count.
        for root in (stock, native):
            failed_history = history(root)
            assert all(failed_history[action] >= count
                       for action, count in attempted_actions.items()), (
                root, failed_history, attempted_actions)
        assert outputs(native) == before_outputs, (outputs(native), before_outputs)
        assert graph_path.read_bytes() == before_graph
        # The barrier holds the failure after both resolver results are
        # observed. Restore root one and queue root two's recovery before the
        # failed build exits, so watch event retries cannot race these edits.
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
        recovery_positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native):
            (root / 'lib/one.src').write_text('import-old\n')
            (root / 'lib/two.src').write_text('import-new recovery-two\n')
        for _, _, release in barriers.values():
            release.write_text('release\n')
        for handle in handles:
            wait(lambda handle=handle:
                 error_marker in handle[1].read_text(), handle[0], handle[1])

        # Only the successful recovery can update the graph. It must restore
        # root one's old edge while rebuilding root two.
        markers = ('Built with build_runner', 'Build completed (Rust frontend)')
        for index, (root, handle) in enumerate(zip((stock, native), handles)):
            marker = markers[index]
            wait(lambda root=root, handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[recovery_positions[index]:]
                 and b"import 'old.dart'" in outputs(root).get('lib/one.dart', b'')
                 and b'recovery-two' in outputs(root).get('lib/two.dart', b''),
                 handle[0], handle[1])

        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert b"import 'old.dart'" in outputs(native)['lib/one.dart'], outputs(native)
        assert b"import 'new.dart'" in outputs(native)['lib/two.dart'], outputs(native)
        assert outputs(native)['lib/one.final'] == before_outputs['lib/one.final']
        assert b'resolved:Generated:Old:0' in outputs(native)['lib/one.final']
        assert b'resolved:Generated:New:0' in outputs(native)['lib/two.final']
        recovered_outputs = outputs(native)
        assert history(stock) == Counter({
            'lib/one.src': 1, 'lib/one.dart': 1,
            'lib/two.src': 1, 'lib/two.dart': 1,
        }), (history(stock), handles[0][1].read_text())
        assert history(native) == Counter({
            'lib/two.src': 1, 'lib/two.dart': 1,
        }), (history(native), handles[1][1].read_text())

        # Only the last successful resolver graph should drive invalidation.
        # The old dependency belongs to the committed first root; if the failed
        # new graph leaked into state, this edit would miss its rebuild.
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
        refresh_positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native):
            (root / 'lib/old.dart').write_text('class Old { int get value => 1; }\n')
        for index, (root, handle) in enumerate(zip((stock, native), handles)):
            marker = markers[index]
            wait(lambda root=root, handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[refresh_positions[index]:]
                 and b'resolved:Generated:Old:1' in outputs(root).get(
                     'lib/one.final', b''),
                 handle[0], handle[1])

        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native) == Counter({'lib/one.dart': 1}), (
            history(stock), history(native), handles[0][1].read_text(),
            handles[1][1].read_text())
        assert outputs(native)['lib/one.final'] != recovered_outputs['lib/one.final']
        assert b'resolved:Generated:Old:1' in outputs(native)['lib/one.final']
        assert outputs(native)['lib/two.final'] == recovered_outputs['lib/two.final']
    finally:
        for _, _, release in barriers.values():
            release.write_text('release cleanup\n')
        stop_all(handles)



def watch_midbuild_source_edit_comparison(tmp):
    stock, native = tmp / 'watch-midbuild-stock', tmp / 'watch-midbuild-native'
    prepare(stock); prepare(native)
    flags = ['--build-filter=lib/a.final']
    check(stock, native, flags)

    handles = []
    barrier_paths = {}
    try:
        for root, mode in ((stock, 'stock'), (native, 'rust')):
            arm = tmp / (root.name + '-barrier-arm')
            reached = tmp / (root.name + '-barrier-reached')
            release = tmp / (root.name + '-barrier-release')
            barrier_paths[root] = (arm, reached, release)
            extras = {
                'BUILD_FILTER_READ_BARRIER_ARM': str(arm),
                'BUILD_FILTER_READ_BARRIER_REACHED': str(reached),
                'BUILD_FILTER_READ_BARRIER_RELEASE': str(release),
            }
            handles.append(watch(root, mode, flags, extra_env=extras))
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        for root in (stock, native): history_path(root).unlink(missing_ok=True)

        positions = [handle[1].stat().st_size for handle in handles]
        for arm, _, _ in barrier_paths.values(): arm.write_text('armed\n')
        for root in (stock, native):
            (root / 'lib/a.txt').write_text('watch build trigger edit\n')
        for root, (_, reached, _), handle in zip((stock, native), barrier_paths.values(), handles):
            wait(lambda reached=reached: reached.exists(), handle[0], handle[1])

        value = 'watch source edited during active build\n'
        for root in (stock, native): (root / 'lib/common.txt').write_text(value)
        for _, _, release in barrier_paths.values(): release.write_text('release\n')

        markers = ('Built with build_runner', 'Build completed (Rust frontend)')
        for index, handle in enumerate(handles):
            marker = markers[index]
            wait(lambda handle=handle, index=index, marker=marker:
                 handle[1].read_text()[positions[index]:].count(marker) >= 2,
                 handle[0], handle[1])

        stock_output = outputs(stock).get('lib/a.final', b'')
        native_output = outputs(native).get('lib/a.final', b'')
        assert value.encode() in stock_output, (
            'stock watch must process a source edit that arrives after its builder read',
            stock_output, history(stock), handles[0][1].read_text()[positions[0]:])
        assert value.encode() in native_output, (
            'filtered native watch must process a source edit that arrives after its builder read',
            native_output, history(native), handles[1][1].read_text()[positions[1]:])
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native) == Counter({
            'lib/a.txt': 1, 'lib/a.mid': 2, 'lib/common.txt': 1,
        }), (history(stock), history(native))
    finally:
        for _, _, release in barrier_paths.values(): release.write_text('release\n')
        stop_all(handles)


def watch_unfiltered_midbuild_source_edit_comparison(tmp):
    stock, native = tmp / 'watch-unfiltered-postscan-stock', tmp / 'watch-unfiltered-postscan-native'
    prepare(stock); prepare(native)
    check(stock, native)

    handles = []
    barrier_paths = {}
    markers = ('Built with build_runner', 'Build completed (Rust frontend)')
    try:
        for root, mode in ((stock, 'stock'), (native, 'rust')):
            arm = tmp / (root.name + '-barrier-arm')
            reached = tmp / (root.name + '-barrier-reached')
            release = tmp / (root.name + '-barrier-release')
            barrier_paths[root] = (arm, reached, release)
            extras = {
                'BUILD_FILTER_READ_BARRIER_ARM': str(arm),
                'BUILD_FILTER_READ_BARRIER_REACHED': str(reached),
                'BUILD_FILTER_READ_BARRIER_RELEASE': str(release),
            }
            # Exercise the ordinary native watch path, where the post-scan
            # snapshot previously replaced source evidence from build start.
            handles.append(watch(root, mode, [], extra_env=extras))
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        for root in (stock, native): history_path(root).unlink(missing_ok=True)

        positions = [handle[1].stat().st_size for handle in handles]
        for arm, _, _ in barrier_paths.values(): arm.write_text('armed\n')
        for root in (stock, native):
            (root / 'lib/a.txt').write_text('unfiltered watch trigger edit\n')
        for root, (_, reached, _), handle in zip((stock, native), barrier_paths.values(), handles):
            wait(lambda reached=reached: reached.exists(), handle[0], handle[1])

        value = 'unfiltered source changed after builder read\n'
        for root in (stock, native): (root / 'lib/common.txt').write_text(value)
        for _, _, release in barrier_paths.values(): release.write_text('release\n')

        for index, handle in enumerate(handles):
            marker = markers[index]
            # The unfiltered bug produced a no-work cycle instead of a second
            # successful build. Stop polling as soon as that failure is visible.
            wait(lambda handle=handle, index=index, marker=marker:
                 handle[1].read_text()[positions[index]:].count(marker) >= 2
                 or (index == 1 and 'No work to do (Rust frontend)' in
                     handle[1].read_text()[positions[index]:]),
                 handle[0], handle[1], timeout=30)

        stock_output = outputs(stock).get('lib/a.final', b'')
        native_output = outputs(native).get('lib/a.final', b'')
        assert value.encode() in stock_output, (
            'stock watch must process a source edit that arrives after its builder read',
            stock_output, history(stock), handles[0][1].read_text()[positions[0]:])
        assert value.encode() in native_output, (
            'unfiltered native watch must process a source edit that arrives after its builder read',
            native_output, history(native), handles[1][1].read_text()[positions[1]:])
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native), (history(stock), history(native))
    finally:
        for _, _, release in barrier_paths.values(): release.write_text('release cleanup\n')
        stop_all(handles)


def watch_initial_build_source_edit_comparison(tmp):
    stock, native = tmp / 'watch-initial-stock', tmp / 'watch-initial-native'
    prepare(stock); prepare(native)
    flags = ['--build-filter=lib/a.final']
    handles = []
    barriers = {}
    marker_tokens = ('Built with build_runner', 'Build completed (Rust frontend)')
    try:
        for root, mode in ((stock, 'stock'), (native, 'rust')):
            arm = tmp / (root.name + '-initial-arm')
            reached = tmp / (root.name + '-initial-reached')
            release = tmp / (root.name + '-initial-release')
            barriers[root] = (arm, reached, release)
            arm.write_text('armed\n')
            extras = {
                'BUILD_FILTER_READ_BARRIER_ARM': str(arm),
                'BUILD_FILTER_READ_BARRIER_REACHED': str(reached),
                'BUILD_FILTER_READ_BARRIER_RELEASE': str(release),
                'BUILD_FILTER_READ_BARRIER_TIMEOUT_SECONDS': '120',
            }
            # Observe both initial builds while they are held after reading the
            # common source, before either consumer writes its first output.
            handles.append(watch(
                root, mode, flags, extra_env=extras, wait_ready=False))

        for root, handle in zip((stock, native), handles):
            reached = barriers[root][1]
            wait(lambda reached=reached: reached.exists(), handle[0], handle[1], timeout=150)

        value = 'startup edit during initial build\n'
        for root in (stock, native):
            (root / 'lib/common.txt').write_text(value)
        for _, _, release in barriers.values():
            release.write_text('release\n')

        for index, handle in enumerate(handles):
            marker = marker_tokens[index]
            wait(lambda handle=handle, marker=marker:
                 handle[1].read_text().count(marker) >= 2,
                 handle[0], handle[1], timeout=240)

        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert value.encode() in outputs(stock)['lib/a.final'], outputs(stock)
        assert value.encode() in outputs(native)['lib/a.final'], outputs(native)
        expected_history = Counter({
            'lib/a.txt': 1,
            'lib/common.txt': 2,
            'lib/a.mid': 2,
        })
        assert history(stock) == history(native) == expected_history, (
            history(stock), history(native), expected_history,
            handles[0][1].read_text(), handles[1][1].read_text())
    finally:
        for _, _, release in barriers.values():
            release.write_text('release cleanup\n')
        stop_all(handles)


def writer_lock_watch_comparison(tmp):
    stock, native = tmp / 'writer-lock-stock', tmp / 'writer-lock-native'
    prepare(stock); prepare(native)
    check(stock, native)
    flags = ['--build-filter=lib/a.final']
    arm = tmp / 'writer-lock-barrier-arm'
    reached = tmp / 'writer-lock-barrier-reached'
    release = tmp / 'writer-lock-barrier-release'
    handle = None
    try:
        handle = watch(native, 'rust', flags, extra_env={
            'BUILD_FILTER_READ_BARRIER_ARM': str(arm),
            'BUILD_FILTER_READ_BARRIER_REACHED': str(reached),
            'BUILD_FILTER_READ_BARRIER_RELEASE': str(release),
        })
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        history_path(stock).unlink(missing_ok=True)
        history_path(native).unlink(missing_ok=True)
        watch_log_position = handle[1].stat().st_size
        arm.write_text('armed\n')
        trigger = 'writer lock held build edit\n'
        (stock / 'lib/a.txt').write_text(trigger)
        (native / 'lib/a.txt').write_text(trigger)
        wait(lambda: reached.exists(), handle[0], handle[1])

        # The resident watcher is paused after the builder has read its shared
        # input. Competing filters must fail before either the artifact tree or
        # the committed graph can change.
        before_outputs = outputs(native)
        graph_path = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        before_graph = graph_path.read_bytes()
        for mode in ('auto', 'rust'):
            competing = execute(
                launcher(native, mode, flags=['--force-jit', '--build-filter=lib/b.final']),
                native,
            )
            assert competing[0] != 0 and 'workspace writer lock' in competing[1].lower(), (
                mode, competing)
            assert outputs(native) == before_outputs, (mode, outputs(native), before_outputs)
            assert graph_path.read_bytes() == before_graph, mode

        release.write_text('release\n')
        wait(lambda: 'Build completed (Rust frontend)' in
             handle[1].read_text()[watch_log_position:], handle[0], handle[1])
        stop(handle)
        handle = None

        stock_a = execute(
            [DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
        assert stock_a[0] == 0, stock_a
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native), (history(stock), history(native))
        assert trigger.encode() in outputs(native)['lib/a.final'], outputs(native)

        # Releasing the watch session releases the OS lock; a later native
        # writer can build a different filter and still match stock.
        for root in (stock, native):
            (root / 'lib/b.txt').write_text('writer lock released build edit\n')
            history_path(root).unlink(missing_ok=True)
        next_flags = ['--build-filter=lib/b.final']
        stock_b = execute(
            [DART, 'run', 'build_runner', 'build', '--force-jit', *next_flags], stock)
        native_b = execute(
            launcher(native, 'rust', flags=['--force-jit', *next_flags]), native)
        assert native_b[0] == stock_b[0] == 0, (stock_b, native_b)
        assert '(Rust frontend)' in native_b[1], native_b
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), native_b)
        assert history(stock) == history(native), (history(stock), history(native))
    finally:
        release.write_text('release cleanup\n')
        if handle is not None:
            stop_all([handle])


def late_fallback_writer_lock_comparison(tmp):
    stock, native = tmp / 'late-lock-stock', tmp / 'late-lock-native'
    prepare(stock); prepare(native)
    flags = ['--build-filter=lib/a.final']
    check(stock, native, flags, compile_flag='--force-jit')

    barriers = {}
    handles = []
    try:
        for root in (stock, native):
            barriers[root] = tuple(
                tmp / f'{root.name}-late-lock-{suffix}'
                for suffix in ('arm', 'reached', 'release')
            )
        for root, mode in ((stock, 'stock'), (native, 'auto')):
            arm, reached, release = barriers[root]
            handles.append(watch(root, mode, flags, extra_env={
                'BUILD_FILTER_READ_BARRIER_ARM': str(arm),
                'BUILD_FILTER_READ_BARRIER_REACHED': str(reached),
                'BUILD_FILTER_READ_BARRIER_RELEASE': str(release),
                'BUILD_FILTER_READ_BARRIER_TIMEOUT_SECONDS': '120',
            }))

        stock_initial_handle, native_handle = handles
        stop(stock_initial_handle)
        handles = [native_handle]
        config_position = native_handle[1].stat().st_size
        noise_builder = """  noise:
    import: 'package:build_filter_app/builder.dart'
    builder_factories: [noise]
    build_extensions: {'.noise': ['.ignored']}
    auto_apply: root_package
    build_to: source
"""
        for root in (stock, native):
            config = root / 'build.yaml'
            contents = config.read_text()
            assert contents.count(noise_builder) == 1, contents
            # An unrelated optional builder is enough to route filtered auto
            # to stock while keeping the selected .txt -> .mid -> .final path.
            config.write_text(contents.replace(
                noise_builder,
                noise_builder.replace(
                    'build_to: source',
                    'build_to: cache\n    is_optional: true',
                ),
                1,
            ))

        wait(lambda: 'using Dart fallback' in native_handle[1].read_text(),
             native_handle[0], native_handle[1])
        wait(lambda: 'Built with build_runner' in
             native_handle[1].read_text()[config_position:],
             native_handle[0], native_handle[1])

        # A direct stock reference starts from the same optional config that
        # the native watch handed off to. This avoids relying on stock's own
        # hot-reload transition while still comparing the same watch behavior.
        arm, reached, release = barriers[stock]
        stock_handle = watch(stock, 'stock', flags, extra_env={
            'BUILD_FILTER_READ_BARRIER_ARM': str(arm),
            'BUILD_FILTER_READ_BARRIER_REACHED': str(reached),
            'BUILD_FILTER_READ_BARRIER_RELEASE': str(release),
            'BUILD_FILTER_READ_BARRIER_TIMEOUT_SECONDS': '120',
        })
        handles.insert(0, stock_handle)
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))

        # The config-change cycle is complete in both stock watches. Compare
        # only the next input-triggered cycle, with stock held after reading
        # a.mid and before it publishes the dependent output.
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
            arm, _, _ = barriers[root]
            arm.write_text('armed\n')
            (root / 'lib/a.txt').write_text('late fallback lock watch edit\n')
        positions = [handle[1].stat().st_size for handle in handles]
        for root, handle in zip((stock, native), handles):
            reached = barriers[root][1]
            wait(lambda reached=reached: reached.exists(), handle[0], handle[1])

        graph_path = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        before_outputs = outputs(native)
        before_graph = graph_path.read_bytes()
        for mode in ('auto', 'rust'):
            competing = execute(
                launcher(native, mode, flags=['--force-jit', '--build-filter=lib/b.final']),
                native,
            )
            assert competing[0] != 0 and 'workspace writer lock' in competing[1].lower(), (
                mode, competing)
            assert outputs(native) == before_outputs, (mode, outputs(native), before_outputs)
            assert graph_path.read_bytes() == before_graph, mode

        for _, _, release in barriers.values():
            release.write_text('release\n')
        for index, handle in enumerate(handles):
            wait(lambda index=index, handle=handle:
                 'Built with build_runner' in handle[1].read_text()[positions[index]:],
                 handle[0], handle[1])
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert history(stock) == history(native), (history(stock), history(native))
        assert b'late fallback lock watch edit' in outputs(stock)['lib/a.mid']
        assert b'late fallback lock watch edit' in outputs(native)['lib/a.mid']
    finally:
        for _, _, release in barriers.values():
            release.write_text('release cleanup\n')
        stop_all(handles)

    # The lock must be released with the exec'd stock watch. Restore the
    # supported plan, then compare the next native run with stock.
    for root in (stock, native):
        config = root / 'build.yaml'
        config.write_text(config.read_text().replace(
            'build_to: cache\n    is_optional: true', 'build_to: source', 1))
        (root / 'lib/a.txt').write_text('native resumed after stock watch\n')
        history_path(root).unlink(missing_ok=True)
    stock_build = execute(
        [DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
    native_build = execute(
        launcher(native, 'auto', flags=['--force-jit', *flags]), native)
    assert stock_build[0] == native_build[0] == 0, (stock_build, native_build)
    assert '(Rust frontend)' in native_build[1], native_build
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
    assert b'native resumed after stock watch' in outputs(native)['lib/a.final']

    # The first rebuild also absorbs the optional-config graph transition on
    # the stock control. A second stable-plan edit gives both engines the same
    # incremental history to compare after the lock has been released.
    for root in (stock, native):
        (root / 'lib/a.txt').write_text('native stable lock released edit\n')
        history_path(root).unlink(missing_ok=True)
    stock_next = execute(
        [DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
    native_next = execute(
        launcher(native, 'auto', flags=['--force-jit', *flags]), native)
    assert stock_next[0] == native_next[0] == 0, (stock_next, native_next)
    assert '(Rust frontend)' in native_next[1], native_next
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
    assert history(stock) == history(native), (history(stock), history(native))
    assert b'native stable lock released edit' in outputs(native)['lib/a.final']


def watch_unknown_external_source_comparison(tmp):
    stock, native = tmp / 'watch-external-stock', tmp / 'watch-external-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        add_external_fixture_package(root, 'external-version-1\n')
    flags = ['--build-filter=lib/a.final,lib/b.final']
    # Establish a clean selected graph before the builder starts observing the
    # external package source for the first time in the resident watch session.
    check(stock, native, flags)

    handles = []
    barriers = {}
    marker_tokens = ('Built with build_runner', 'Build completed (Rust frontend)')
    try:
        for root, mode in ((stock, 'stock'), (native, 'rust')):
            arm = tmp / (root.name + '-external-arm')
            allow_b = tmp / (root.name + '-external-allow-b')
            reached = tmp / (root.name + '-external-reached')
            release = tmp / (root.name + '-external-release')
            next_reached = tmp / (root.name + '-external-next-reached')
            next_release = tmp / (root.name + '-external-next-release')
            barriers[root] = (arm, allow_b, reached, release, next_reached, next_release)
            extra_env = {
                'BUILD_FILTER_EXTERNAL_READ': '1',
                'BUILD_FILTER_EXTERNAL_READ_ARM': str(arm),
                'BUILD_FILTER_EXTERNAL_READ_B_ALLOW': str(allow_b),
                'BUILD_FILTER_EXTERNAL_READ_REACHED': str(reached),
                'BUILD_FILTER_EXTERNAL_READ_RELEASE': str(release),
                'BUILD_FILTER_EXTERNAL_READ_NEXT_REACHED': str(next_reached),
                'BUILD_FILTER_EXTERNAL_READ_NEXT_RELEASE': str(next_release),
            }
            handles.append(watch(root, mode, flags, jobs=4, extra_env=extra_env))

        for index, handle in enumerate(handles):
            marker = marker_tokens[index]
            wait(lambda handle=handle, marker=marker: marker in handle[1].read_text(),
                 handle[0], handle[1])
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
        positions = [handle[1].stat().st_size for handle in handles]
        for arm, _, _, _, _, _ in barriers.values():
            arm.write_text('armed\n')
        for root in (stock, native):
            (root / 'lib/a.txt').write_text('external-read cycle a\n')
            (root / 'lib/b.txt').write_text('external-read cycle b\n')

        for root, handle in zip((stock, native), handles):
            reached = barriers[root][2]
            wait(lambda reached=reached: (reached / 'a.mid').exists(), handle[0], handle[1])
        # A has already read v1 and is held after the read. Edit the external
        # source, then let A finish; stock runs primary inputs sequentially, so
        # B's actual read reveals whether that build reuses A's source bytes.
        for root in (stock, native):
            (root / 'external_fixture/lib/shared.asset').write_text('external-version-2\n')
            barriers[root][1].write_text('allow b read\n')
        for _, _, _, release, _, _ in barriers.values():
            release.write_text('release first build\n')

        for index, handle in enumerate(handles):
            marker = marker_tokens[index]
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
        for root, handle in zip((stock, native), handles):
            reached = barriers[root][2]
            wait(lambda reached=reached: (reached / 'b.mid').exists(), handle[0], handle[1])
        for root in (stock, native):
            current = outputs(root)
            assert b'external-version-1' in current['lib/a.final'], current
            assert b'external-version-1' in current['lib/b.final'], current
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))

        # The external source edit is itself a queued watch event. Hold A after
        # its read so the pre-commit outputs and activity history remain
        # inspectable; stock runs B only after A is released.
        for root, handle in zip((stock, native), handles):
            next_reached = barriers[root][4]
            wait(lambda next_reached=next_reached: (next_reached / 'a.mid').exists(),
                 handle[0], handle[1], timeout=60)
            current = outputs(root)
            assert b'external-version-1' in current['lib/a.final'], current
            assert b'external-version-1' in current['lib/b.final'], current
        for _, _, _, _, _, next_release in barriers.values():
            next_release.write_text('release second build\n')
        for index, handle in enumerate(handles):
            marker = marker_tokens[index]
            wait(lambda handle=handle, index=index, marker=marker:
                 handle[1].read_text()[positions[index]:].count(marker) >= 2,
                 handle[0], handle[1])

        expected_history = Counter({
            'lib/a.txt': 1, 'lib/b.txt': 1, 'lib/a.mid': 2, 'lib/b.mid': 2,
        })
        assert outputs(stock) == outputs(native), (outputs(stock), outputs(native))
        assert all(b'external-version-2' in outputs(root)[f'lib/{name}.final']
                   for root in (stock, native) for name in ('a', 'b')), (
            outputs(stock), outputs(native))
        assert history(stock) == history(native) == expected_history, (
            history(stock), history(native), expected_history)

        # Once the next cycle records the shared source observation as v2,
        # an unrelated watch event must not keep the consumers dirty.
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
        before = outputs(stock)
        positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native):
            (root / 'lib/other.noise').write_text('external-source no-op event\n')
        for index, handle in enumerate(handles):
            marker = marker_tokens[index]
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[positions[index]:], handle[0], handle[1])
        assert outputs(stock) == outputs(native) == before, (outputs(stock), outputs(native), before)
        assert history(stock) == history(native) == Counter(), (
            history(stock), history(native), handles[0][1].read_text(), handles[1][1].read_text())
    finally:
        for _, _, _, release, _, next_release in barriers.values():
            release.write_text('release cleanup\n')
            next_release.write_text('release cleanup\n')
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


def watch_failed_initial_recovery_generated_rename_comparison(tmp):
    stock, native = tmp / 'classification-failure-stock', tmp / 'classification-failure-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        (root / 'lib/a.txt').write_text('use-glob\n')
        (root / 'lib/c.txt').write_text('initial c source\n')
    define = '--define=:finish=conditional_glob=true'
    flags = ['--build-filter=lib/a.final', define]
    check(stock, native, flags)
    assert (native / 'lib/c.side').exists()
    assert b'initial c source' in (native / 'lib/a.final').read_bytes()
    for root in (stock, native):
        history_path(root).unlink(missing_ok=True)
        (root / 'lib/common.txt').write_text('fail\n')

    handles = []
    try:
        handles.append(watch(stock, 'stock', flags, wait_ready=False))
        handles.append(watch(native, 'rust', flags, wait_ready=False))
        for index, (proc, log, _) in enumerate(handles):
            if index == 0:
                wait(lambda log=log:
                     'intentional build-filter fixture failure' in log.read_text()
                     and 'Failed to build with build_runner' in log.read_text(),
                     proc, log, timeout=60)
            else:
                wait(lambda log=log:
                     'initial watch build failed:' in log.read_text()
                     and 'Watching ' in log.read_text(),
                     proc, log, timeout=60)
        for root in (stock, native):
            assert history(root)['lib/common.txt'] > 0
            history_path(root).unlink(missing_ok=True)

        recovery_positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native):
            (root / 'lib/common.txt').write_text('recovered shared source\n')
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[recovery_positions[index]:],
                 handle[0], handle[1])
        for root in (stock, native):
            assert b'recovered shared source' in (root / 'lib/a.final').read_bytes()
            assert history(root)['lib/common.txt'] > 0
        assert outputs(stock) == outputs(native)
        assert history(stock) == history(native), (history(stock), history(native))

        # Removing the producer and its artifact leaves c.side classified as
        # generated in the retained filtered graph until an ADD reclassifies it.
        for root in (stock, native): history_path(root).unlink(missing_ok=True)
        delete_positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native):
            (root / 'lib/c.txt').unlink()
            (root / 'lib/c.side').unlink(missing_ok=True)
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[delete_positions[index]:],
                 handle[0], handle[1])
        assert outputs(stock) == outputs(native)
        assert history(stock) == history(native), (history(stock), history(native))
        assert not (stock / 'lib/c.side').exists()
        assert not (native / 'lib/c.side').exists()

        for root in (stock, native): history_path(root).unlink(missing_ok=True)
        rename_positions = [handle[1].stat().st_size for handle in handles]
        for root in (stock, native):
            destination = root / 'lib/c.side'
            staged = root.parent / (root.name + '-external-c.side')
            staged.write_text('renamed external c source\n')
            staged.replace(destination)
        for index, handle in enumerate(handles):
            marker = 'Built with build_runner' if index == 0 else 'Build completed (Rust frontend)'
            wait(lambda handle=handle, index=index, marker=marker:
                 marker in handle[1].read_text()[rename_positions[index]:],
                 handle[0], handle[1])
        for root in (stock, native):
            assert b'renamed external c source' in (root / 'lib/a.final').read_bytes()
            assert (root / 'lib/c.side').read_bytes() == b'renamed external c source\n'
        assert outputs(stock) == outputs(native)
        assert history(stock) == history(native), (history(stock), history(native))
    finally:
        stop_all(handles)


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
    watch_failed_initial_recovery_generated_rename_comparison(tmp)


def filtered_default_jobs_comparison(tmp):
    stock, native = tmp / 'default-jobs-stock', tmp / 'default-jobs-native'
    prepare(stock); prepare(native)
    flags = ['--force-jit', '--build-filter=lib/a.final,lib/b.final']
    reference = execute([DART, 'run', 'build_runner', 'build', *flags], stock)
    native_args = launcher(native, 'rust', flags=flags)
    native_args.remove('--jobs=1')
    actual = execute(native_args, native, {'BUILD_RUNNER_ACCELERATOR_METRICS': '1'})
    assert actual[0] == reference[0] == 0, (reference, actual)
    assert '(Rust frontend)' in actual[1], actual
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), actual)
    expected_history = Counter({
        'lib/a.txt': 1, 'lib/b.txt': 1, 'lib/common.txt': 1,
        'lib/a.mid': 1, 'lib/b.mid': 1,
    })
    assert history(stock) == history(native) == expected_history, (
        history(stock), history(native), expected_history)
    metrics = worker_metrics(actual[1])
    assert metrics.get('worker_starts_total') == 1, (metrics, actual)
    assert metrics.get('workers_active') == 1, (metrics, actual)


def source_selection_comparison(tmp):
    filtered_default_jobs_comparison(tmp)
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
    root_cache_source_collision_comparison(tmp)
    artifact_commit_graph_save_crash_comparison(tmp)
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


def root_cache_source_collision_comparison(tmp):
    stock, native = tmp / 'root-collision-stock', tmp / 'root-collision-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        config = root / 'build.yaml'
        config.write_text(config.read_text().replace('build_to: source', 'build_to: cache', 1))
        (root / 'lib/a.mid').write_text('root package source collision\n')

    # Stock classifies package-path files matching declared cache outputs as
    # conflicts even when their producer is outside the selected roots. The
    # conflicting source must be deleted, while the unselected cached output
    # must remain absent.
    flags = ['--build-filter=lib/b.final']
    reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
    actual = execute(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
    assert actual[0] == reference[0] == 0, (reference, actual)
    assert '(Rust frontend)' in actual[1], actual
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), actual)
    for root in (stock, native):
        assert not (root / 'lib/a.mid').exists(), root
    assert 'cache/build_filter_app/lib/a.mid' not in outputs(stock), outputs(stock)
    assert 'cache/build_filter_app/lib/a.mid' not in outputs(native), outputs(native)

    # Once selected, the same action publishes the logical asset in the cache
    # and still removes the conflicting package-path source.
    check(stock, native, ['--build-filter=lib/a.final'])
    for root in (stock, native):
        assert not (root / 'lib/a.mid').exists(), root
    assert 'cache/build_filter_app/lib/a.mid' in outputs(stock), outputs(stock)
    assert 'cache/build_filter_app/lib/a.mid' in outputs(native), outputs(native)


def artifact_commit_graph_save_crash_comparison(tmp):
    stock, native = tmp / 'graph-crash-stock', tmp / 'graph-crash-native'
    prepare(stock); prepare(native)
    for root in (stock, native):
        config = root / 'build.yaml'
        config.write_text(config.read_text().replace('build_to: source', 'build_to: cache', 1))
    check(stock, native)

    # A source/cache transition makes the native commit clean its old artifact
    # tree. Block the later graph save so a forced process kill leaves the old
    # graph beside already committed new source outputs.
    for root in (stock, native):
        config = root / 'build.yaml'
        config.write_text(config.read_text().replace('build_to: cache', 'build_to: source', 1))
        (root / 'lib/a.txt').write_text('crash window cache-to-source edit\n')

    graph_path = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
    graph_temp = graph_path.with_name('graph-v3.bin.tmp')
    before_graph = graph_path.read_bytes()
    assert not graph_temp.exists(), graph_temp
    os.mkfifo(graph_temp)
    assert graph_temp.is_fifo(), graph_temp

    log = tmp / 'graph-crash-native.log'
    stream = log.open('w')
    proc = None
    try:
        args = launcher(native, 'rust', flags=[
            '--force-jit', '--build-filter=lib/a.final',
        ])
        proc = subprocess.Popen(
            args, cwd=native, env=fixture_env(native), stdout=stream,
            stderr=stream, start_new_session=True,
        )

        def outputs_committed_and_graph_blocked():
            current = outputs(native)
            token = b'crash window cache-to-source edit'
            committed = all(
                token in current.get(f'lib/a.{suffix}', b'')
                for suffix in ('mid', 'side', 'final')
            )
            return (
                committed
                and not any(path.startswith('cache/') for path in current)
                and graph_temp.is_fifo()
                and graph_path.read_bytes() == before_graph
                and proc.poll() is None
                and native_waiting_for_fifo_writer(proc.pid) is not None
            )

        wait(outputs_committed_and_graph_blocked, proc, log, timeout=240)
        assert proc.poll() is None, log.read_text()
        assert graph_temp.is_fifo(), graph_temp
        assert graph_path.read_bytes() == before_graph

        # Kill the launcher group and any supervised descendants while native
        # graph::save is blocked opening the FIFO.
        children = descendants(proc.pid)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for child in children:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        proc.wait(timeout=15)
    finally:
        if proc is not None and proc.poll() is None:
            children = descendants(proc.pid)
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for child in children:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.wait()
        stream.close()
        graph_temp.unlink(missing_ok=True)

    assert proc.returncode != 0, (proc.returncode, log.read_text())
    assert graph_path.read_bytes() == before_graph
    assert b'crash window cache-to-source edit' in outputs(native)['lib/a.final']
    history_path(native).unlink(missing_ok=True)
    history_path(stock).unlink(missing_ok=True)

    stock_result = execute(
        [DART, 'run', 'build_runner', 'build', '--force-jit', '--build-filter=lib/a.final'],
        stock,
    )
    native_result = execute(
        launcher(native, 'rust', flags=['--force-jit', '--build-filter=lib/a.final']),
        native,
    )
    assert stock_result[0] == native_result[0] == 0, (stock_result, native_result)
    assert '(Rust frontend)' in native_result[1], native_result
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), native_result)
    assert history(stock) == history(native), (history(stock), history(native))
    assert not any(path.startswith('cache/') for path in outputs(native)), outputs(native)
    assert graph_path.read_bytes() != before_graph


def parallel_history_comparison(tmp):
    stock, native = tmp / 'parallel-history-stock', tmp / 'parallel-history-native'
    prepare(stock); prepare(native)
    parallel_inputs = [f'parallel_{index:02}' for index in range(40)]
    for root in (stock, native):
        for name in parallel_inputs:
            (root / f'lib/{name}.txt').write_text(f'{name} input\n')

    # Each selected finish action requests the same generated secondary input.
    # The common seed and each selected producer must be recorded once. The
    # broad pattern also includes empty.final, whose primary currently emits
    # no siblings but may begin doing so after an edit.
    filtered_flags = ['--force-jit', '--build-filter=lib/*.final']

    def rust_four_jobs(flags):
        args = launcher(native, 'rust', flags=flags)
        args[args.index('--jobs=1')] = '--jobs=4'
        return args

    def stock_build(flags):
        return [DART, 'run', 'build_runner', 'build', *flags]

    for root in (stock, native):
        history_path(root).unlink(missing_ok=True)
        activity_path(root).unlink(missing_ok=True)
    reference = execute(stock_build(filtered_flags), stock)
    actual = execute(rust_four_jobs(filtered_flags), native, {
        'BUILD_FILTER_ACTIVITY_LOG': str(activity_path(native)),
        'BUILD_FILTER_DELAY_MS': '60',
    })
    assert actual[0] == reference[0] == 0, (reference, actual)
    assert '(Rust frontend)' in actual[1], actual
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), actual)
    filtered_intervals = activity_intervals(native)
    finish_intervals = [
        interval for interval in filtered_intervals
        if interval['builder'] == 'finish' and '|lib/parallel_' in interval['asset']
    ]
    assert len(finish_intervals) == len(parallel_inputs), (
        'all filtered root builders ran', len(finish_intervals), len(parallel_inputs))
    assert has_cross_worker_overlap(finish_intervals), (
        'filtered jobs=4 ran distinct root builders concurrently', finish_intervals, actual)
    initial_roots = ['a', 'b', *parallel_inputs]
    filtered_history = (
        Counter({f'lib/{name}.txt': 1 for name in initial_roots})
        + Counter({f'lib/{name}.mid': 1 for name in initial_roots})
        + Counter({'lib/empty.txt': 1, 'lib/common.txt': 1, 'lib/common.mid': 1})
    )
    assert history(stock) == history(native) == filtered_history, (
        'filtered jobs=4 action history', history(stock), history(native), filtered_history)
    filtered_outputs = outputs(native)
    for name in parallel_inputs:
        assert all(f'lib/{name}.{suffix}' in filtered_outputs for suffix in ('mid', 'side', 'final')), (
            name, [path for path in filtered_outputs if f'lib/{name}.' in path])
    assert all(f'lib/common.{suffix}' in filtered_outputs for suffix in ('mid', 'side')), (
        [path for path in filtered_outputs if 'lib/common.' in path])

    # A filtered no-op must not start or initialize any Dart workers.
    for root in (stock, native): history_path(root).unlink(missing_ok=True)
    no_op_reference = execute(stock_build(filtered_flags), stock)
    no_op_actual = execute(rust_four_jobs(filtered_flags), native, {
        'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
        'BUILD_RUNNER_ACCELERATOR_WALL_TRACE': '1',
    })
    assert no_op_actual[0] == no_op_reference[0] == 0, (no_op_reference, no_op_actual)
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), no_op_actual)
    assert history(stock) == history(native) == Counter(), (
        history(stock), history(native), no_op_actual)
    no_op_metrics = worker_metrics(no_op_actual[1])
    assert no_op_metrics.get('worker_starts_total') == 0, (no_op_metrics, no_op_actual)
    assert no_op_metrics.get('worker_initializes_total') == 0, (no_op_metrics, no_op_actual)
    no_op_trace = wall_events(no_op_actual[1])
    assert not any(event.get('stage') in ('worker_start', 'worker_initialize', 'worker_build_lazy')
                   for event in no_op_trace), no_op_trace

    # Keep all 40 outputs selected while changing only one input. The scheduler
    # must size its worker pool for dirty work instead of all matching roots.
    for root in (stock, native):
        (root / 'lib/parallel_00.txt').write_text('parallel_00 edited input\n')
        history_path(root).unlink(missing_ok=True)
    one_file_flags = filtered_flags
    one_file_reference = execute(stock_build(one_file_flags), stock)
    one_file_actual = execute(rust_four_jobs(one_file_flags), native, {
        'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
        'BUILD_RUNNER_ACCELERATOR_WALL_TRACE': '1',
    })
    assert one_file_actual[0] == one_file_reference[0] == 0, (one_file_reference, one_file_actual)
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), one_file_actual)
    one_file_history = Counter({'lib/parallel_00.txt': 1, 'lib/parallel_00.mid': 1})
    assert history(stock) == history(native) == one_file_history, (
        history(stock), history(native), one_file_history)
    one_file_metrics = worker_metrics(one_file_actual[1])
    assert one_file_metrics.get('worker_starts_total', 5) <= 1, (one_file_metrics, one_file_actual)
    assert one_file_metrics.get('workers_active', 5) <= 1, (one_file_metrics, one_file_actual)

    # The selected empty producer published no siblings in the initial broad
    # build. After filtered reuse and an unrelated one-file edit above, the
    # same broad demand must discover its newly materialized final.
    assert not any(path.startswith('lib/empty.') for path in outputs(native)), outputs(native)
    for root in (stock, native):
        (root / 'lib/empty.txt').write_text('expanded from empty input\n')
        history_path(root).unlink(missing_ok=True)
    materialized_reference = execute(stock_build(filtered_flags), stock)
    materialized_actual = execute(rust_four_jobs(filtered_flags), native)
    assert materialized_actual[0] == materialized_reference[0] == 0, (
        materialized_reference, materialized_actual)
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), materialized_actual)
    assert all(f'lib/empty.{suffix}' in outputs(native) for suffix in ('mid', 'side', 'final')), (
        [path for path in outputs(native) if path.startswith('lib/empty.')])
    assert b'expanded from empty input' in outputs(native)['lib/empty.final']
    expected_empty_history = Counter({'lib/empty.txt': 1, 'lib/empty.mid': 1})
    assert history(stock) == history(native) == expected_empty_history, (
        history(stock), history(native), expected_empty_history, materialized_actual)

    # Start from empty action/output state and fan out enough actions to exercise
    # concurrent writes from multiple workers to the shared history file.
    generated_suffixes = {'.mid', '.side', '.final', '.ignored', '.post'}
    for root in (stock, native):
        history_path(root).unlink(missing_ok=True)
        (root / 'lib/empty.txt').write_text('empty\n')
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
    reference = execute(stock_build(full_flags), stock)
    actual = execute(rust_four_jobs(full_flags), native)
    assert actual[0] == reference[0] == 0, (reference, actual)
    assert '(Rust frontend)' in actual[1], actual
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), actual)
    assert history(stock) == history(native) == full_history, (
        'unfiltered jobs=4 action history', history(stock), history(native), full_history)

    # Matching both siblings of one source action schedules that producer
    # once, even though two selected output roots point to it.
    for root in (stock, native):
        (root / 'lib/parallel_00.txt').write_text('parallel_00 sibling edit\n')
        history_path(root).unlink(missing_ok=True)
    sibling_flags = [
        '--force-jit',
        '--build-filter=lib/parallel_00.mid,lib/parallel_00.side',
    ]
    sibling_reference = execute(stock_build(sibling_flags), stock)
    sibling_actual = execute(rust_four_jobs(sibling_flags), native, {
        'BUILD_RUNNER_ACCELERATOR_METRICS': '1',
    })
    assert sibling_actual[0] == sibling_reference[0] == 0, (sibling_reference, sibling_actual)
    assert outputs(stock) == outputs(native), (outputs(stock), outputs(native), sibling_actual)
    sibling_history = Counter({'lib/parallel_00.txt': 1})
    assert history(stock) == history(native) == sibling_history, (
        history(stock), history(native), sibling_history)
    assert all(f'lib/parallel_00.{suffix}' in outputs(native) for suffix in ('mid', 'side'))
    sibling_metrics = worker_metrics(sibling_actual[1])
    assert sibling_metrics.get('worker_starts_total', 5) <= 1, (
        sibling_metrics, sibling_actual)
    assert sibling_metrics.get('workers_active', 5) <= 1, (sibling_metrics, sibling_actual)

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
    def selected_outputs(root, roots=('a',)):
        current = outputs(root)
        selected = tuple(
            f'lib/{name}.{suffix}' for name in roots for suffix in ('final', 'mid', 'side')
        ) + ('lib/common.mid', 'lib/common.side')
        return {path: current[path] for path in selected if path in current}

    def recover(stock, native, flags, expected_stock_history, expected_native_history,
                jobs=1, roots=('a',)):
        for root in (stock, native):
            history_path(root).unlink(missing_ok=True)
        reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
        args = launcher(native, 'rust', flags=['--force-jit', *flags])
        args[args.index('--jobs=1')] = f'--jobs={jobs}'
        actual = execute(args, native)
        assert actual[0] == reference[0] == 0, (flags, reference, actual)
        assert selected_outputs(stock, roots) == selected_outputs(native, roots), (
            flags, selected_outputs(stock, roots), selected_outputs(native, roots), actual)
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
        roots = ('a', 'b') if rpc == 'read' else ('a',)
        flags = [f"--build-filter={','.join(f'lib/{name}.final' for name in roots)}", catch_flag]
        if rpc == 'read':
            # Output digest changes dirty both consumers before their retained
            # secondary read order can demand the shared producer. Stock stores
            # read assets in a HashSet, so that order can place common.side
            # before the generated primary and fail before either consumer runs.
            for root in (stock, native):
                for name in roots:
                    (root / f'lib/{name}.final').unlink()
        previous_outputs = outputs(native)
        graph = native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        previous_graph = graph.read_bytes()

        for root in (stock, native):
            (root / 'lib/common.txt').write_text('fail\n')
            if rpc == 'read':
                (root / 'lib/a.txt').write_text('changed primary a\n')
                (root / 'lib/b.txt').write_text('changed primary b\n')
            history_path(root).unlink(missing_ok=True)
        failure_env = None
        if rpc == 'read':
            activity_path(native).unlink(missing_ok=True)
            failure_env = {
                'BUILD_FILTER_ACTIVITY_LOG': str(activity_path(native)),
                'BUILD_FILTER_DELAY_MS': '60',
            }
        reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
        native_args = launcher(native, 'rust', flags=['--force-jit', *flags])
        native_args[native_args.index('--jobs=1')] = '--jobs=4' if rpc == 'read' else '--jobs=1'
        actual = execute(native_args, native, failure_env)
        assert reference[0] == actual[0] != 0, (rpc, reference, actual)
        assert 'intentional build-filter fixture failure' in actual[1], (rpc, actual)
        # Stock may write the consumer's caught-error output before reporting
        # its failed build. Native keeps its all-success transaction boundary.
        assert outputs(native) == previous_outputs, (rpc, outputs(native), previous_outputs)
        assert graph.read_bytes() == previous_graph, rpc
        if rpc == 'read':
            intervals = activity_intervals(native)
            finish_intervals = [item for item in intervals
                                if item['builder'] == 'finish' and item['asset'] in (
                                    'build_filter_app|lib/a.mid', 'build_filter_app|lib/b.mid')]
            common_seed = [item for item in intervals
                           if item['builder'] == 'seed'
                           and item['asset'] == 'build_filter_app|lib/common.txt']
            assert len(finish_intervals) == 2, finish_intervals
            assert len(common_seed) == 1 and history(native)['lib/common.txt'] == 1, (
                common_seed, history(native))
            assert has_cross_worker_overlap(finish_intervals), (
                'both filtered consumers wait concurrently on the shared failing producer',
                finish_intervals, actual)
            assert any(root['pid'] != common_seed[0]['pid']
                       and root['start'] < common_seed[0]['end']
                       and common_seed[0]['start'] < root['end'] for root in finish_intervals), (
                'a second worker waited while the common producer was failing',
                finish_intervals, common_seed)

        for root in (stock, native):
            (root / 'lib/common.txt').write_text('recovered common\n')
        recovered_stock_history = (
            Counter({f'lib/{name}.mid': 1 for name in roots})
            + Counter({'lib/common.txt': 1})
        )
        recovered_native_history = recovered_stock_history.copy()
        if rpc == 'read':
            recovered_native_history.update({f'lib/{name}.txt': 1 for name in roots})
        rebuilt = recover(stock, native, flags,
                          recovered_stock_history, recovered_native_history,
                          jobs=4 if rpc == 'read' else 1, roots=roots)
        assert rebuilt == recovered_native_history, (rpc, rebuilt)
        for name in roots:
            assert b'recovered common' in (native / f'lib/{name}.final').read_bytes(), rpc
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
            Counter({'lib/a.txt': 1, 'lib/common.txt': 1, 'lib/a.mid': 1}), roots=('a',))
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
    'watch-source': lambda tmp: (
        watch_comparison(tmp),
        watch_resolver_failure_graph_comparison(tmp),
        watch_midbuild_source_edit_comparison(tmp),
        watch_unfiltered_midbuild_source_edit_comparison(tmp),
        watch_initial_build_source_edit_comparison(tmp),
        watch_unknown_external_source_comparison(tmp),
        writer_lock_watch_comparison(tmp),
        late_fallback_writer_lock_comparison(tmp),
    ),
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
