import 'package:build/build.dart';

// Supply generated manifests without loading Conduit's Analyzer-based builders.
// The consumer remains the published registryBuilder factory, unchanged.
Builder sourceManifest(BuilderOptions options) =>
    _CopyManifest('.record', '.controller.conduit.json');
Builder cacheManifest(BuilderOptions options) =>
    _CopyManifest('.cached', '.channel.conduit.json');

class _CopyManifest implements Builder {
  _CopyManifest(this.input, this.output);
  final String input;
  final String output;

  @override
  Map<String, List<String>> get buildExtensions => {
    input: [output],
  };

  @override
  Future<void> build(BuildStep step) async {
    await step.writeAsString(
      step.inputId.changeExtension(output),
      await step.readAsString(step.inputId),
    );
  }
}
