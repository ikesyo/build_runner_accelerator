import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_triggers.dart'
    show BuildTriggers;
import 'package:built_collection/built_collection.dart';

import 'manifest/emitter.dart';
import 'manifest/mapping.dart';
import 'manifest/model.dart';
import 'manifest/ordering.dart';
import 'manifest/package_graph.dart';
import 'manifest/probe.dart';
import 'manifest/selection.dart';

Future<void> generateBuilderManifest(List<String> arguments) async {
  final options = _Arguments.parse(arguments);
  final root = Directory(options.root).absolute.path;
  final inputs = await _loadInputs(root);
  final resolved = _resolveTargetsAndDefinitions(inputs);
  final selection = _ApplicationSelection(
    selectApplications(
      rootPackageName: resolved.rootPackageName,
      rootConfig: resolved.rootConfig,
      orderedTargets: resolved.orderedTargets,
      definitions: resolved.definitions,
    ),
  );
  final runtimeMappings = await _probeRuntimeMappings(
    root,
    resolved,
    selection,
  );
  final normalized = _normalizeManifest(resolved, selection, runtimeMappings);
  await _emitArtifacts(options, inputs.triggerDigest, normalized);
}

class _LoadedInputs {
  const _LoadedInputs({
    required this.packageGraph,
    required this.configs,
    required this.normalizedTriggerMap,
    required this.triggerDigest,
  });

  final PackageGraph packageGraph;
  final Map<String, BuildConfig> configs;
  final Map<String, List<ManifestTrigger>> normalizedTriggerMap;
  final String triggerDigest;
}

class _ResolvedInputs {
  const _ResolvedInputs({
    required this.rootPackageName,
    required this.rootConfig,
    required this.orderedTargets,
    required this.targetOrder,
    required this.definitions,
    required this.normalizedTriggerMap,
  });

  final String rootPackageName;
  final BuildConfig rootConfig;
  final List<TargetInfo> orderedTargets;
  final TargetOrder<TargetInfo> targetOrder;
  final Map<String, DefinitionInfo> definitions;
  final Map<String, List<ManifestTrigger>> normalizedTriggerMap;
}

class _ApplicationSelection {
  const _ApplicationSelection(this.selected);

  final Map<String, SelectedBuilder> selected;
}

class _RuntimeMappings {
  const _RuntimeMappings({
    required this.probedMappings,
    required this.compatibleDefinitions,
  });

  final Map<String, List<FactoryMapping>> probedMappings;
  final Map<String, List<ManifestDefinition>> compatibleDefinitions;
}

class _NormalizedManifest {
  const _NormalizedManifest({
    required this.builders,
    required this.definitions,
    required this.catalogEntries,
  });

  const _NormalizedManifest.empty()
    : builders = const [],
      definitions = const [],
      catalogEntries = const [];

  final List<Map<String, dynamic>> builders;
  final List<Map<String, dynamic>> definitions;
  final List<CatalogEntry> catalogEntries;
}

Future<_LoadedInputs> _loadInputs(String root) async {
  final packageGraph = await loadPackageGraph(root);
  final configs = await loadBuildConfigs(packageGraph);

  // Keep build_runner's parser and package-wide aggregation as the source of
  // truth. The Rust side receives only this normalized, analyzer-independent
  // representation; it never parses build.yaml trigger strings itself.
  final buildTriggers = BuildTriggers.fromConfigs(
    BuiltMap<String, BuildConfig>.from(configs),
  );
  if (buildTriggers.warningsByPackage.isNotEmpty) {
    throw StateError(
      'Unsupported build trigger configuration:\n${buildTriggers.renderWarnings}',
    );
  }
  return _LoadedInputs(
    packageGraph: packageGraph,
    configs: configs,
    normalizedTriggerMap: normalizedTriggers(buildTriggers),
    triggerDigest: buildTriggers.digest.toString(),
  );
}

