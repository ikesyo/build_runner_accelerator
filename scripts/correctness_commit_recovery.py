#!/usr/bin/env python3
"""Stock comparison using a test-only native adapter and deterministic kill IPC.

Run cargo test --no-run and cargo build first; pass --test-binary from Cargo's
compiler-artifact message (the executable with profile.test=true).
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--test-binary', type=Path, required=True)
parser.add_argument('--native', type=Path, required=True)
parser.add_argument('--dart', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
env = dict(os.environ, PUB_CACHE=os.environ.get('PUB_CACHE', str(repo / '.pub-cache')),
           BUILD_RUNNER_ACCELERATOR_WORKER_AOT='0')
root = Path(tempfile.mkdtemp(prefix='commit-recovery-'))
print(f'commit-recovery: workspace/logs {root}', flush=True)


def run(command, cwd, label):
    with (root / f'{label}.log').open('w') as log:
        subprocess.run([str(x) for x in command], cwd=cwd, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)


def native(path, label, *extra):
    run([args.native, 'build', '--root', path, '--dart', args.dart, *extra], repo, label)


def generated(path, stock=False):
    result = {str(p.relative_to(path)): p.read_bytes()
              for p in (path / 'lib').rglob('*')
              if p.is_file() and (p.name.endswith('.gen.txt') or p.name.endswith('.post.txt'))}
    cache = path / ('.dart_tool/build/generated' if stock else '.dart_tool/build_runner_accelerator/cache')
    if cache.exists():
        result.update({f'cache/{p.relative_to(cache)}': p.read_bytes()
                       for p in cache.rglob('*.cache')})
    return result


def child(path, point):
    child_env = dict(env, ACCELERATOR_TEST_NATIVE_ARGUMENTS=json.dumps([
        'build', '--root', str(path), '--dart', str(args.dart)]),
        ACCELERATOR_TEST_COMMIT_POINT=point)
    log = (root / f'{path.name}-killed.stderr').open('w')
    process = subprocess.Popen([str(args.test_binary), '--exact',
                               'build::tests::native_commit_process_child', '--nocapture'],
                              cwd=repo, env=child_env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=log, text=True)
    # Pipe handshake, not a sleep or a racing filesystem poll. Fail with a
    # bounded timeout even if a regression never reaches the commit boundary.
    import queue
    import threading
    lines = queue.Queue()
    def read_lines():
        for line in process.stdout:
            lines.put(line.strip())
        lines.put(None)
    threading.Thread(target=read_lines, daemon=True).start()
    try:
        while True:
            line = lines.get(timeout=180)
            if line == 'COMMIT_BOUNDARY_READY':
                break
            if line is None:
                raise AssertionError(f'child exited before {point}; see {log.name}')
    finally:
        process.kill()
        process.wait(timeout=30)
        log.close()


def watch_recovery(path):
    import queue
    import threading
    child_env = dict(env, ACCELERATOR_TEST_NATIVE_ARGUMENTS=json.dumps([
        'watch', '--root', str(path), '--dart', str(args.dart), '--interval-ms', '20']),
        ACCELERATOR_TEST_COMMIT_POINT='after_output')
    process = subprocess.Popen([str(args.test_binary), '--exact',
                               'build::tests::native_commit_process_child', '--nocapture'],
                              cwd=repo, env=child_env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    lines = queue.Queue()
    log = (root / 'watch-recovery.log').open('w')
    def read_lines():
        for line in process.stdout:
            log.write(line)
            log.flush()
            lines.put(line.strip())
        lines.put(None)
    thread = threading.Thread(target=read_lines, daemon=True)
    thread.start()
    def wait_for(text):
        while True:
            line = lines.get(timeout=180)
            if line is None:
                raise AssertionError(f'watch exited before {text}; see {log.name}')
            if text in line:
                return
    try:
        wait_for('Watching ')
        (path / 'lib/input.txt').write_text('updated\n')
        (path / 'lib/removed.txt').unlink()
        wait_for('COMMIT_BOUNDARY_READY')
        process.stdin.write('inject I/O error\n')
        process.stdin.flush()
        wait_for('watch build failed:')
        wait_for('recovering interrupted commit')
        # Same bytes still differ from the restored graph. A fresh source event
        # triggers the next attempt after in-process rollback and resident drop.
        (path / 'lib/input.txt').write_text('updated\n')
        wait_for('Build completed (Rust frontend)')
    finally:
        process.kill()
        process.wait(timeout=30)
        thread.join(timeout=10)
        log.close()


try:
    baseline = root / 'baseline'
    shutil.copytree(repo / 'fixtures/post_process_builder_app', baseline,
                    ignore=shutil.ignore_patterns('.dart_tool', '*.gen.txt', '*.post.txt'))
    pubspec = baseline / 'pubspec.yaml'
    pubspec.write_text(pubspec.read_text().replace('path: ../..', f'path: {repo}'))
    # A cache producer in the same transaction as source and post-process outputs.
    builder = baseline / 'lib/post_process_builder.dart'
    builder.write_text(builder.read_text() + '''
Builder cacheBuilder(BuilderOptions options) => CacheBuilder();
class CacheBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {'.txt': ['.cache']};
  @override
  Future<void> build(BuildStep step) async {
    final value = await step.readAsString(step.inputId);
    await step.writeAsString(AssetId(step.inputId.package,
      step.inputId.path.replaceFirst(RegExp(r'\\.txt$'), '.cache')), value);
  }
}
''')
    config = baseline / 'build.yaml'
    config.write_text(config.read_text().replace('post_process_builders:', '''  cache_builder:
    import: "package:post_process_builder_app/post_process_builder.dart"
    builder_factories: [cacheBuilder]
    build_extensions:
      ".txt": [".cache"]
    auto_apply: none
    build_to: cache

post_process_builders:''').replace('      post_process_builder_app:echo_builder:', '''      post_process_builder_app:cache_builder:
        generate_for: [lib/input.txt, lib/removed.txt]
      post_process_builder_app:echo_builder:'''))
    (baseline / 'lib/removed.txt').write_text('remove me\n')
    (baseline / 'lib/handwritten.dart').write_text('// keep me\n')
    run([args.dart, 'pub', 'get', '--offline'], baseline, 'pub-get')
    native(baseline, 'baseline')
    stock = root / 'stock'
    shutil.copytree(baseline, stock, ignore=shutil.ignore_patterns('.dart_tool', '*.gen.txt', '*.post.txt'))
    run([args.dart, 'pub', 'get', '--offline'], stock, 'stock-pub-get')
    (stock / 'lib/input.txt').write_text('updated\n')
    (stock / 'lib/removed.txt').unlink()
    run([args.dart, 'run', 'build_runner', 'build'], stock, 'stock')
    expected = generated(stock, stock=True)
    for point in ['after_deletions', 'output_temporary_created', 'after_output', 'after_graph', 'graph_io']:
        workspace = root / point
        shutil.copytree(baseline, workspace)
        # Regenerate package_config root URI after copying the workspace.
        run([args.dart, 'pub', 'get', '--offline'], workspace, f'{point}-pub-get')
        (workspace / 'lib/input.txt').write_text('updated\n')
        (workspace / 'lib/removed.txt').unlink()
        graph = workspace / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        if point == 'graph_io':
            blocked = graph.with_suffix('.bin.tmp')
            blocked.mkdir()
            try:
                native(workspace, f'{point}-failed')
                raise AssertionError('graph save unexpectedly succeeded')
            except subprocess.CalledProcessError:
                pass
            blocked.rmdir()
        else:
            child(workspace, point)
        undo = graph.with_suffix('.commit-undo')
        journal = json.loads((undo / 'journal.json').read_text())
        undo_bytes = sum(p.stat().st_size for p in undo.iterdir() if p.is_file())
        print(f'commit-recovery: {point}: undo_entries={len(journal["entries"])} undo_bytes={undo_bytes}', flush=True)
        before_verify = ({str(p.relative_to(workspace)): p.read_bytes()
                          for p in (workspace / 'lib').rglob('*') if p.is_file()}, graph.read_bytes())
        try:
            native(workspace, f'{point}-verify', '--only-check')
            raise AssertionError('verification silently recovered a pending commit')
        except subprocess.CalledProcessError:
            pass
        assert before_verify == ({str(p.relative_to(workspace)): p.read_bytes()
                                  for p in (workspace / 'lib').rglob('*') if p.is_file()}, graph.read_bytes())
        assert (undo / 'journal.json').exists()
        native(workspace, f'{point}-recovered')
        assert generated(workspace) == expected, point
        assert not list((workspace / 'lib').rglob('*.build-runner-accelerator-commit.tmp')), point
        assert (workspace / 'lib/handwritten.dart').read_text() == '// keep me\n'
        assert not graph.with_suffix('.commit-undo').joinpath('journal.json').exists()
        native(workspace, f'{point}-noop')
        assert generated(workspace) == expected, point
        assert not list((workspace / 'lib').rglob('*.build-runner-accelerator-commit.tmp')), point
        assert 'No work to do (Rust frontend)' in (root / f'{point}-noop.log').read_text()
        print(f'commit-recovery: {point}: stock equality, stale deletion, no-op PASS', flush=True)
    workspace = root / 'watch'
    shutil.copytree(baseline, workspace)
    run([args.dart, 'pub', 'get', '--offline'], workspace, 'watch-pub-get')
    watch_recovery(workspace)
    assert generated(workspace) == expected
    native(workspace, 'watch-noop')
    assert 'No work to do (Rust frontend)' in (root / 'watch-noop.log').read_text()
    assert generated(workspace) == expected
    print('commit-recovery: watch I/O failure, resident rollback, retry, stock equality, no-op PASS', flush=True)
except BaseException:
    print(f'commit-recovery: retained failure workspace/logs {root}', flush=True)
    raise
else:
    shutil.rmtree(root)
    print('commit-recovery: PASS', flush=True)
