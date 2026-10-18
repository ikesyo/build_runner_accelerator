import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';

void _recordHistory(String entry) {
  final file = File(
    Platform.environment['BUILD_FILTER_HISTORY'] ?? 'history.log',
  ).openSync(mode: FileMode.append);
  var locked = false;
  try {
    file.lockSync(FileLock.blockingExclusive);
    locked = true;
    file.setPositionSync(file.lengthSync());
    file.writeStringSync('$entry\n');
  } finally {
    try {
      if (locked) file.unlockSync();
    } finally {
      file.closeSync();
    }
  }
}

void _recordActivity(String event, String builder, AssetId input) {
  final path = Platform.environment['BUILD_FILTER_ACTIVITY_LOG'];
  if (path == null || path.isEmpty) return;
  final file = File(path).openSync(mode: FileMode.append);
  var locked = false;
  try {
    file.lockSync(FileLock.blockingExclusive);
    locked = true;
    file.setPositionSync(file.lengthSync());
    file.writeStringSync(
      '${jsonEncode({'event': event, 'builder': builder, 'asset': '${input.package}|${input.path}', 'pid': pid, 'timestamp_us': DateTime.now().microsecondsSinceEpoch})}\n',
    );
  } finally {
    try {
      if (locked) file.unlockSync();
    } finally {
      file.closeSync();
    }
  }
}

Future<void> _instrumentationDelay() async {
  final milliseconds = int.tryParse(
    Platform.environment['BUILD_FILTER_DELAY_MS'] ?? '',
  );
  if (milliseconds != null && milliseconds > 0) {
    await Future<void>.delayed(Duration(milliseconds: milliseconds));
  }
}

