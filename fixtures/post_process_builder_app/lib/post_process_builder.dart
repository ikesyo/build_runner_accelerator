import 'package:build/build.dart';

Builder echoBuilder(BuilderOptions options) => _EchoBuilder();

PostProcessBuilder appendPostProcessBuilder(BuilderOptions options) =>
    _AppendPostProcessBuilder(
      emit: options.config['emit'] as bool? ?? true,
      fail: options.config['fail'] as bool? ?? false,
    );

class _EchoBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.txt': <String>['.gen.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      AssetId(
        buildStep.inputId.package,
        buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.gen.txt'),
      ),
      input.trimRight() + ' generated\n',
    );
  }
}

class _AppendPostProcessBuilder implements PostProcessBuilder {
  _AppendPostProcessBuilder({required this.emit, required this.fail});

  final bool emit;
  final bool fail;

  @override
  Iterable<String> get inputExtensions => const <String>['.gen.txt'];

  @override
  Future<void> build(PostProcessBuildStep buildStep) async {
    if (fail) throw StateError('post-process fixture failure');
    if (!emit) return;
    final input = await buildStep.readInputAsString();
    final output = AssetId(
      buildStep.inputId.package,
      '${buildStep.inputId.path}.post.txt',
    );
    await buildStep.writeAsString(output, input.trimRight() + ' post\n');
  }
}
