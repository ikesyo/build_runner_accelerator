#!/usr/bin/env python3
"""Prepare the isolated CLI/parse dependency experiment; optionally compile once.

This research probe deliberately disables ChildProcess.run in copied sources.
Its executable is not a production worker. Original packages/workspace are read
only. A workspace with an already generated worker and effective runner config
is required; this script neither runs builders nor resolves dependencies.
"""

import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
from urllib.parse import unquote, urljoin, urlparse


TESTED = {
    'analyzer': '14.6.0',
    'build_runner': '2.16.1',
    'dart_style': '3.1.14',
}
PARSE_URI = 'package:analyzer/src/clients/build_resolvers/parse_utilities.dart'
PUBLIC_URI = 'package:analyzer/dart/analysis/utilities.dart'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def replace_once(source, before, after):
    require(source.count(before) == 1, f'Unexpected source shape: {before!r}')
    return source.replace(before, after, 1)


def package_root(config, uri):
    parsed = urlparse(urljoin(config.as_uri(), uri))
    require(parsed.scheme == 'file' and not parsed.netloc,
            f'Expected a local package URI: {uri}')
    return Path(unquote(parsed.path)).resolve()


def source_stats(depfile, workspace):
    """Decode Ninja escapes and count complete .dart paths, not .dart_tool."""
    tokens = shlex.split(depfile.read_text().replace('\\\n', ''))
    paths = {(workspace / token).resolve() for token in tokens
             if token.endswith('.dart')}
    require(all(p.is_file() for p in paths), 'Depfile source is missing')
    return {'files': len(paths), 'bytes': sum(p.stat().st_size for p in paths)}


