import 'package:build/build.dart';

Builder overlayProbe(BuilderOptions options) =>
    _OverlayProbe(options.config['unique'] == true);
PostProcessBuilder probePost(BuilderOptions options) => _ProbePost();

class _OverlayProbe implements Builder {
  _OverlayProbe(this.unique);
  final bool unique;
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.g.dart': ['.probe.dart'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final generated = await step.readAsString(step.inputId);
    final shared = await step.readAsString(
      AssetId(step.inputId.package, 'lib/shared_0_io.dart'),
    );
    final prefix = unique
        ? step.inputId.path.split('/').last.replaceAll('.', '_')
        : '';
    await step.writeAsString(
      step.allowedOutputs.single,
      "import 'shared_0.dart' if (dart.library.io) 'shared_0_io.dart';\n" +
          List.generate(
            2048,
            (n) =>
                'class ${prefix}Probe$n { final int value = ${generated.length + shared.length}; }\n',
          ).join(),
    );
  }
}

class _ProbePost implements PostProcessBuilder {
  @override
  Iterable<String> get inputExtensions => const ['.probe.dart'];

  @override
  Future<void> build(PostProcessBuildStep step) async {
    final generated = await step.readInputAsString();
    await step.writeAsString(
      AssetId(step.inputId.package, '${step.inputId.path}.post'),
      'post:$generated',
    );
  }
}
