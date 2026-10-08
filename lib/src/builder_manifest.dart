import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';

import 'manifest/emitter.dart';
import 'manifest/mapping.dart';
import 'manifest/model.dart';
import 'manifest/ordering.dart';
import 'manifest/catalog.dart';
import 'manifest/package_graph.dart';
import 'manifest/probe.dart';
import 'manifest/selection.dart';
import 'manifest/settings.dart';

Future<void> generateBuilderManifest(List<String> arguments) async {
  final metrics =
      Platform.environment['BUILD_RUNNER_ACCELERATOR_METRICS'] == '1';
  final timer = Stopwatch()..start();
  var previousMicros = 0;
  void reportStage(String stage) {
    if (!metrics) return;
    final elapsed = timer.elapsedMicroseconds;
    stderr.writeln(
      'Dart manifest metrics: stage=$stage '
      'elapsed_us=${elapsed - previousMicros} total_us=$elapsed',
    );
    previousMicros = elapsed;
  }

  final options = _Arguments.parse(arguments);
  final root = Directory(options.root).absolute.path;
  final inputs = await _loadInputs(root, options.settings);
  reportStage('load-inputs');
  final resolved = _resolveTargetsAndDefinitions(inputs);
  final selection = _ApplicationSelection(
    selectApplications(
      rootPackageName: resolved.rootPackageName,
      rootConfig: resolved.rootConfig,
      orderedTargets: resolved.orderedTargets,
      definitions: resolved.definitions,
      release: options.settings.release,
      overrides: options.settings.overrides(inputs.packageGraph.root.name),
    ),
  );
  reportStage('select-builders');
  // Emit the worker entrypoint before probing: the Rust frontend overlaps
  // the synchronous worker AOT compile with the probe window. The catalog is
  // a superset of the final one (a builder that later fails conversion keeps
  // its unused factory in the script); when the manifest succeeds the early
  // and final contents are identical.
  if (selection.selected.isNotEmpty) {
    await emitWorkerEntrypoint(
      options.workerEntrypoint,
      earlyCatalogEntries(selection.selected),
    );
  }
  reportStage('entrypoint');
  final triggers = await loadManifestTriggers(
    root,
    options.workerEntrypoint,
    configKey: options.settings.config,
  );
  reportStage('triggers');
  final runtimeMappings = await _probeRuntimeMappings(
    root,
    resolved,
    selection,
    options.fingerprint,
    options.workerEntrypoint,
    triggers.triggers,
  );
  reportStage('probe');
  final normalized = _normalizeManifest(resolved, selection, runtimeMappings);
  await _emitArtifacts(options, triggers.digest, normalized);
  reportStage('emit');
}

class _LoadedInputs {
  const _LoadedInputs({
    required this.packageGraph,
    required this.configs,
    required this.definitionConfigs,
  });

  final PackageGraph packageGraph;
  final Map<String, BuildConfig> configs;
  final Map<String, BuildConfig> definitionConfigs;
}

class _ResolvedInputs {
  const _ResolvedInputs({
    required this.rootPackageName,
    required this.rootConfig,
    required this.orderedTargets,
    required this.targetOrder,
    required this.definitions,
  });

