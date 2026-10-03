import 'package:build/build.dart';
import 'package:glob/glob.dart';

Builder optionalBuilder(BuilderOptions options) => _OptionalBuilder(options);
Builder secondaryConsumer(BuilderOptions options) =>
    _SecondaryConsumer(options);
Builder primaryConsumer(BuilderOptions options) => _PrimaryConsumer();
Builder globConsumer(BuilderOptions options) => _GlobConsumer();

class _OptionalBuilder implements Builder {
  _OptionalBuilder(this._options);

  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.txt': <String>['.optional.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (_options.config['fail'] == true) {
      throw StateError('optional builder failure');
    }
    final input = await buildStep.readAsString(buildStep.inputId);
    final probe = _options.config['resolve'] == true
        ? '|resolver:${await _resolverProbe(buildStep)}'
        : '';
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.optional.txt'),
      'optional:$input$probe',
    );
  }
}

class _SecondaryConsumer implements Builder {
  _SecondaryConsumer(this._options);
  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/input.txt': <String>['lib/input.final.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    final optional = AssetId(
      buildStep.inputId.package,
      'lib/input.optional.txt',
    );
    final resolve = _options.config['resolve'] == true;
    final before = resolve ? await _resolverProbe(buildStep) : '';
    final optionalInput = await buildStep.readAsString(optional);
    final after = resolve ? await _resolverProbe(buildStep) : '';
    if (before != after)
      throw StateError('resolver changed across optional demand');
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'secondary:$input|$optionalInput',
    );
  }
}

class _PrimaryConsumer implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.optional.txt': <String>['.primary.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'primary:$input',
    );
  }
}

class _GlobConsumer implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '^lib/input.txt': <String>['lib/input.glob.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final matches = await buildStep
        .findAssets(Glob('lib/*.optional.txt'))
        .toList();
    final optionalInput = await buildStep.readAsString(matches.single);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      'glob:$optionalInput',
    );
  }
}

Future<String> _resolverProbe(BuildStep step) async {
  final id = AssetId(step.inputId.package, 'lib/resolver_probe.dart');
  Future<String> read() async {
    final library = await step.resolver.isLibrary(id);
    final unit = await step.resolver.compilationUnitFor(id);
    final element = await step.resolver.libraryFor(id);
    final classes = element.classes.map((c) => c.name).toList()..sort();
    return '$library|${unit.declarations.length}|${classes.join(',')}';
  }

  final first = await read();
  if (first != await read())
    throw StateError('repeated resolver results differ');
  return first;
}
