import 'dart:io';
import 'package:build/build.dart';
import 'package:glob/glob.dart';

Builder seed(BuilderOptions options) => Recorder('.txt', ['.mid', '.side']);
Builder finish(BuilderOptions options) => Recorder(
  '.mid',
  ['.final'],
  glob: options.config['glob'] == true || options.config['glob_names'] == true,
  globNames: options.config['glob_names'] == true,
  orphan: options.config['orphan'] == true,
  conditionalGlob: options.config['conditional_glob'] == true,
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
  });
  final bool glob;
  final bool readInput;
  final bool globNames;
  final bool orphan;
  final bool conditionalGlob;
  final String input;
  final List<String> outputs;
  Map<String, List<String>> get buildExtensions => {input: outputs};
  Future<void> build(BuildStep step) async {
    File(
      Platform.environment['BUILD_FILTER_HISTORY'] ?? 'history.log',
    ).writeAsStringSync(
      '${step.inputId.package}|${step.inputId.path}\n',
      mode: FileMode.append,
    );
    var text = readInput ? await step.readAsString(step.inputId) : 'constant\n';
    if (text.contains('\n#')) text = '${text.split('\n#').first}\n';
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
      if (await step.canRead(common)) text += await step.readAsString(common);
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
    File(
      Platform.environment['BUILD_FILTER_HISTORY'] ?? 'history.log',
    ).writeAsStringSync(
      'post:${step.inputId.package}|${step.inputId.path}\n',
      mode: FileMode.append,
    );
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
    File(
      Platform.environment['BUILD_FILTER_HISTORY'] ?? 'history.log',
    ).writeAsStringSync(
      '${step.inputId.package}|${step.inputId.path}\n',
      mode: FileMode.append,
    );
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
    File(
      Platform.environment['BUILD_FILTER_HISTORY'] ?? 'history.log',
    ).writeAsStringSync(
      '${step.inputId.package}|${step.inputId.path}\n',
      mode: FileMode.append,
    );
    await step.resolver.libraryFor(step.inputId);
    await step.writeAsString(step.allowedOutputs.single, 'resolved\n');
  }
}
