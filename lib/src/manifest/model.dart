import 'package:build_config/build_config.dart';

/// The package graph data needed while generating the worker manifest.
class PackageGraph {
  PackageGraph({required this.root, required this.allPackages});

  final PackageInfo root;
  final Map<String, PackageInfo> allPackages;
}

class PackageInfo {
  PackageInfo({required this.name, required this.path, required this.isRoot});

  final String name;
  final String path;
  final bool isRoot;
  final List<PackageInfo> dependencies = <PackageInfo>[];
}

class PatternSet {
  const PatternSet(this.include, this.exclude);

  final List<String> include;
  final List<String> exclude;
}

class TargetInfo {
  TargetInfo({
    required this.package,
    required this.target,
    required this.sources,
  });

  final PackageInfo package;
  final BuildTarget target;
  final PatternSet sources;
}

class TargetOrder<T> {
  const TargetOrder(
    this.targets,
    this.componentIndex,
    this.memberIndex,
    this.maxComponentSize,
  );

  final List<T> targets;
  final Map<String, int> componentIndex;
  final Map<String, int> memberIndex;
  final int maxComponentSize;
}

class DefinitionInfo {
  DefinitionInfo.normal(this.normal) : postProcess = null;
  DefinitionInfo.postProcess(this.postProcess) : normal = null;

  final BuilderDefinition? normal;
  final PostProcessBuilderDefinition? postProcess;

  bool get isPostProcess => postProcess != null;
  String get key => normal?.key ?? postProcess!.key;
  TargetBuilderConfigDefaults get defaults =>
      normal?.defaults ?? postProcess!.defaults;
  Iterable<String> get appliesBuilders => normal?.appliesBuilders ?? const [];
}

class SelectedBuilder {
  SelectedBuilder(this.definition, this.target, this.generateFor, this.options);

  final DefinitionInfo definition;
  final TargetInfo target;
  final InputSet generateFor;
  final Map<String, dynamic> options;
}

class FactoryProbeRequest {
  FactoryProbeRequest({
    required this.id,
    required this.definition,
    required this.options,
    required this.isRoot,
  });

  final String id;
  final DefinitionInfo definition;
  final Map<String, dynamic> options;
  final bool isRoot;
}

class FactoryMapping {
  FactoryMapping({
    required this.factory,
    required this.buildExtensions,
    this.inputExtensions,
  });

  final String factory;
  final Map<String, List<String>> buildExtensions;
  final List<String>? inputExtensions;
}

class ManifestExtension {
  const ManifestExtension({
    required this.inputSuffix,
    required this.inputMatch,
    required this.inputAnchored,
    required this.outputSuffixes,
  });

  final String inputSuffix;
  final String inputMatch;
  final bool inputAnchored;
  final List<String> outputSuffixes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'input_suffix': inputSuffix,
    'input_match': inputMatch,
    'input_anchored': inputAnchored,
    'output_suffixes': outputSuffixes,
  };
}

class ManifestTrigger {
  const ManifestTrigger({required this.kind, required this.value});

  final String kind;
  final String value;

  Map<String, String> toJson() => <String, String>{
    'kind': kind,
    'value': value,
  };
}

class ManifestDefinition {
  ManifestDefinition({
    required this.id,
    required this.importUri,
    required this.factory,
    required this.kind,
    required this.extensions,
    required this.inputExtensions,
    required this.buildTo,
    required this.outputIsOptional,
    required this.isOptional,
    required this.requiredInputSuffixes,
    required this.triggers,
  });

  final String id;
  final String importUri;
  final String factory;
  final String kind;
  final List<ManifestExtension> extensions;
  final List<String> inputExtensions;
  final String buildTo;
  final bool outputIsOptional;
  final bool isOptional;
  final List<String> requiredInputSuffixes;
  final List<ManifestTrigger> triggers;

  bool get isPostProcess => kind == 'post_process';

  String get inputSuffix =>
      isPostProcess ? inputExtensions.first : extensions.first.inputSuffix;

  String get inputMatch =>
      isPostProcess ? 'suffix' : extensions.first.inputMatch;

  bool get inputAnchored =>
      isPostProcess ? false : extensions.first.inputAnchored;

  List<String> get outputSuffixes => [
    for (final extension in extensions) ...extension.outputSuffixes,
  ];

  Map<String, dynamic> toJson({
    required List<String> generateFor,
    required List<String> generateForExclude,
    required List<String> targetSources,
    required List<String> targetSourcesExclude,
    required Map<String, dynamic> options,
    bool isRoot = false,
    Map<String, dynamic>? runtimeMapping,
    required int phase,
    required String? target,
    required String? package,
    required int targetOrder,
    required List<String> excludedInputSuffixes,
  }) => <String, dynamic>{
    'id': id,
    'kind': kind,
    if (!isPostProcess)
      'extensions': [for (final extension in extensions) extension.toJson()],
    if (isPostProcess) 'input_extensions': inputExtensions,
    // Keep the flattened fields while the watch-side manifest reader and
    // older diagnostics transition to the explicit extension list.
    if (!isPostProcess) 'input_suffix': inputSuffix,
    if (!isPostProcess) 'input_match': inputMatch,
    if (!isPostProcess) 'input_anchored': inputAnchored,
    if (!isPostProcess) 'output_suffixes': outputSuffixes,
    'build_to': buildTo,
    'phase': phase,
    if (target != null) 'target': target,
    if (package != null) 'package': package,
    if (target != null) 'target_order': targetOrder,
    'is_optional': isOptional,
    'output_is_optional': outputIsOptional,
    'required_input_suffixes': requiredInputSuffixes,
    'triggers': [for (final trigger in triggers) trigger.toJson()],
    'excluded_input_suffixes': excludedInputSuffixes,
    'generate_for': generateFor,
    'generate_for_exclude': generateForExclude,
    'target_sources': targetSources,
    'target_sources_exclude': targetSourcesExclude,
    'options': options,
    if (target != null) 'is_root': isRoot,
    if (runtimeMapping != null) 'runtime_mapping': runtimeMapping,
  };
}

class CatalogEntry {
  CatalogEntry({
    required this.id,
    required this.importUri,
    required this.factory,
    required this.isPostProcess,
  });

  final String id;
  final String importUri;
  final String factory;
  final bool isPostProcess;
}