_ResolvedInputs _resolveTargetsAndDefinitions(_LoadedInputs inputs) {
  final packageGraph = inputs.packageGraph;
  final rootConfig = inputs.configs[packageGraph.root.name];
  if (rootConfig == null) {
    throw StateError('Root package config was not loaded');
  }
  final targets = <TargetInfo>[];
  for (final package in packageGraph.allPackages.values) {
    if (package.name == r'$sdk') continue;
    final config = inputs.configs[package.name];
    if (config == null) {
      throw StateError('Package config is unavailable: ' + package.name);
    }
    for (final target in config.buildTargets.values) {
      targets.add(
        TargetInfo(
          package: package,
          target: target,
          sources: targetPatterns(target, package, config),
        ),
      );
    }
  }
  final targetOrder = orderTargets(
    targets,
    keyOf: (target) => target.target.key,
    dependenciesOf: (target) => target.target.dependencies,
  );
  final orderedTargets = targetOrder.targets;
  final rootTargetKey = packageGraph.root.name + ':' + packageGraph.root.name;
  final rootTarget = orderedTargets
      .where((target) => target.target.key == rootTargetKey)
      .firstOrNull;
  if (rootTarget == null) {
    throw StateError('Root target is unavailable: ' + rootTargetKey);
  }
  final definitions = <String, DefinitionInfo>{};
  for (final config in inputs.configs.values) {
    for (final definition in config.builderDefinitions.values) {
      // Match build_runner's build-script rule: relative imports from
      // dependency packages cannot be imported by the root worker script.
      if (!definition.import.startsWith('package:') &&
          definition.package != packageGraph.root.name) {
        continue;
      }
      definitions[definition.key] = DefinitionInfo.normal(definition);
    }
    for (final definition in config.postProcessBuilderDefinitions.values) {
      // Post-process builders use the same package:builder key namespace as
      // normal builders, but are resolved through a different factory type.
      if (!definition.import.startsWith('package:') &&
          definition.package != packageGraph.root.name) {
        continue;
      }
      definitions[definition.key] = DefinitionInfo.postProcess(definition);
    }
  }
  return _ResolvedInputs(
    rootPackageName: packageGraph.root.name,
    rootConfig: rootConfig,
    orderedTargets: orderedTargets,
    targetOrder: targetOrder,
    definitions: definitions,
    normalizedTriggerMap: inputs.normalizedTriggerMap,
  );
}

Future<_RuntimeMappings> _probeRuntimeMappings(
  String root,
  _ResolvedInputs resolved,
  _ApplicationSelection selection,
) async {
  if (selection.selected.isEmpty) {
    return const _RuntimeMappings(
      probedMappings: {},
      compatibleDefinitions: {},
    );
  }

  // build.yaml remains the ordering source, while the instantiated Builder is
  // the expected-output source. Probe selected multi-factory and
  // option-dependent applications so target-local mapping overrides remain
  // lossless and package-specific Rust branches are unnecessary.
  final probeRequests = selection.selected.entries
      .where((entry) => requiresRuntimeProbe(entry.value))
      .map(
        (entry) => FactoryProbeRequest(
          id: entry.key,
          definition: entry.value.definition,
          options: _jsonMap(entry.value.options),
          isRoot: entry.value.target.package.isRoot,
        ),
      )
      .toList(growable: false);
  final probedMappings = await probeFactoryMappings(root, probeRequests);
  final canonicalMappings = <String, List<FactoryMapping>>{};
  for (final request in probeRequests) {
    final mappings = probedMappings[request.id];
    if (mappings != null) {
      canonicalMappings.putIfAbsent(request.definition.key, () => mappings);
    }
  }
  final compatibleDefinitions = <String, List<ManifestDefinition>>{};
  for (final info in resolved.definitions.values) {
    final converted = tryConvertDefinition(
      info,
      canonicalMappings[info.key],
      triggers: resolved.normalizedTriggerMap[info.key] ?? const [],
    );
    if (converted != null && converted.isNotEmpty) {
      compatibleDefinitions[info.key] = converted;
    }
  }

  for (final entry in selection.selected.entries) {
    final selectedBuilder = entry.value;
    final definition = selectedBuilder.definition;
    final requiresProbe = requiresRuntimeProbe(selectedBuilder);
    final runtimeMappings = probedMappings[entry.key];
    if (requiresProbe) {
      if (runtimeMappings == null ||
          !compatibleDefinitions.containsKey(definition.key) ||
          compatibleDefinitions[definition.key]!.any(
            (converted) =>
                runtimeMappingJson(definition, runtimeMappings, converted) ==
                null,
          )) {
        throw StateError(
          'Builder runtime mapping is outside the supported subset: ' +
              definition.key,
        );
      }
    }
    if (!compatibleDefinitions.containsKey(definition.key)) {
      throw StateError(
        'Builder is outside the dynamic worker subset: ' + definition.key,
      );
    }
  }
  return _RuntimeMappings(
    probedMappings: probedMappings,
    compatibleDefinitions: compatibleDefinitions,
  );
}

