import 'package:build/build.dart';

Builder overlayProbe(BuilderOptions options) => _OverlayProbe();
PostProcessBuilder probePost(BuilderOptions options) => _ProbePost();

class _OverlayProbe implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.g.dart': ['.probe'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final generated = await step.readAsString(step.inputId);
    final shared = await step.readAsString(
      AssetId(step.inputId.package, 'lib/shared_0_io.dart'),
    );
    await step.writeAsString(
      step.allowedOutputs.single,
      '${generated.length}:${shared.length}\n',
    );
  }
}

class _ProbePost implements PostProcessBuilder {
  @override
  Iterable<String> get inputExtensions => const ['.probe'];

  @override
  Future<void> build(PostProcessBuildStep step) async {
    final generated = await step.readInputAsString();
    await step.writeAsString(
      AssetId(step.inputId.package, '${step.inputId.path}.post'),
      'post:$generated',
    );
  }
}
