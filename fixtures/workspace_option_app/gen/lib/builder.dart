import 'package:build/build.dart';

Builder copyBuilder(BuilderOptions options) => CopyBuilder();

class CopyBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    '.txt': ['.gen'],
  };
  @override
  Future<void> build(BuildStep step) async {
    final value = await step.readAsString(step.inputId);
    if (value.contains('FAIL')) throw StateError('workspace fixture failure');
    await step.writeAsString(step.allowedOutputs.single, 'copied: $value');
  }
}