_NormalizedManifest _normalizeManifest(
  _ResolvedInputs resolved,
  _ApplicationSelection selection,
  _RuntimeMappings runtime,
) {
  if (selection.selected.isEmpty) return const _NormalizedManifest.empty();

  final activeEntries = <Map<String, dynamic>>[];
  final selectedDefinitions = <String>{};
  final allOutputSuffixes = <String>{
    for (final definitions in runtime.compatibleDefinitions.values)
      for (final definition in definitions) ...definition.outputSuffixes,
  };
  final normalDefinitions = <String, DefinitionInfo>{
    for (final entry in resolved.definitions.entries)
      if (!entry.value.isPostProcess) entry.key: entry.value,
  };
  final builderOrdering = <String, BuilderOrderDefinition>{
    for (final entry in normalDefinitions.entries)
      entry.key: BuilderOrderDefinition(
        requiredInputs: entry.value.normal!.requiredInputs,
        buildExtensionOutputs: entry.value.normal!.buildExtensions.values,
        runsBefore: entry.value.normal!.runsBefore,
      ),
  };
  final globalRunsBefore = <String, Iterable<String>>{
    for (final entry in resolved.rootConfig.globalOptions.entries)
      entry.key: entry.value.runsBefore,
  };
  final globallyOrderedKeys = orderBuilders(
    normalDefinitions.keys.toList(),
    builderOrdering,
    globalRunsBefore,
  );
  // Flatten the factory phases in the same order as build_runner's phase
  // creator: definition order first, then factory order within a definition.
  final builderOrder = <String, int>{};
  var nextBuilderOrder = 0;
  for (final key in globallyOrderedKeys) {
    for (final definition in runtime.compatibleDefinitions[key] ?? const []) {
      if (definition.isPostProcess) continue;
      builderOrder[definition.id] = nextBuilderOrder++;
    }
  }
  for (final target in resolved.orderedTargets) {
    final componentIndex =
        resolved.targetOrder.componentIndex[target.target.key]!;
    final memberIndex = resolved.targetOrder.memberIndex[target.target.key]!;
    final targetBuilders = selection.selected.values
        .where((builder) => builder.target.target.key == target.target.key)
        .toList();
    if (targetBuilders.isEmpty) continue;
    final selectedKeys = targetBuilders
        .map((builder) => builder.definition.key)
        .toSet()
        .toList();
    final normalKeys = globallyOrderedKeys
        .where(selectedKeys.contains)
        .toList(growable: false);
    final postProcessKeys =
        targetBuilders
            .where((builder) => builder.definition.isPostProcess)
            .map((builder) => builder.definition.key)
            .toList()
          ..sort();
    final runtimeSuffixesById = <String, List<String>>{};
    for (final candidateBuilder in targetBuilders) {
      final candidateMappings =
          runtime.probedMappings[_selectedKey(
            target.target.key,
            candidateBuilder.definition.key,
          )];
      for (final candidate
          in runtime.compatibleDefinitions[candidateBuilder.definition.key] ??
              const <ManifestDefinition>[]) {
        runtimeSuffixesById[candidate.id] = runtimeOutputSuffixes(
          candidateBuilder.definition,
          candidateMappings,
          candidate,
        );
      }
    }
    final orderedKeys = <String>[...normalKeys, ...postProcessKeys];
    for (final key in orderedKeys) {
      final selectedBuilder = targetBuilders.firstWhere(
        (builder) => builder.definition.key == key,
      );
      final selectedPatterns = patterns(selectedBuilder.generateFor);
      for (final converted in runtime.compatibleDefinitions[key]!) {
        selectedDefinitions.add(converted.id);
        final excludedInputSuffixes = converted.isPostProcess
            ? <String>[]
            : (<String>{
                for (final candidateKey in normalKeys)
                  for (final candidate
                      in runtime.compatibleDefinitions[candidateKey]!)
                    if (!candidate.isPostProcess &&
                        builderOrder[candidate.id]! >=
                            builderOrder[converted.id]!)
                      ...(runtimeSuffixesById[candidate.id] ??
                          candidate.outputSuffixes),
              }.toList()..sort());
        activeEntries.add(
          converted.toJson(
            generateFor: selectedPatterns.include,
            generateForExclude: selectedPatterns.exclude,
            targetSources: target.sources.include,
            targetSourcesExclude: target.sources.exclude,
            options: _jsonMap(selectedBuilder.options),
            isRoot: target.package.isRoot,
            runtimeMapping: runtimeMappingJson(
              selectedBuilder.definition,
              runtime.probedMappings[_selectedKey(target.target.key, key)],
              converted,
            ),
            phase: converted.isPostProcess
                ? 0
                : builderOrder[converted.id]! *
                          resolved.targetOrder.maxComponentSize +
                      memberIndex,
            target: target.target.key,
            package: target.package.name,
            targetOrder: componentIndex,
            excludedInputSuffixes: excludedInputSuffixes,
          ),
        );
      }
    }
  }

  final allCompatibleDefinitions = <ManifestDefinition>[
    for (final definitions in runtime.compatibleDefinitions.values)
      ...definitions,
  ]..sort((left, right) => left.id.compareTo(right.id));
  final definitionEntries = <Map<String, dynamic>>[
    for (final definition in allCompatibleDefinitions)
      definition.toJson(
        generateFor: const [],
        generateForExclude: const [],
        targetSources: const [],
        targetSourcesExclude: const [],
        options: const {},
        phase: 0,
        target: null,
        package: null,
        targetOrder: 0,
        excludedInputSuffixes: allOutputSuffixes.toList()..sort(),
      ),
  ];

  final catalogEntries = <CatalogEntry>[
    for (final definition in allCompatibleDefinitions)
      if (selectedDefinitions.contains(definition.id))
        _catalogEntry(definition),
  ];
  return _NormalizedManifest(
    builders: activeEntries,
    definitions: definitionEntries,
    catalogEntries: catalogEntries,
  );
}