  final String rootPackageName;
  final BuildConfig rootConfig;
  final List<TargetInfo> orderedTargets;
  final TargetOrder<TargetInfo> targetOrder;
  final Map<String, DefinitionInfo> definitions;
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

Future<_LoadedInputs> _loadInputs(String root, BuildSettings settings) async {
  final packageGraph = await loadPackageGraph(root);
  final configs = await loadBuildConfigs(packageGraph);

  return _LoadedInputs(
    packageGraph: packageGraph,
    configs: settings.config == null
        ? configs
        : await loadBuildConfigs(packageGraph, configKey: settings.config),
    definitionConfigs: configs,
  );
}

_ResolvedInputs _resolveTargetsAndDefinitions(_LoadedInputs inputs) {
  final catalog = resolveBuilderCatalog(
    inputs.packageGraph,
    inputs.configs,
    definitionConfigs: inputs.definitionConfigs,
  );
  return _ResolvedInputs(
    rootPackageName: catalog.rootPackageName,
    rootConfig: catalog.rootConfig,
    orderedTargets: catalog.orderedTargets,
    targetOrder: catalog.targetOrder,
    definitions: catalog.definitions,
  );
}

Future<_RuntimeMappings> _probeRuntimeMappings(
  String root,
  _ResolvedInputs resolved,
  _ApplicationSelection selection,
  String probeCacheKey,
  String workerEntrypoint,
  Map<String, List<ManifestTrigger>> triggers,
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
  // lossless and package-specific Rust branches are unnecessary. Normal
  // builders are also probed for their runtime type — the manifest flags
  // part-family builders for the frontend's part-directive pre-filter — but
  // only when their declared outputs could carry a `part` file at all: a
  // builder that emits no `.dart`/`.part` output can never be gated by a
  // `part` directive, so leaving its type unknown is strictly conservative.
  final probeRequiredKeys = <String>{
    for (final entry in selection.selected.entries)
      if (requiresRuntimeProbe(entry.value)) entry.key,
  };
  final probeRequests = selection.selected.entries
      .where(
        (entry) =>
            probeRequiredKeys.contains(entry.key) ||
            (!entry.value.definition.isPostProcess &&
                _declaresPartFamilyOutputs(entry.value.definition)),
      )
      .map(
        (entry) => FactoryProbeRequest(
          id: entry.key,
          definition: entry.value.definition,
          options: _jsonMap(entry.value.options),
          isRoot: entry.value.target.package.isRoot,
        ),
      )
      .toList(growable: false);
  final probedMappings = await probeFactoryMappings(
    root,
    probeRequests,
    cacheKey: probeCacheKey,
    workerEntrypoint: workerEntrypoint,
  );
  final canonicalMappings = <String, List<FactoryMapping>>{};
  final builderTypes = <String, List<String?>>{};
  for (final request in probeRequests) {
    final mappings = probedMappings[request.id];
    if (mappings == null) continue;
    if (probeRequiredKeys.contains(request.id)) {
      canonicalMappings.putIfAbsent(request.definition.key, () => mappings);
    }
    builderTypes.putIfAbsent(
      request.definition.key,
      () => [for (final mapping in mappings) mapping.builderType],
    );
  }
  final compatibleDefinitions = <String, List<ManifestDefinition>>{};
  for (final info in resolved.definitions.values) {
    final converted = tryConvertDefinition(
      info,
      canonicalMappings[info.key],
      triggers: triggers[info.key] ?? const [],
      builderTypes: builderTypes[info.key],
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

/// Whether a normal builder's declared build.yaml outputs could be a `part`
/// file at all — i.e. any output ending in `.dart` or `.part`. Builders
/// outside this shape never produce a `part`-gated output, so skipping their
/// runtime-type probe only loses the pre-filter eligibility, never
/// correctness.
bool _declaresPartFamilyOutputs(DefinitionInfo info) =>
    info.normal!.buildExtensions.values.any(
      (outputs) => outputs.any(
        (output) => output.endsWith('.dart') || output.endsWith('.part'),
      ),
    );

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
  // Part-family builders validate that the input declares their output as a
  // `part` directive before writing anything; when the directive is absent
  // the action provably emits nothing, so the frontend can skip it after a
  // cheap source scan instead of dispatching it to a worker. The suffix the
  // input must declare is the combining builder's output extension for
  // shared-part builders, and the builder's own output extension for direct
  // part builders. Only resolve it when it is unambiguous.
  final combiningSuffixes = <String>{
    for (final definitions in runtime.compatibleDefinitions.values)
      for (final definition in definitions)
        if (definition.builderType == 'CombiningBuilder')
          ...definition.outputSuffixes,
  };
  // A shared part's intermediates are only safe to skip when the combining
  // builder (plus the part_cleanup post-processor) are their sole consumers:
  // another builder or post-processor declaring `.part` inputs could read
  // them.
  final sharedPartConsumedElsewhere = runtime.compatibleDefinitions.values
      .expand((definitions) => definitions)
      .any(
        (definition) =>
            definition.builderType != 'CombiningBuilder' &&
            definition.id != 'source_gen:part_cleanup' &&
            (definition.isPostProcess
                    ? definition.inputExtensions
                    : definition.extensions.map(
                        (extension) => extension.inputSuffix,
                      ))
                .any((input) => input.endsWith('.part')),
      );
  final combiningSuffix =
      combiningSuffixes.length == 1 && !sharedPartConsumedElsewhere
      ? combiningSuffixes.single
      : null;
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
            partDirectiveSuffix: _partDirectiveSuffix(
              converted,
              combiningSuffix,
              runtimeSuffixesById[converted.id] ?? converted.outputSuffixes,
            ),
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

/// Resolves the `part` directive suffix an input must declare before a
/// part-family builder can emit anything, or null when the builder is not a
/// recognized part-family shape or the suffix is ambiguous.
///
/// - `PartBuilder`/`CombiningBuilder` write their single output only when the
///   input declares it, so the suffix is their own output extension.
/// - `SharedPartBuilder` writes its `.part` intermediates unconditionally,
///   but they only reach source outputs through the combining builder, which
///   performs the directive check — so the suffix is the combining output
///   extension. The intermediates must stay uncommitted (cache builds only),
///   and extra non-part outputs disqualify the builder.
///
/// Only plain extension suffixes like `.g.dart` qualify: a remapped
/// `build_extensions` output (a path or `{{}}` capture) changes the `part`
/// URI the input must declare, so the filter stays off for those shapes.
String? _partDirectiveSuffix(
  ManifestDefinition definition,
  String? combiningSuffix,
  List<String> outputs,
) {
  switch (definition.builderType) {
    case 'PartBuilder':
    case 'CombiningBuilder':
      if (outputs.length == 1) {
        return _simplePartDirectiveSuffix(outputs.single);
      }
      return null;
    case 'SharedPartBuilder':
      if (definition.buildTo == 'cache' &&
          combiningSuffix != null &&
          outputs.every((output) => output.endsWith('.part'))) {
        return _simplePartDirectiveSuffix(combiningSuffix);
      }
      return null;
  }
  return null;
}

/// Returns [suffix] when it is a plain extension (`'.g.dart'`) — the only
/// form whose `part` directive is `<input stem><suffix>` — else null.
String? _simplePartDirectiveSuffix(String suffix) {
  if (!suffix.startsWith('.') ||
      !suffix.endsWith('.dart') ||
      suffix.contains('/') ||
      suffix.contains(r'\') ||
      suffix.contains("'") ||
      suffix.contains('"') ||
      suffix.contains('*') ||
      suffix.contains('?') ||
      suffix.contains('{') ||
      suffix.contains('}') ||
      suffix.contains('[') ||
      suffix.contains(']')) {
    return null;
  }
  return suffix;
}

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
    required this.settings,
  });

  final String root;
  final String manifest;
  final String workerEntrypoint;
  final String fingerprint;
  final BuildSettings settings;

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
      settings: BuildSettings.parse(
        (jsonDecode(value('--settings-json') ?? '[]') as List).cast<String>(),
      ),
    );
  }
}
