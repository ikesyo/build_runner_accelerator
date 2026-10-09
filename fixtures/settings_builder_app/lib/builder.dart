import 'dart:convert';
import 'package:build/build.dart';

Builder settings(BuilderOptions options) => SettingsBuilder(options);
Builder marker(BuilderOptions options) => SettingsBuilder(
  BuilderOptions({'suffix': '.marker'}, isRoot: options.isRoot),
);

class SettingsBuilder implements Builder {
  SettingsBuilder(this.options);
  final BuilderOptions options;
  @override
  Map<String, List<String>> get buildExtensions => {
    '.txt': [options.config['suffix'] as String? ?? '.out'],
  };
  @override
  Future<void> build(BuildStep step) async {
    // A config override can stop emission as well as change the mapping.
    if (options.config['emit'] == false) return;
    await step.writeAsString(
      step.allowedOutputs.single,
      jsonEncode({
        'input': await step.readAsString(step.inputId),
        'root': options.isRoot,
        'options': options.config,
      }),
    );
  }
}
