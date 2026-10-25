import 'package:build/build.dart';
import 'dart:io';

Builder first(BuilderOptions options) => _Contributor(false);
Builder second(BuilderOptions options) => _Contributor(true);
Builder summary(BuilderOptions options) => _Summary();
Builder optionalPayload(BuilderOptions options) => _OptionalPayload();

class _OptionalPayload implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': ['.optional.txt'],
  };
  @override
  Future<void> build(BuildStep step) async {
    final source = await step.readAsString(step.inputId);
    final history = Platform.environment['SHARED_OPTIONAL_HISTORY'];
    if (history != null) {
      File(history).writeAsStringSync(
        '${step.inputId}:${source.length}\n',
        mode: FileMode.append,
      );
    }
    await step.writeAsString(step.allowedOutputs.single, source);
  }
}

class _Contributor implements Builder {
  _Contributor(this.second);
  final bool second;
  @override
  Map<String, List<String>> get buildExtensions => {
    '.dart': second ? [] : ['.first.txt'],
  };
  @override
  Future<void> build(BuildStep step) async {
    final source = await step.readAsString(step.inputId);
    final sink = await step.librarySourceSink;
    if (sink == null) return;
    if (!source.contains('// empty')) {
      if (second) {
        final library = await step.resolver.libraryFor(step.inputId);
        final seesFirst = library.classes.any(
          (element) => element.name == 'FirstGenerated',
        );
        sink.add('const seesFirst = $seesFirst; class SecondGenerated {}');
      } else {
        if (source.contains('// optional')) {
          final payload = await step.readAsString(
            step.inputId.changeExtension('.optional.txt'),
          );
          sink.add('const optionalLength = ${payload.length};');
        }
        if (source.contains('// imports')) {
          final prefix = '${sink.importPrefix}math';
          sink.addImport('dart:math', as: prefix, show: ['pi']);
          sink.add('const importedMarker = $prefix.pi;');
        }
        sink.add('class FirstGenerated {}');
      }
    }
    if (!second)
      await step.writeAsString(
        step.inputId.changeExtension('.first.txt'),
        source,
      );
    if (source.contains('// fail') ||
        (source.contains('// replay-failure') && source.contains('part ')))
      throw StateError('requested shared-part failure');
  }
}

class _Summary implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => {
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
  }
}
