#!/usr/bin/env python3
"""Check experimental compiler copies, mode transitions and fail-closed CLI use."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname

FLAG = 'BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def outputs(root):
    return {str(p.relative_to(root)): digest(p)
            for p in sorted((root / 'lib').glob('*.g.dart'))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path)
    parser.add_argument('--worker-mode', choices=['jit', 'aot'], default='jit')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    results = (args.results.resolve() if args.results else
               Path(tempfile.mkdtemp(prefix='compile-isolation-correctness-')))
    results.mkdir(parents=True, exist_ok=True)
    local_dart = repo / '.toolchains/dart/dart-sdk/bin/dart'
    dart = os.environ.get('DART_BIN') or (str(local_dart) if local_dart.is_file()
                                          else shutil.which('dart'))
    require(dart, 'Dart SDK not found; set DART_BIN')
    native = os.environ.get('BUILD_RUNNER_ACCELERATOR_BIN',
                            str(repo / 'rust/target/release/build_runner_accelerator'))
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('BUILD_RUNNER_ACCELERATOR_')}
    env.update(PUB_CACHE=os.environ.get('PUB_CACHE', str(repo / '.pub-cache')),
               BUILD_RUNNER_ACCELERATOR_BIN=native,
               BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1' if args.worker_mode == 'aot' else '0',
               BUILD_RUNNER_ACCELERATOR_CACHE=str(results / 'cache'))

    def run(root, label, command, enabled=False, success=True):
        current = dict(env)
        if enabled:
            current[FLAG] = '1'
        with (results / f'{label}.log').open('w') as log:
            result = subprocess.run(command, cwd=root, env=current, stdout=log,
                                    stderr=log, timeout=300, check=False)
        require((result.returncode == 0) == success,
                f'{label}: unexpected status {result.returncode}; results={results}')

    fixture = repo / 'fixtures/json_serializable_10_app'
    for lane in ['stock', 'native']:
        root = results / lane
        root.mkdir()
        shutil.copytree(fixture / 'lib', root / 'lib')
        for p in (root / 'lib').glob('*.g.dart'):
            p.unlink()
        for name in ['pubspec.yaml', 'pubspec.lock']:
            (root / name).write_text((fixture / name).read_text().replace('../..', str(repo)))
        command = [dart, '--suppress-analytics', 'pub', 'get', '--enforce-lockfile']
        if os.environ.get('PUB_GET_OFFLINE', '1') == '1':
            command.append('--offline')
        run(root, lane + '-pub', command)
    stock, target = results / 'stock', results / 'native'
    state = target / '.dart_tool/build_runner_accelerator'
    original_config = target / '.dart_tool/package_config.json'
    original_hash = digest(original_config)
    config = json.loads(original_config.read_text())
    original_sources = {}
    for entry in config['packages']:
        if entry['name'] not in ['analyzer', 'dart_style', 'build_runner', 'build_runner_accelerator']:
            continue
        package = Path(url2pathname(urlparse(urljoin(original_config.as_uri(), entry['rootUri'])).path))
        for p in (package / 'lib').rglob('*.dart'):
            original_sources[p] = digest(p)
    stock_command = [dart, '--suppress-analytics', 'run', 'build_runner', 'build']
    command = [dart, '--suppress-analytics', 'run', 'build_runner_accelerator',
               'build', '--jobs', '2', '--dart', dart]

    def compare(label, enabled):
        run(stock, label + '-stock', stock_command)
        run(target, label + '-native', command, enabled)
        require(outputs(stock) and outputs(stock) == outputs(target), label + ': outputs differ')
        require(digest(original_config) == original_hash, 'Original configuration was changed')
        print(f'compile-isolation: {label}: stock/native=yes', flush=True)

    compare('initial-off', False)
    initial_manifest = json.loads((state / 'builder-manifest.json').read_text())['fingerprint']
    for root in [stock, target]:
        p = sorted((root / 'lib').glob('model_*.dart'))[0]
        p.write_text(p.read_text().replace('String value', 'String title').replace('this.value', 'this.title'))
    compare('one-file-on', True)
    selected = state / 'compile-isolation-package_config.json'
    require('buildRunnerAcceleratorCompileIsolation' in json.loads(selected.read_text()),
            'Experimental configuration not selected')
    require(initial_manifest != json.loads((state / 'builder-manifest.json').read_text())['fingerprint'],
            'Mode switch did not invalidate the manifest')
    run(target, 'noop-on', command, True)
    require(outputs(stock) == outputs(target), 'No-op changed outputs')
    stamp = state / 'dynamic_worker.dill.config'
    on_stamp = stamp.read_bytes() if args.worker_mode == 'jit' else None
    for root in [stock, target]:
        for p in (root / 'lib').glob('model_*.dart'):
            p.write_text(p.read_text().replace('int id', 'int key').replace('this.id', 'this.key'))
    compare('broad-on', True)
    graph = state / 'graph-v3.bin'
    graph_before, output_before = digest(graph), outputs(target)
    first = sorted((target / 'lib').glob('model_*.dart'))[0]
    valid = first.read_text()
    # Keep the part directive so the normal prefilter still runs the builder.
    # Function fields are valid Dart but unsupported by json_serializable.
    require('String title' in valid, 'Failure fixture field not found')
    first.write_text(valid.replace('String title', 'Function title'))
    run(target, 'failure-on', command, True, success=False)
    require(digest(graph) == graph_before and outputs(target) == output_before,
            'Failure published graph/outputs')
    first.write_text(valid)
    for root in [stock, target]:
        p = sorted((root / 'lib').glob('model_*.dart'))[0]
        p.write_text(p.read_text().replace('String title', 'String label').replace('this.title', 'this.label'))
    compare('recovery-off', False)
    require(not (state / 'runner-package_config.json').exists(),
            'Turning isolation off selected a copied modern runner')
    require(selected.exists(), 'Experimental setup snapshot was unexpectedly removed')
    if on_stamp is not None:
        require(stamp.read_bytes() != on_stamp, 'Kernel reused an incompatible compiler config')

    # A builder cannot catch the unsupported stock entrypoint and publish success.
    graph_before, output_before = digest(graph), outputs(target)
    (target / 'lib/cli_probe.dart').write_text('''
import 'package:build/build.dart';
import 'package:build_runner/src/bootstrap/processes.dart';
import 'package:build_runner/src/build_plan/builder_factories.dart';
Builder cliProbe(BuilderOptions options) => Probe();
class Probe implements Builder {
  Map<String, List<String>> get buildExtensions => {'.txt': ['.out']};
  Future<void> build(BuildStep step) async {
    try { await ChildProcess.run([], BuilderFactories({})); }
    catch (_) { await step.writeAsString(step.allowedOutputs.single, 'caught'); }
  }
}
''')
    (target / 'lib/trigger.txt').write_text('trigger')
    (target / 'build.yaml').write_text('''
builders:
  cli_probe:
    import: "package:json_serializable_10_app/cli_probe.dart"
    builder_factories: ["cliProbe"]
    build_extensions: {".txt": [".out"]}
    auto_apply: root_package
    build_to: source
''')
    run(target, 'unsupported-cli-on', command, True, success=False)
    log = (results / 'unsupported-cli-on.log').read_text()
    require('Experimental compile isolation does not support ChildProcess.run' in log,
            'Unsupported CLI did not reach the fail-closed guard')
    require(not (target / 'lib/trigger.out').exists(), 'Builder caught the unsupported CLI call')
    require(digest(graph) == graph_before and outputs(target) == output_before,
            'Unsupported CLI published graph/outputs')
    require(all(digest(p) == value for p, value in original_sources.items()),
            'Original compiler package source was changed')
    print(f'compile-isolation: PASS mode={args.worker_mode} results={results}', flush=True)


if __name__ == '__main__':
    main()