def prepare(workspace, results, dart):
    require(dart.is_file(), 'Dart executable is missing')
    state = workspace / '.dart_tool/build_runner_accelerator'
    config = state / 'runner-package_config.json'
    if not config.is_file():
        config = workspace / '.dart_tool/package_config.json'
    worker = state / 'dynamic_worker.dart'
    require(worker.is_file(), 'Generate the workspace worker before this probe')
    data = json.loads(config.read_text())
    require('buildRunnerAcceleratorCompileIsolation' not in data,
            'Prepare this research workspace with experimental isolation disabled')
    roots = {p['name']: package_root(config, p['rootUri'])
             for p in data['packages']}
    names = [*TESTED, 'build_runner_accelerator']
    require(all(n in roots for n in names), 'Required package is missing')
    require(not results.is_relative_to(workspace) and
            all(not results.is_relative_to(p) for p in roots.values()),
            'Results must be outside the workspace and original packages')
    for name, expected in TESTED.items():
        spec = (roots[name] / 'pubspec.yaml').read_text()
        require(re.search(rf'^version: {re.escape(expected)}\s*$', spec, re.M),
                f'This bounded probe expects {name} {expected}')
    results.mkdir(parents=True, exist_ok=False)
    copies = {}
    for name in names:
        dest = results / name
        shutil.copytree(roots[name] / 'lib', dest / 'lib')
        for filename in ['pubspec.yaml', 'LICENSE']:
            source = roots[name] / filename
            if source.is_file():
                shutil.copy2(source, dest / filename)
        copies[name] = dest

    patch = []

    def write(path, text):
        old = path.read_text() if path.exists() else ''
        relative = path.relative_to(results).as_posix()
        patch.extend(difflib.unified_diff(
            old.splitlines(True), text.splitlines(True),
            fromfile=f'a/{relative}' if old else '/dev/null',
            tofile=f'b/{relative}'))
        path.write_text(text)

    analyzer = copies['analyzer'] / 'lib'
    utilities = analyzer / 'dart/analysis/utilities.dart'
    source = utilities.read_text()
    marker = '/// Return the result of resolving the file at the given [path].'
    require(source.count(marker) == 1, 'Unexpected Analyzer utility source')
    split = source.index(marker)
    light = source[:split]
    for filename in ['analysis_context.dart', 'analysis_context_collection.dart']:
        light = replace_once(light,
                             f"import 'package:analyzer/dart/analysis/{filename}';\n",
                             '')
    write(analyzer / 'src/clients/build_resolvers/parse_utilities.dart', light)
    header = source[:source.index('/// Return the result of parsing the file')]
    write(utilities, header + f"export '{PARSE_URI}' show parseFile, parseString;\n\n"
          + source[split:])
    barrel = analyzer / 'src/clients/build_resolvers/build_resolvers.dart'
    text = replace_once(barrel.read_text(),
                        "import 'package:analyzer/dart/analysis/analysis_context_collection.dart';\n",
                        '')
    text = replace_once(text, "import 'dart:typed_data';",
                        "/// @docImport 'package:analyzer/dart/analysis/analysis_context_collection.dart';\n"
                        "library;\n\nimport 'dart:typed_data';")
    write(barrel, text)
    consumers = [copies['build_runner_accelerator'] / 'lib/src' / name for name in
                 ['trigger_evaluator.dart', 'worker_analysis_driver_model.dart',
                  'resolver_directives.dart']]
    consumers += [copies['dart_style'] / 'lib/src/dart_formatter.dart',
                  analyzer / 'src/dart/sdk/sdk.dart',
                  copies['build_runner'] / 'lib/src/build/library_cycle_graph/asset_deps_loader.dart',
                  copies['build_runner'] / 'lib/src/build/build.dart']
    for path in consumers:
        write(path, replace_once(path.read_text(), f"'{PUBLIC_URI}'", f"'{PARSE_URI}'"))

    processes = copies['build_runner'] / 'lib/src/bootstrap/processes.dart'
    text = replace_once(processes.read_text(), "import '../build_runner.dart';\n", '')
    start = '    _isRunning = true;'
    end = '  /// Receives the message sent from the parent process.'
    require(text.count(start) == text.count(end) == 1, 'Unexpected ChildProcess source')
    first, last = text.index(start), text.index(end)
    require(first < last, 'Unexpected ChildProcess source ordering')
    write(processes, text[:first] +
          "    throw UnsupportedError('CLI removed for isolated compilation experiment');\n"
          '  }\n\n' + text[last:])
    for entry in data['packages']:
        entry['rootUri'] = (copies.get(entry['name'], roots[entry['name']])).as_uri() + '/'
    combined = results / 'package_config.json'
    combined.write_text(json.dumps(data, indent=2) + '\n')
    (results / 'prototype.patch').write_text(''.join(patch))
    commands = {}
    for lane, packages in [('control', config), ('combined', combined)]:
        commands[lane] = [str(dart), '--suppress-analytics', 'compile', 'exe',
                          f'--packages={packages}', f'--depfile={results / (lane + ".d")}',
                          str(worker), '-o', str(results / lane)]
    metadata = {
        'scope': __doc__, 'workspace': str(workspace), 'tested_packages': TESTED,
        'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest(),
        'config_sha256': hashlib.sha256(config.read_bytes()).hexdigest(),
        'commands': commands,
    }
    (results / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    return commands


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True,
                        help='New directory outside the workspace/packages')
    parser.add_argument('--compile', action='store_true',
                        help='Measure one serial control/combined AOT pair')
    args = parser.parse_args()
    workspace, results, dart = (args.workspace.resolve(), args.results.resolve(),
                                args.dart.resolve())
    commands = prepare(workspace, results, dart)
    if args.compile:
        measure = Path(__file__).with_name('measure_process.py')
        sdk = subprocess.check_output([str(dart), '--version'], text=True).strip()
        summary = {'sdk': sdk, 'lanes': {}}
        for lane, command in commands.items():
            metrics = results / f'{lane}.json'
            subprocess.run([sys.executable, str(measure), '--metrics', str(metrics),
                            '--stdout', str(results / f'{lane}.stdout'),
                            '--stderr', str(results / f'{lane}.stderr'),
                            '--cwd', str(workspace), '--', *command],
                           check=True, timeout=300)
            artifact = results / lane
            summary['lanes'][lane] = {
                'metrics': json.loads(metrics.read_text()),
                'sources': source_stats(results / f'{lane}.d', workspace),
                'executable_bytes': artifact.stat().st_size,
                'executable_sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(),
            }
            (results / 'comparison.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'Isolated prototype and commands: {results}')


if __name__ == '__main__':
    main()