Future<void> _emitArtifacts(
  _Arguments options,
  String triggerDigest,
  _NormalizedManifest normalized,
) => emitManifestArtifacts(
  manifestPath: options.manifest,
  workerEntrypoint: options.workerEntrypoint,
  fingerprint: options.fingerprint,
  builders: normalized.builders,
  definitions: normalized.definitions,
  catalogEntries: normalized.catalogEntries,
  triggerDigest: triggerDigest,
);

Map<String, dynamic> _jsonMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

String _selectedKey(String target, String builder) => '$target|$builder';

CatalogEntry _catalogEntry(ManifestDefinition definition) => CatalogEntry(
  id: definition.id,
  importUri: definition.importUri,
  factory: definition.factory,
  isPostProcess: definition.isPostProcess,
);

class _Arguments {
  _Arguments({
    required this.root,
    required this.manifest,
    required this.workerEntrypoint,
    required this.fingerprint,
  });

  final String root;
  final String manifest;
  final String workerEntrypoint;
  final String fingerprint;

  static _Arguments parse(List<String> arguments) {
    String? value(String name) {
      final index = arguments.indexOf(name);
      if (index < 0 || index + 1 >= arguments.length) {
        return null;
      }
      return arguments[index + 1];
    }

    final root = value('--root');
    final manifest = value('--manifest');
    final workerEntrypoint = value('--worker-entrypoint');
    final fingerprint = value('--fingerprint');
    if (root == null ||
        manifest == null ||
        workerEntrypoint == null ||
        fingerprint == null) {
      throw ArgumentError(
        'required arguments: --root --manifest --worker-entrypoint --fingerprint',
      );
    }
    return _Arguments(
      root: root,
      manifest: manifest,
      workerEntrypoint: workerEntrypoint,
      fingerprint: fingerprint,
    );
  }
}
