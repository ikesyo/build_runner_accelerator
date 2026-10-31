/// Public launcher help. Informational requests never invoke the native frontend.
String launcherHelpFor(String? command) {
  if (command == null) return _overview;
  final buffer = StringBuffer()
    ..writeln(_descriptions[command])
    ..writeln()
    ..writeln('Usage: build_runner_accelerator $command [options]')
    ..writeln()
    ..writeln('Global options:')
    ..write(_globalOptions)
    ..writeln()
    ..writeln('Command options:')
    ..write(_workerOptions);
  if (command == 'build' || command == 'watch') {
    buffer.write(_buildOptions);
  }
  switch (command) {
    case 'build':
      buffer.write(
        '''  --only-check           Report I/M/U differences; exit 1 if outputs differ
  --keep-modified-outputs Retain modified outputs until the producer reruns
  --workspace            Build all Pub workspace packages (supported subset)

Output policies are mutually exclusive and support normal-builder demand only.
Workspace builds exclude filters, output policies, named configs and --define;
optional, shared-part and trigger-only builders are unsupported in workspaces.
''',
      );
    case 'watch':
      buffer.write(
        '''  --interval-ms N        Debounce interval (positive integer)

Topology changes and watch after retained output history are unsupported.
''',
      );
    case 'prewarm':
      buffer.write(
        '''  --background           Prepare caches in a detached process

Prepares caches without running builders. Build filters, output policies and
workspace builds are unsupported.
''',
      );
  }
  buffer.write('''
Unsupported requests fail; stock build_runner is never started.
Configuration and compatibility limits:
https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/launcher-and-release.md
State recovery and migration:
https://github.com/ikesyo/build_runner_accelerator/blob/main/docs/compatibility-cleanup.md#safe-recovery
''');
  return buffer.toString();
}

const _descriptions = {
  'build':
      'Builds the current package with the native frontend and a Dart worker.',
  'watch': 'Continuously builds the current package.',
  'prewarm': 'Prepares worker and analysis caches without running builders.',
};

const _globalOptions = '''  -h, --help             Print this usage information
  --version              Print the accelerator version
  --root PATH            Workspace directory
  --dart PATH            Dart SDK executable used by the worker
''';

const _workerOptions =
    '''  --jobs N               Worker count (positive integer)
  --force-aot            Force the AOT worker
  --force-jit            Force the non-AOT worker
  -r, --[no-]release     Select builder release settings
  -c, --config NAME      Select build.<name>.yaml
  --define BUILDER=OPTION=VALUE
                         Override a builder option
  --enable-experiment NAME
                         Enable Dart experiments; repeat or comma-separate
''';

const _buildOptions =
    '''  --build-filter PATTERN Select outputs; repeat or comma-separate
  -d, --delete-conflicting-outputs
                         Accepted retired stock flags; no effect
''';

const _overview =
    '''A Rust-accelerated frontend for build_runner.

Usage: build_runner_accelerator <command> [options]

Global options:
$_globalOptions
Available commands:
  build          Builds the current package (default when omitted)
  watch          Continuously builds the current package
  prewarm        Prepares worker and analysis caches
  help           Prints help for the accelerator or a command

Run "build_runner_accelerator help <command>" for more information about a command.

Unsupported requests fail; stock build_runner is never started.
Run dart run build_runner directly for stock-only features such as clean,
serve, run, test, stop, --output and logging options.
''';
