import 'package:build/build.dart';

Builder emptyInputMapping(BuilderOptions options) => _EmptyInputMappingBuilder(
  fail: options.config['fail'] == true,
);

Builder emptyInputConsumer(BuilderOptions options) =>
    const _EmptyInputConsumerBuilder();

Builder emptyInputCollision(BuilderOptions options) =>
    const _EmptyInputCollisionBuilder();

class _EmptyInputMappingBuilder implements Builder {
  const _EmptyInputMappingBuilder({required this.fail});

  final bool fail;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '': <String>['.empty_mapping.out'],
    '.dart': <String>['.regular.out'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (fail) {
      throw StateError('empty input mapping failure');
    }
    final input = await buildStep.readAsString(buildStep.inputId);
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(
        output,
        'input=${buildStep.inputId.path}\n'
        'output=${output.path}\n'
        'content=${input.trimRight()}\n',
      );
    }
  }
}

class _EmptyInputConsumerBuilder implements Builder {
  const _EmptyInputConsumerBuilder();

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.empty_mapping.out': <String>['.consumed.out'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'consumed=${buildStep.inputId.path}\n${input.trimRight()}\n',
    );
  }
}

class _EmptyInputCollisionBuilder implements Builder {
  const _EmptyInputCollisionBuilder();

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '': <String>['.empty_mapping.out'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'collision\n',
    );
  }
}