Future<void> _waitAfterCommonRead(AssetId input) async {
  if (input.path != 'lib/a.mid') return;
  final armPath = Platform.environment['BUILD_FILTER_READ_BARRIER_ARM'];
  final reachedPath = Platform.environment['BUILD_FILTER_READ_BARRIER_REACHED'];
  final releasePath = Platform.environment['BUILD_FILTER_READ_BARRIER_RELEASE'];
  if (armPath == null || reachedPath == null || releasePath == null) return;
  if (!File(armPath).existsSync()) return;

  File(reachedPath).writeAsStringSync('common.side read completed\n');
  final timeoutSeconds =
      int.tryParse(
        Platform.environment['BUILD_FILTER_READ_BARRIER_TIMEOUT_SECONDS'] ?? '',
      ) ??
      30;
  final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
  while (!File(releasePath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for filtered watch read barrier');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitAtResolverFailureBarrier(AssetId input) async {
  if (input.path != 'lib/two.dart') return;
  final armPath = Platform.environment['BUILD_FILTER_RESOLVER_FAILURE_ARM'];
  final reachedPath =
      Platform.environment['BUILD_FILTER_RESOLVER_FAILURE_REACHED'];
  final releasePath =
      Platform.environment['BUILD_FILTER_RESOLVER_FAILURE_RELEASE'];
  if (armPath == null || reachedPath == null || releasePath == null) return;
  if (!File(armPath).existsSync()) return;

  File(reachedPath).writeAsStringSync('resolver completed before failure\n');
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (!File(releasePath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting at resolver failure barrier');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitBeforeExternalRead(AssetId input) async {
  if (input.path != 'lib/b.mid') return;
  final armPath = Platform.environment['BUILD_FILTER_EXTERNAL_READ_ARM'];
  final allowPath = Platform.environment['BUILD_FILTER_EXTERNAL_READ_B_ALLOW'];
  if (armPath == null || allowPath == null || !File(armPath).existsSync()) {
    return;
  }

  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!File(allowPath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting to read external fixture source');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitAfterExternalRead(AssetId input) async {
  if (input.path != 'lib/a.mid' && input.path != 'lib/b.mid') return;
  final armPath = Platform.environment['BUILD_FILTER_EXTERNAL_READ_ARM'];
  final reachedPath =
      Platform.environment['BUILD_FILTER_EXTERNAL_READ_REACHED'];
  final releasePath =
      Platform.environment['BUILD_FILTER_EXTERNAL_READ_RELEASE'];
  if (armPath == null || reachedPath == null || releasePath == null) return;
  if (!File(armPath).existsSync()) return;

  // Each stock build step runs sequentially. Track cycle state per input so a
  // source version change cannot misclassify its first read as a later cycle.
  final inputMarker = input.path.split('/').last;
  final nextCycle = File('$reachedPath/$inputMarker').existsSync();
  final activeReachedPath = nextCycle
      ? Platform.environment['BUILD_FILTER_EXTERNAL_READ_NEXT_REACHED']
      : reachedPath;
  final activeReleasePath = nextCycle
      ? Platform.environment['BUILD_FILTER_EXTERNAL_READ_NEXT_RELEASE']
      : releasePath;
  if (activeReachedPath == null || activeReleasePath == null) return;
  final reachedDirectory = Directory(activeReachedPath)
    ..createSync(recursive: true);
  File(
    '${reachedDirectory.path}/${input.path.split('/').last}',
  ).writeAsStringSync('external source read completed\n');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!File(activeReleasePath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for filtered external read barrier');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Builder seed(BuilderOptions options) =>
    Recorder('.txt', ['.mid', '.side'], activityName: 'seed');
Builder finish(BuilderOptions options) => Recorder(
  '.mid',
  ['.final'],
  activityName: 'finish',
  glob: options.config['glob'] == true || options.config['glob_names'] == true,
  globNames: options.config['glob_names'] == true,
  orphan: options.config['orphan'] == true,
  conditionalGlob: options.config['conditional_glob'] == true,
  catchCanReadError: options.config['catch_can_read_error'] == true,
  catchReadError: options.config['catch_read_error'] == true,
);
Builder seedGlob(BuilderOptions options) => Recorder(
  '.txt',
  ['.mid', '.side'],
  glob: true,
  globNames: true,
  activityName: 'seedGlob',
);
Builder noise(BuilderOptions options) =>
    Recorder('.noise', ['.ignored'], activityName: 'noise');
Builder zero(BuilderOptions options) => Recorder('.txt', []);
Builder constant(BuilderOptions options) =>
    Recorder('.txt', ['.mid', '.side'], readInput: false);

class Recorder implements Builder {
  Recorder(
    this.input,
    this.outputs, {
    this.activityName = 'recorder',
    this.glob = false,
    this.readInput = true,
    this.globNames = false,
    this.orphan = false,
    this.conditionalGlob = false,
    this.catchCanReadError = false,
    this.catchReadError = false,
  });
  final bool glob;
  final bool readInput;
  final bool globNames;
  final bool orphan;
  final bool conditionalGlob;
  final bool catchCanReadError;
  final bool catchReadError;
  final String activityName;
  final String input;
  final List<String> outputs;
  Map<String, List<String>> get buildExtensions => {input: outputs};
  Future<void> build(BuildStep step) async {
    final historyEntry = '${step.inputId.package}|${step.inputId.path}';
    _recordActivity('start', activityName, step.inputId);
    try {
      await _instrumentationDelay();
      _recordHistory(historyEntry);
      var text = readInput
          ? await step.readAsString(step.inputId)
          : 'constant\n';
      if (text.contains('\n#')) text = '${text.split('\n#').first}\n';
      if (step.inputId.path == 'lib/common.txt' && text.trim() == 'fail') {
        throw StateError('intentional build-filter fixture failure');
      }
      if (text.trim() == 'empty') return;
      if (orphan) {
        final asset = AssetId(step.inputId.package, 'lib/orphan.side');
        text += await step.canRead(asset)
            ? await step.readAsString(asset)
            : 'no orphan\n';
      }
      if (input == '.mid' &&
          !globNames &&
          !step.inputId.path.endsWith('common.mid') &&
          !text.startsWith('no-shared')) {
        final common = AssetId(step.inputId.package, 'lib/common.side');
        if (catchCanReadError) {
          try {
            if (await step.canRead(common))
              text += await step.readAsString(common);
          } catch (_) {
            text += 'caught canRead failure\n';
          }
        } else if (catchReadError) {
          try {
            text += await step.readAsString(common);
          } catch (_) {
            text += 'caught read failure\n';
          }
        } else if (await step.canRead(common)) {
          text += await step.readAsString(common);
          await _waitAfterCommonRead(step.inputId);
        }
      }
      if (input == '.mid' &&
          Platform.environment['BUILD_FILTER_EXTERNAL_READ'] == '1') {
        await _waitBeforeExternalRead(step.inputId);
        final externalAsset = AssetId(
          'build_filter_external',
          'lib/shared.asset',
        );
        if (await step.canRead(externalAsset)) {
          final externalContents = await step.readAsString(externalAsset);
          text += externalContents;
          await _waitAfterExternalRead(step.inputId);
        }
      }
      if (glob || (conditionalGlob && text.startsWith('use-glob'))) {
        final assets = await step.findAssets(Glob('lib/*.side')).toList();
        if (!globNames) assets.sort((a, b) => a.path.compareTo(b.path));
        for (final asset in assets) {
          text += globNames
              ? '${asset.toString()}\n'
              : await step.readAsString(asset);
        }
      }
      for (final output in step.allowedOutputs) {
        await step.writeAsString(output, '$text${output.path}\n');
      }
    } finally {
      _recordActivity('end', activityName, step.inputId);
    }
  }
}

PostProcessBuilder post(BuilderOptions options) => PostRecorder();

class PostRecorder implements PostProcessBuilder {
  Iterable<String> get inputExtensions => ['.final'];
  Future<void> build(PostProcessBuildStep step) async {
    _recordHistory('post:${step.inputId.package}|${step.inputId.path}');
    await step.writeAsString(
      AssetId(step.inputId.package, '${step.inputId.path}.post'),
      await step.readInputAsString(),
    );
  }
}

Builder dartSeed(BuilderOptions options) => DartSeed();
Builder resolve(BuilderOptions options) => Resolve();

class DartSeed implements Builder {
  Map<String, List<String>> get buildExtensions => {
    '.src': ['.dart'],
  };
  Future<void> build(BuildStep step) async {
    _recordActivity('start', 'dartSeed', step.inputId);
    try {
      await _instrumentationDelay();
      _recordHistory('${step.inputId.package}|${step.inputId.path}');
      final source = await step.readAsString(step.inputId);
      final generated = step.inputId.path.endsWith('shared.src')
          ? "export 'transitive.dart';\n"
          : source.contains('import-old')
          ? "import 'old.dart';\nclass Generated extends Old {}\n"
          : source.contains('import-new')
          ? "import 'new.dart';\nclass Generated extends New {}\n"
          : "import 'shared.dart';\nclass Generated extends Shared {}\n";
      // These markers vary only the two roots used by the failed-watch fixture.
      // Keep ordinary generated bytes independent of source edits so unrelated
      // resolver reuse cases continue to exercise the same action graph.
      final sourceMarker = source.contains('fail-after-resolver')
          ? '// fail-after-resolver\n'
          : source.contains('recovery-two')
          ? '// recovery-two\n'
          : '';
      await step.writeAsString(
        step.allowedOutputs.single,
        '$generated$sourceMarker',
      );
    } finally {
      _recordActivity('end', 'dartSeed', step.inputId);
    }
  }
}

class Resolve implements Builder {
  Map<String, List<String>> get buildExtensions => {
    '.dart': ['.final'],
  };
  Future<void> build(BuildStep step) async {
    _recordActivity('start', 'resolve', step.inputId);
    try {
      await _instrumentationDelay();
      _recordHistory('${step.inputId.package}|${step.inputId.path}');
      final source = await step.readAsString(step.inputId);
      final library = await step.resolver.libraryFor(step.inputId);
      if (source.contains('fail-after-resolver')) {
        await _waitAtResolverFailureBarrier(step.inputId);
        throw StateError('intentional resolver fixture failure');
      }
      final generated = library.getClass('Generated');
      final dependencyClass = generated?.supertype?.element;
      final members =
          generated?.interfaceMembers.keys.map((name) => name.name).toList() ??
          <String>[];
      members.sort();
      final summary = <String>[
        generated?.name ?? 'no-generated-class',
        dependencyClass?.name ?? 'missing-supertype',
        '${dependencyClass?.getters.length ?? 0}',
      ].join(':');
      await step.writeAsString(
        step.allowedOutputs.single,
        'resolved:$summary:${members.join(',')}\n',
      );
    } finally {
      _recordActivity('end', 'resolve', step.inputId);
    }
  }
}

Builder nestedView(BuilderOptions options) => NestedView();
Builder nestedPrivateSeed(BuilderOptions options) => NestedPrivateSeed();

Future<String> _probeRead(BuildStep step, AssetId asset) async {
  final readable = await step.canRead(asset);
  String content;
  try {
    content = await step.readAsString(asset);
  } on InvalidInputException {
    content = '<invalid>';
  } on AssetNotFoundException {
    content = '<missing>';
  }
  return '$asset:$readable:$content';
}

class NestedPrivateSeed implements Builder {
  Map<String, List<String>> get buildExtensions => {
    '^lib/{{}}.txt': ['lib/{{}}.post', 'test/{{}}.post'],
  };

  Future<void> build(BuildStep step) async {
    _recordHistory('private_seed|${step.inputId}');
    final text = await step.readAsString(step.inputId);
    if (text.trim() == 'empty') return;
    final privateOutput = step.allowedOutputs.firstWhere(
      (id) => id.path.startsWith('test/'),
    );
    final probe = await _probeRead(step, privateOutput);
    for (final output in step.allowedOutputs) {
      await step.writeAsString(output, '$text$probe\n${output.path}\n');
    }
  }
}

class NestedView implements Builder {
  Map<String, List<String>> get buildExtensions => {
    '.probe': ['.final'],
  };

  Future<void> build(BuildStep step) async {
    _recordHistory('${step.inputId.package}|${step.inputId.path}');
    final lines = (await step.readAsString(step.inputId)).trim().split('\n');
    final name = lines.first;
    final assets = await step.findAssets(Glob('**/*.txt')).toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    final result = <String>[for (final asset in assets) asset.toString()];
    for (final asset in [
      AssetId('build_filter_app', 'dep/lib/$name.txt'),
      AssetId('filter_dep', 'lib/$name.txt'),
      AssetId('filter_dep', 'test/$name.txt'),
      AssetId('filter_dep', 'test/published/$name.txt'),
      if (lines.contains('private-outputs'))
        ...await step.findAssets(Glob('test/*.post')).toList(),
    ]) {
      result.add(await _probeRead(step, asset));
    }
    await step.writeAsString(step.allowedOutputs.single, result.join('\n'));
  }
}
