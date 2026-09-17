import 'package:build/build.dart';

Builder analyzerProbe(BuilderOptions options) => _AnalyzerProbe(options);

class _AnalyzerProbe implements Builder {
  _AnalyzerProbe(this._options);

  final BuilderOptions _options;

  @override
  Map<String, List<String>> get buildExtensions => const <String, List<String>>{
    '.dart': <String>['.drift_analyzer_probe.txt'],
    '.drift': <String>['.drift_analyzer_probe.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final input = buildStep.inputId;
    final elements = input.addExtension('.drift_elements.json');
    final module = input.addExtension('.drift_module.json');
    final types = input.addExtension('.types.temp.dart');
    final lines = <String>[
      'input=${input.path}',
      'elements=${await _assetSummary(buildStep, elements)}',
      'module=${await _assetSummary(buildStep, module)}',
      'types=${await _assetSummary(buildStep, types)}',
    ];

    if (input.extension == '.dart') {
      final resolver = buildStep.resolver;
      final inputLibrary = await buildStep.inputLibrary;
      final resolvedLibrary = await resolver.libraryFor(input);
      final namedLibrary = await resolver.findLibraryByName(
        'drift_analyzer_app',
      );
      final elementAsset = await resolver.assetIdForElement(inputLibrary);
      final packageConfig = await buildStep.packageConfig;
      final package = packageConfig.packages.firstWhere(
        (candidate) => candidate.name == input.package,
      );
      lines.addAll(<String>[
        'input_library=${inputLibrary.name ?? 'unnamed'}',
        'library_for=${resolvedLibrary.name ?? 'unnamed'}',
        'find_library_by_name=${namedLibrary?.name ?? 'missing'}',
        'asset_id_for_element=${elementAsset.path}',
        'language_version=${package.languageVersion}',
      ]);
    }

    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      '${lines.join('\n')}\n',
    );

    if (_options.config['fail_after_write'] == true) {
      throw StateError('analyzer probe failure after writing output');
    }
  }
}

Future<String> _assetSummary(BuildStep buildStep, AssetId id) async {
  if (!await buildStep.canRead(id)) return 'missing';
  final contents = await buildStep.readAsString(id);
  var checksum = 0;
  for (final codeUnit in contents.codeUnits) {
    checksum = (checksum * 31 + codeUnit) & 0x7fffffff;
  }
  return 'present:${contents.length}:$checksum';
}
