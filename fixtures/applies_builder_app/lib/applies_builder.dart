import 'package:build/build.dart';

Builder producer(BuilderOptions options) => _ProducerBuilder();
Builder consumer(BuilderOptions options) => _ConsumerBuilder();

class _ProducerBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.txt': ['.produced.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    final output = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst('.txt', '.produced.txt'),
    );
    await buildStep.writeAsString(
      output,
      'producer input=' +
          buildStep.inputId.path +
          '\n' +
          input.trimRight() +
          '\n',
    );
  }
}

class _ConsumerBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.produced.txt': ['.consumed.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    final output = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst('.produced.txt', '.consumed.txt'),
    );
    await buildStep.writeAsString(
      output,
      'consumer input=' +
          buildStep.inputId.path +
          '\n' +
          input.trimRight() +
          '\n',
    );
  }
}
