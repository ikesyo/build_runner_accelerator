import 'package:build/build.dart';

Builder cacheStage(BuilderOptions _) => _Stage('.seed.dart', '.cache.dart');
Builder sourceStage(BuilderOptions _) => _Stage('.cache.dart', '.ready.dart');
PostProcessBuilder finishStage(BuilderOptions _) => _Finish();

class _Stage implements Builder {
  _Stage(this.input, this.output);
  final String input;
  final String output;

  @override
  Map<String, List<String>> get buildExtensions => {
    input: [output],
  };

  @override
  Future<void> build(BuildStep step) async {
    final text = await step.readAsString(step.inputId);
    final library = await step.resolver.libraryFor(step.inputId);
    final name = library.classes.single.name;
    // Same-phase generated outputs remain private, even when stale bytes
    // exist on disk from a previous build.
    if (await step.canRead(step.allowedOutputs.single)) {
      throw StateError('same-phase output became visible');
    }
    if (text.contains('OMIT')) return;
    if (text.contains('FAIL')) throw StateError('injected failure');
    await step.writeAsString(
      step.allowedOutputs.single,
      'class ${name}Next {}\n',
    );
  }
}

class _Finish implements PostProcessBuilder {
  @override
  Iterable<String> get inputExtensions => const ['.ready.dart'];

  @override
  Future<void> build(PostProcessBuildStep step) async {
    final text = await step.readInputAsString();
    await step.writeAsString(
      AssetId(step.inputId.package, '${step.inputId.path}.done'),
      'finished:$text',
    );
  }
}
