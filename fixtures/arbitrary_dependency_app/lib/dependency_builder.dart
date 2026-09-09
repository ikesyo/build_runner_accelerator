import 'package:build/build.dart';

Builder seedBuilder(BuilderOptions options) => _SeedBuilder();

class _SeedBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
        '.txt': <String>['.seed.txt'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = await buildStep.readAsString(buildStep.inputId);
    final output = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.seed.txt'),
    );
    await buildStep.writeAsString(output, input.trimRight() + ' seed\n');
  }
}

Builder summaryBuilder(BuilderOptions options) => _SummaryBuilder();

class _SummaryBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
        '.txt': <String>['.summary.txt'],
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    final seed = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.seed.txt'),
    );
    final seedContents = await buildStep.readAsString(seed);
    final output = AssetId(
      buildStep.inputId.package,
      buildStep.inputId.path.replaceFirst(RegExp(r'\.txt$'), '.summary.txt'),
    );
    await buildStep.writeAsString(
      output,
      seedContents.trimRight() + ' summary\n',
    );
  }
}
