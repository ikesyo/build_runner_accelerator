import 'package:build/build.dart';

Builder multiMappingBuilder(BuilderOptions options) => _MultiMappingBuilder(
  options.config['suffix'] as String? ?? '.multi',
);

class _MultiMappingBuilder implements Builder {
  _MultiMappingBuilder(this._suffix);

  final String _suffix;

  @override
  Map<String, List<String>> get buildExtensions => <String, List<String>>{
    '.txt': <String>[_suffix],
    '^lib/special.txt': <String>['lib/special.generated.txt'],
    'schema.yaml': <String>['lib/generated_schema.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    if (input.trim() == 'FAIL') throw StateError('invalid schema');
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(
        output,
        input.trimRight() + '|output=' + output.path + '\n',
      );
    }
  }
}
