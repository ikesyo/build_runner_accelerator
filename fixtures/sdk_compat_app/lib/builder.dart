import 'package:build/build.dart';

Builder summary(BuilderOptions options) => _Summary();

class _Summary implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.summary'],
  };

  @override
  Future<void> build(BuildStep step) async {
    final library = await step.resolver.libraryFor(step.inputId);
    final names = library.classes.map((element) => element.name).toList()
      ..sort();
    await step.writeAsString(
      step.allowedOutputs.single,
      '${names.join(',')}\n',
    );
    // Stage an output before failure to exercise native publication protection.
    if ((await step.readAsString(step.inputId)).contains('// fail')) {
      throw StateError('requested SDK compatibility failure');
    }
  }
}
