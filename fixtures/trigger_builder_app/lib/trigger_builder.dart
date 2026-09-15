import 'package:build/build.dart';

Builder triggerBuilder(BuilderOptions options) => _TriggerBuilder(options);
Builder optionalTriggerBuilder(BuilderOptions options) =>
    _OptionalTriggerBuilder(options);
Builder producerBuilder(BuilderOptions options) => _ProducerBuilder();
Builder generatedConsumer(BuilderOptions options) => _GeneratedConsumer();
Builder optionalConsumer(BuilderOptions options) => _OptionalConsumer();

class _TriggerBuilder implements Builder {
  _TriggerBuilder(this._options);

  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.dart': <String>['.triggered.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (_options.config['fail'] == true) {
      throw StateError('trigger builder failure');
    }
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(buildStep.allowedOutputs.single, 'triggered:$input');
  }
}

class _OptionalTriggerBuilder implements Builder {
  _OptionalTriggerBuilder(this._options);

  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.dart': <String>['.optional.triggered.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (_options.config['fail'] == true) {
      throw StateError('optional trigger builder failure');
    }
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'optional:$input',
    );
  }
}

class _ProducerBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/seed.dart': <String>['lib/generated_input.trigger.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final seed = await buildStep.readAsString(buildStep.inputId);
    final seedLine = seed.trim().replaceAll(RegExp(r'\s+'), ' ');
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      "// generated from $seedLine\n"
      "import 'package:trigger_builder_app/trigger_marker.dart';\n"
      '@TriggerMarker()\n'
      'class GeneratedMarker {}\n',
    );
  }
}

class _GeneratedConsumer implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/generated_input.trigger.dart':
        <String>['lib/generated_input.consumer.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'consumer:$input',
    );
  }
}

class _OptionalConsumer implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/optional_input.dart':
        <String>['lib/optional_input.consumer.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final optional = AssetId(
      buildStep.inputId.package,
      'lib/optional_input.optional.triggered.dart',
    );
    final present = await buildStep.canRead(optional);
    final contents = present ? await buildStep.readAsString(optional) : '';
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'optional-present:$present\n$contents',
    );
  }
}
