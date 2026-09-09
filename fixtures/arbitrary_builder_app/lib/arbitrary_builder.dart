import 'package:build/build.dart';

Builder echoBuilder(BuilderOptions options) =>
    _EchoBuilder(options.config['suffix'] as String? ?? '');

Builder exactBuilder(BuilderOptions options) => _ExactBuilder();

Builder captureBuilder(BuilderOptions options) => _CaptureBuilder();

class _EchoBuilder implements Builder {
  _EchoBuilder(this._suffix);

  final String _suffix;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.txt': <String>['.gen.txt', '.meta.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    final generated = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.gen.txt'),
    );
    final metadata = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.meta.txt'),
    );
    await buildStep.writeAsString(
      generated,
      input.trimRight() + _suffix + '\n',
    );
    await buildStep.writeAsString(metadata, 'length=${input.length}\n');
  }
}

class _ExactBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/special.txt': <String>['lib/special.generated.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      AssetId(buildStep.inputId.package, 'lib/special.generated.txt'),
      input.trimRight() + ' exact\n',
    );
  }
}

class _CaptureBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/assets/{{dir}}/{{file}}.txt': <String>[
      'lib/generated/{{dir}}/{{file}}.dart',
    ],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      input.trimRight() + ' captured\n',
    );
  }
}
