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

Future<void> _waitAfterCommonRead(AssetId input) async {
  if (input.path != 'lib/a.mid') return;
  final armPath = Platform.environment['BUILD_FILTER_READ_BARRIER_ARM'];
  final reachedPath = Platform.environment['BUILD_FILTER_READ_BARRIER_REACHED'];
  final releasePath = Platform.environment['BUILD_FILTER_READ_BARRIER_RELEASE'];
  if (armPath == null || reachedPath == null || releasePath == null) return;
  if (!File(armPath).existsSync()) return;

  File(reachedPath).writeAsStringSync('common.side read completed\n');
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!File(releasePath).existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for filtered watch read barrier');
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

Future<void> _waitAfterExternalRead(AssetId input, String contents) async {
  if (input.path != 'lib/a.mid' && input.path != 'lib/b.mid') return;
  final armPath = Platform.environment['BUILD_FILTER_EXTERNAL_READ_ARM'];
  final reachedPath =
      Platform.environment['BUILD_FILTER_EXTERNAL_READ_REACHED'];
  final releasePath =
      Platform.environment['BUILD_FILTER_EXTERNAL_READ_RELEASE'];
  if (armPath == null || reachedPath == null || releasePath == null) return;
  if (!File(armPath).existsSync()) return;

  // Track cycle state per input so an edit cannot misclassify its first read.
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

Builder seed(BuilderOptions options) => Recorder('.txt', ['.mid', '.side']);
Builder finish(BuilderOptions options) => Recorder(
  '.mid',
  ['.final'],
  glob: options.config['glob'] == true || options.config['glob_names'] == true,
  globNames: options.config['glob_names'] == true,
  orphan: options.config['orphan'] == true,
  conditionalGlob: options.config['conditional_glob'] == true,
  catchCanReadError: options.config['catch_can_read_error'] == true,
  catchReadError: options.config['catch_read_error'] == true,
);
Builder seedGlob(BuilderOptions options) =>
    Recorder('.txt', ['.mid', '.side'], glob: true, globNames: true);
Builder noise(BuilderOptions options) => Recorder('.noise', ['.ignored']);
Builder zero(BuilderOptions options) => Recorder('.txt', []);
Builder constant(BuilderOptions options) =>
    Recorder('.txt', ['.mid', '.side'], readInput: false);

class Recorder implements Builder {
  Recorder(
    this.input,
    this.outputs, {
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
  final String input;
  final List<String> outputs;
  Map<String, List<String>> get buildExtensions => {input: outputs};
  Future<void> build(BuildStep step) async {
    _recordHistory('${step.inputId.package}|${step.inputId.path}');
    var text = readInput ? await step.readAsString(step.inputId) : 'constant\n';
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
        await _waitAfterExternalRead(step.inputId, externalContents);
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
    _recordHistory('${step.inputId.package}|${step.inputId.path}');
    await step.readAsString(step.inputId);
    await step.writeAsString(
      step.allowedOutputs.single,
      step.inputId.path.endsWith('shared.src')
          ? "export 'transitive.dart';\n"
          : "import 'shared.dart';\nclass Generated extends Shared {}\n",
    );
  }
}

class Resolve implements Builder {
  Map<String, List<String>> get buildExtensions => {
    '.dart': ['.final'],
  };
  Future<void> build(BuildStep step) async {
    _recordHistory('${step.inputId.package}|${step.inputId.path}');
    await step.resolver.libraryFor(step.inputId);
    await step.writeAsString(step.allowedOutputs.single, 'resolved\n');
  }
}
