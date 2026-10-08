#!/usr/bin/env python3
"""Stock/native/launcher CLI comparisons in disposable workspaces."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
DART = os.environ.get('DART_BIN', str(REPO / '.toolchains/dart-wrapper'))
NATIVE = REPO / 'rust/target/debug/build_runner_accelerator'
LAUNCHER = [DART, f'--packages={REPO}/.dart_tool/package_config.json',
            str(REPO / 'bin/build_runner_accelerator.dart')]
ENV = {**os.environ, 'PUB_CACHE': os.environ.get('PUB_CACHE', str(REPO / '.pub-cache')),
       'BUILD_RUNNER_ACCELERATOR_BIN': str(NATIVE),
       'BUILD_RUNNER_ACCELERATOR_WORKER_AOT': '0',
       'DART_SUPPRESS_ANALYTICS': 'true'}
ENV.pop('HOME', None)


def run(args, root, expected=0, env=ENV):
    result = subprocess.run(args, cwd=root, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    assert result.returncode == expected, (args, result.returncode, result.stdout)
    return result.stdout


def files(root):
    return {str(p.relative_to(root)): p.read_bytes()
            for p in (root / 'lib').rglob('*') if p.suffix in ('.copy', '.final')}


def prepare(root):
    (root / 'lib').mkdir(parents=True)
    (root / 'pubspec.yaml').write_text(f'''name: cli_fixture
publish_to: none
environment:
  sdk: ">=3.13.0 <4.0.0"
dev_dependencies:
  build_runner_accelerator:
    path: {REPO}
''')
    (root / 'build.yaml').write_text('''builders:
  copy:
    import: 'package:cli_fixture/builder.dart'
    builder_factories: [copy]
    build_extensions: {'.txt': ['.copy']}
    auto_apply: root_package
    build_to: source
  final:
    import: 'package:cli_fixture/builder.dart'
    builder_factories: [finish]
    build_extensions: {'.copy': ['.final']}
    auto_apply: root_package
    build_to: source
    required_inputs: ['.copy']
''')
    (root / 'lib/builder.dart').write_text('''import 'package:build/build.dart';
Builder copy(BuilderOptions options) => Copier('.txt', '.copy');
Builder finish(BuilderOptions options) => Copier('.copy', '.final');
class Copier implements Builder {
  Copier(this.from, this.to);
  final String from, to;
  Map<String, List<String>> get buildExtensions => {from: [to]};
  Future<void> build(BuildStep step) async {
    final text = await step.readAsString(step.inputId);
    if (text.trim() == 'empty') return;
    await step.writeAsString(step.allowedOutputs.single, text + to + '\\n');
  }
}
''')
    for name in ('a', 'b', 'empty'):
        (root / f'lib/{name}.txt').write_text(name + '\n')
        for ext in ('copy', 'final'):
            (root / f'lib/{name}.{ext}').write_text('conflict\n')
    run([DART, '--suppress-analytics', 'pub', 'get', '--offline'], root)


def launcher(root, mode, command='build', flags=()):
    return [*LAUNCHER, command, f'--mode={mode}', '--dart', DART,
            '--root', str(root), '--jobs=1', *flags]


def descendants(pid):
    children = {}
    for entry in Path('/proc').glob('[0-9]*/stat'):
        try:
            fields = entry.read_text().rsplit(')', 1)[1].split()
            if fields[0] != 'Z':
                children.setdefault(int(fields[1]), []).append(int(entry.parent.name))
        except (OSError, ValueError, IndexError):
            continue
    found, pending = set(), [pid]
    while pending:
        for child in children.get(pending.pop(), []):
            if child not in found:
                found.add(child)
                pending.append(child)
    return found


def live(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False


def watch(args, root, reference, env=ENV, compiler_marker=None,
          stop_signal=signal.SIGINT, edit=None):
    log = root / 'watch.log'
    with log.open('w') as stream:
        proc = subprocess.Popen(args, cwd=root, env=env, stdout=stream, stderr=stream,
                                start_new_session=True)
        children = set()
        try:
            deadline = time.monotonic() + 90
            while (not (root / 'lib/a.final').exists() or files(root) != reference or
                   not any(marker in log.read_text() for marker in
                           ('Watching ', 'Built with build_runner'))):
                assert proc.poll() is None, log.read_text()
                assert time.monotonic() < deadline, f'{log.read_text()}\nexpected={reference!r}\nactual={files(root)!r}'
                time.sleep(.1)
            if compiler_marker is not None:
                while not compiler_marker.exists():
                    assert proc.poll() is None, log.read_text()
                    assert time.monotonic() < deadline, log.read_text()
                    time.sleep(.1)
            completion_markers = ('Build completed (Rust frontend)', 'Built with build_runner')
            completed = sum(log.read_text().count(marker) for marker in completion_markers)
            # Every invocation edits after watch is ready, with distinct bytes.
            edit = edit or ('watch background edit' if compiler_marker else f'watch edit {stop_signal.name}')
            (root / 'lib/a.txt').write_text(edit + '\n')
            deadline = time.monotonic() + 90
            while ((root / 'lib/a.final').read_text() != edit + '\n.copy\n.final\n' or
                   sum(log.read_text().count(marker) for marker in completion_markers) <= completed):
                assert proc.poll() is None, log.read_text()
                assert time.monotonic() < deadline, log.read_text()
                time.sleep(.1)
            # Interrupt/hang up the parent only, not its terminal process group.
            children = descendants(proc.pid)
            proc.send_signal(stop_signal)
            assert proc.wait(timeout=15) == 128 + stop_signal, log.read_text()
            # The supervisor owns another group. Check all descendants have gone.
            deadline = time.monotonic() + 5
            while any(live(pid) for pid in children):
                assert time.monotonic() < deadline, f'live watch descendants remain: {children}'
                time.sleep(.1)
            return files(root)
        finally:
            if proc.poll() is None:
                children |= descendants(proc.pid)
                proc.send_signal(signal.SIGINT)
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    # Failure cleanup must also reach the native supervisor's
                    # separate group, even when the assertion failed early.
                    for pid in children:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
            # A hangup regression may exit the parent before its children. Keep
            # failed probes from leaving those already-observed orphans running.
            for pid in children:
                if live(pid):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


def main():
    with tempfile.TemporaryDirectory(prefix='accelerator-cli-') as temp:
        base = Path(temp)
        stock, native = base / 'stock', base / 'native'
        for root in (stock, native):
            prepare(root)
        run(launcher(native, 'rust', 'prewarm', ['--force-aot']), native)
        assert not (native / '.dart_tool/build_runner_accelerator/graph-v3.bin').exists()
        # The obsolete -d/long flag must have exactly the same output effect as
        # omission, including conflicts whose builder emits no output.
        for case_index, flags in enumerate(((), ('-d',), ('--delete-conflicting-outputs',))):
            for root in (stock, native):
                (root / '.dart_tool/build/asset_graph.json').unlink(missing_ok=True)
                (root / '.dart_tool/build_runner_accelerator/graph-v3.bin').unlink(missing_ok=True)
                for name in ('a', 'b', 'empty'):
                    for ext in ('copy', 'final'):
                        (root / f'lib/{name}.{ext}').write_text('conflict\n')
            run([DART, '--suppress-analytics', 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
            run(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
            assert files(stock) == files(native)
            assert not (native / 'lib/empty.copy').exists()
            for root in (stock, native):
                (root / 'lib/a.txt').write_text(f'edited {case_index}\n')
            run([DART, '--suppress-analytics', 'run', 'build_runner', 'build', '--force-jit', *flags], stock)
            run(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
            assert files(stock) == files(native)
            run(launcher(native, 'rust', flags=['--force-jit', *flags]), native)
            assert files(stock) == files(native)
        print('cli-compatibility: conflict flags/no-op/incremental/dependency chain passed', flush=True)
        # build-filter must select stock before even trying the invalid binary.
        fallback = base / 'fallback'
        prepare(fallback)
        bad_native = {**ENV, 'BUILD_RUNNER_ACCELERATOR_BIN': '/bin/false'}
        args = launcher(fallback, 'auto', flags=['--force-jit', '--build-filter=lib/a.final'])
        run(args, fallback, env=bad_native)
        assert not (fallback / '.dart_tool/build_runner_accelerator').exists()
        assert (fallback / 'lib/a.final').read_bytes() == (stock / 'lib/b.final').read_bytes().replace(b'b\n', b'a\n')
        run(launcher(fallback, 'rust', flags=['--build-filter=lib/a.final']), fallback, expected=1)
        # clean/unknown arguments/help/invalid stock values and separator status
        # agree with direct stock, and never resolve the invalid native binary.
        for command, flags in [('clean', []), ('build', ['--help']), ('build', ['--version']),
                               ('build', ['--unknown']), ('build', ['--no-delete-conflicting-outputs']),
                               ('build', ['--delete-conflicting-outputs=true']), ('build', ['--build-filter']),
                               ('build', ['--', '--jobs', '2'])]:
            result = subprocess.run([DART, '--suppress-analytics', 'run', 'build_runner', command, *flags], cwd=stock,
                                    env=ENV, capture_output=True, timeout=180)
            run(launcher(fallback, 'auto', command, flags), fallback,
                expected=result.returncode, env=bad_native)
        print('cli-compatibility: early stock routing/status passed', flush=True)
        # Manifest-time fallback still carries stock flags and the exact status.
        empty = base / 'empty'
        empty.mkdir()
        capture = base / 'captured.json'
        fake_dart = base / 'fake-dart'
        fake_dart.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                            f'open({str(capture)!r}, "w").write(json.dumps(sys.argv[1:]))\n'
                            'sys.exit(23)\n')
        fake_dart.chmod(0o755)
        # Workspace load uses a resolved package graph; generator failure then
        # conservatively falls back (the fake Dart never writes a manifest).
        shutil.copytree(native / '.dart_tool', empty / '.dart_tool')
        shutil.copy(native / 'pubspec.yaml', empty / 'pubspec.yaml')
        for command in ('build', 'watch'):
            run([*LAUNCHER, command, '--root', str(empty), '--dart', str(fake_dart), '--force-jit', '-d'],
                empty, expected=23)
            assert json.loads(capture.read_text()) == ['--suppress-analytics', 'run', 'build_runner', command, '--force-jit', '-d']
            output = run([str(NATIVE), command, '--mode=rust', '--root', str(empty), '--dart', str(fake_dart)], empty, expected=1)
            assert 'Watching' not in output
        notice = run([str(NATIVE), 'prewarm', '--mode=dart', '--root', str(base / 'missing')], base)
        assert 'nothing to prewarm' in notice
        # The same session/exec path works in an AOT launcher, with no runtime
        # SDK lookup for the wrapper and no changes to the selected stock argv.
        compiled_launcher = base / 'launcher'
        run([DART, '--suppress-analytics', 'compile', 'exe',
             str(REPO / 'bin/build_runner_accelerator.dart'), '-o', str(compiled_launcher)], REPO)
        aot_root = base / 'aot-root'
        aot_root.mkdir()
        run([str(compiled_launcher), 'build', '--mode=dart', '--dart', str(fake_dart),
             '--root', str(aot_root), '--force-jit', '-d'], aot_root, expected=23)
        assert not (aot_root / '.dart_tool').exists()
        assert json.loads(capture.read_text()) == ['run', 'build_runner', 'build', '--force-jit', '-d']
        # Direct native CLI routes stock without loading a workspace at all.
        for command, arguments in [('clean', []), ('build', ['--unknown']),
                                   ('build', ['--', '--mode', 'rust'])]:
            run([str(NATIVE), command, '--dart', str(fake_dart), '--root', str(base),
                 *arguments], base, expected=23)
            assert json.loads(capture.read_text()) == ['--suppress-analytics', 'run', 'build_runner', command, *arguments]
        assert not (base / '.dart_tool').exists()
        print('cli-compatibility: manifest/direct-native fallback arguments and status passed', flush=True)
        # Native watch and early CLI fallback watch both stop on launcher Ctrl-C.
        reference = files(native)
        assert watch(launcher(native, 'rust', 'watch', ['--force-jit', '-d']), native, reference)
        assert watch(launcher(stock, 'auto', 'watch', ['--force-jit', '--verbose-durations']),
                     stock, reference) == files(native)
        # Terminal/SSH hangup must reach both isolated subprocess topologies.
        reference = files(native)
        assert watch(launcher(native, 'rust', 'watch', ['--force-jit']), native,
                     reference, stop_signal=signal.SIGHUP)
        assert watch(launcher(stock, 'auto', 'watch', ['--force-jit', '--verbose-durations']),
                     stock, reference, stop_signal=signal.SIGHUP) == files(native)
        assert watch([str(NATIVE), 'watch', '--mode=rust', '--root', str(native),
                      '--dart', DART, '--jobs=1', '--force-jit'], native, files(native),
                     stop_signal=signal.SIGHUP, edit='direct native hangup edit')
        print('cli-compatibility: SIGHUP cleanup/status passed for native/stock/direct-native', flush=True)
        # A real internal prewarm helper starts a deliberately stalled compiler
        # with its own child. All three must die when only the launcher gets SIGINT.
        compiler_marker = base / 'compiler-started'
        sdk_probe = base / 'sdk.dart'
        sdk_probe.write_text("import 'dart:io'; void main() => stdout.write(File(Platform.resolvedExecutable).parent.parent.path);")
        sdk_root = Path(run([DART, str(sdk_probe)], REPO))
        shim_sdk = base / 'shim-sdk'
        (shim_sdk / 'bin').mkdir(parents=True)
        for entry in sdk_root.iterdir():
            if entry.name != 'bin':
                (shim_sdk / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        for entry in (sdk_root / 'bin').iterdir():
            if entry.name != 'dart':
                (shim_sdk / 'bin' / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        compiler = shim_sdk / 'bin/dart'
        compiler.write_text('#!/usr/bin/env python3\nimport os,subprocess,sys,time\n'
                            'if "compile" in sys.argv and "exe" in sys.argv:\n'
                            f'    open({str(compiler_marker)!r}, "w").write(str(os.getpid()))\n'
                            '    subprocess.Popen([sys.executable, "-c", "import time;time.sleep(180)"])\n'
                            '    time.sleep(180)\n'
                            f'else: os.execv({DART!r}, [{DART!r}, *sys.argv[1:]])\n')
        compiler.chmod(0o755)
        shutil.rmtree(native / '.dart_tool/build_runner_accelerator/aot-sdk', ignore_errors=True)
        background_env = {**ENV, 'BUILD_RUNNER_ACCELERATOR_CACHE': str(base / 'background-cache'),
                          'BUILD_RUNNER_ACCELERATOR_WORKER_AOT': 'background',
                          'BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM': '0',
                          'BUILD_RUNNER_ACCELERATOR_SDK_SUMMARY_PREWARM': '0'}
        assert watch([*LAUNCHER, 'watch', '--mode=rust', '--root', str(native),
                      '--dart', str(compiler), '--jobs=1'], native, files(native),
                     env=background_env, compiler_marker=compiler_marker)
    print('cli-compatibility: PASS conflicts/no-op/incremental/dependencies/filter/fallback/status/watch/Ctrl-C/SIGHUP')


if __name__ == '__main__':
    main()
