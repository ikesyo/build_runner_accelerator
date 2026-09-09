import 'package:build/build.dart';

Builder multiMappingBuilder(BuilderOptions options) => _MultiMappingBuilder();

class _MultiMappingBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.txt': ['.multi'],
    '^lib/special.txt': ['lib/special.generated.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    for (final output in buildStep.allowedOutputs) {
      await buildStep.writeAsString(
        output,
        input.trimRight() + '|output=' + output.path + '\n',
      );
    }
  }
}
