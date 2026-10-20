import 'package:build/build.dart';

Builder first(BuilderOptions options) => _Producer('.seed', '.stage', 'first:');
Builder second(BuilderOptions options) =>
    _Producer('.stage', '.ready', 'second:');
Builder consumer(BuilderOptions options) =>
    _Producer('.ready', '.final', 'final:');
PostProcessBuilder cleanup(BuilderOptions options) => _Cleanup();

Builder secondaryConsumer(BuilderOptions options) => _SecondaryConsumer();

class _SecondaryConsumer implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    '.request': ['.final'],
  };
  @override
  Future<void> build(BuildStep step) async {
    final request = await step.readAsString(step.inputId);
    final value = request.trim() == 'demand'
        ? await step.readAsString(step.inputId.changeExtension('.ready'))
        : 'skipped demand\n';
    await step.writeAsString(step.allowedOutputs.single, value);
  }
}

class _Producer implements Builder {
  _Producer(this.input, this.output, this.prefix);
  final String input;
  final String output;
  final String prefix;
  @override
  Map<String, List<String>> get buildExtensions => {
    input: [output],
  };
  @override
  Future<void> build(BuildStep step) async {
    final value = await step.readAsString(step.inputId);
    if (value.contains('FAIL') && prefix == 'second:') {
      throw StateError('optional cleanup failure');
    }
    if (value.contains('OMIT')) return;
    await step.writeAsString(step.allowedOutputs.single, '$prefix$value');
  }
}

class _Cleanup implements PostProcessBuilder {
  @override
  Iterable<String> get inputExtensions => ['.stage', '.ready'];
  @override
  Future<void> build(PostProcessBuildStep step) async {
    final value = await step.readInputAsString();
    await step.writeAsString(
      AssetId(step.inputId.package, '${step.inputId.path}.receipt'),
      value,
    );
    step.deletePrimaryInput();
    if (value.contains('CLEANUP_ERROR') &&
        step.inputId.path.endsWith('.ready')) {
      throw StateError('post-process cleanup failure');
    }
  }
}
