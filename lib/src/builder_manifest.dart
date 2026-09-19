import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_triggers.dart'
    show BuildTriggers;
import 'package:built_collection/built_collection.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'manifest/mapping.dart';
import 'manifest/model.dart';
import 'manifest/ordering.dart';

const _manifestVersion = 8;
const _factoryProbeTimeout = Duration(seconds: 30);
const _factoryProbeKillGracePeriod = Duration(seconds: 1);

Future<void> generateBuilderManifest(List<String> arguments) async {
  final options = _Arguments.parse(arguments);
  final root = Directory(options.root).absolute.path;
  final packageGraph = await _loadPackageGraph(root);
  final configs = <String, BuildConfig>{};

  for (final package in packageGraph.allPackages.values) {
    if (package.name == r'$sdk') continue;
    configs[package.name] = await BuildConfig.fromBuildConfigDir(
      package.name,
      package.dependencies.map((dependency) => dependency.name),
      package.path,
    );
  }

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
  final normalizedTriggerMap = normalizedTriggers(buildTriggers);
  final triggerDigest = buildTriggers.digest.toString();

  final rootConfig = configs[packageGraph.root.name];
  if (rootConfig == null) {
    throw StateError('Root package config was not loaded');
  }
  final targets = <TargetInfo>[];
  for (final package in packageGraph.allPackages.values) {
    if (package.name == r'$sdk') continue;
    final config = configs[package.name];
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
  for (final config in configs.values) {
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

  final selected = <String, SelectedBuilder>{};
  final disabled = <String>{};

  void select(
    String key, {
    required TargetInfo target,
    InputSet? generateFor,
    Map<String, dynamic>? options,
    required bool explicit,
  }) {
    final definition = definitions[key];
    // A dependency's build.yaml may contain configuration for a builder
    // supplied only by that package's development dependencies. build_runner
    // ignores such entries when the builder application is absent from the
    // root package graph.
    if (definition == null) return;
    // build_runner hides source outputs on non-root packages. Its phase
    // filter therefore does not schedule those applications, even when a
    // dependency package's own build.yaml mentions the builder.
    if (!definition.isPostProcess &&
        target.package.name != packageGraph.root.name &&
        definition.normal!.buildTo == BuildTo.source) {
      return;
    }
    if (!definition.isPostProcess &&
        target.package.name != packageGraph.root.name &&
        definition.normal!.appliesBuilders.any(
          (applied) => definitions[applied]?.normal?.buildTo == BuildTo.source,
        )) {
      // A hidden cache builder which applies a visible source builder is also
      // filtered out by build_runner for non-root packages.
      return;
    }
    final selectedKey = _selectedKey(target.target.key, key);
    if (!explicit && disabled.contains(selectedKey)) return;
    if (!explicit && selected.containsKey(selectedKey)) return;

    final global = rootConfig.globalOptions[key];
    final mergedOptions = <String, dynamic>{
      ...definition.defaults.options,
      ...definition.defaults.devOptions,
    };
    if (options != null) mergedOptions.addAll(options);
    if (global != null) {
      mergedOptions.addAll(global.options);
      mergedOptions.addAll(global.devOptions);
    }
    selected[selectedKey] = SelectedBuilder(
      definition,
      target,
      generateFor ?? definition.defaults.generateFor,
      mergedOptions,
    );

    for (final applied in definition.appliesBuilders) {
      if (definitions.containsKey(applied)) {
        select(
          applied,
          target: target,
          generateFor: generateFor,
          options: const {},
          explicit: false,
        );
      }
    }
  }

  for (final target in orderedTargets) {
    for (final entry in target.target.builders.entries) {
      final selectedKey = _selectedKey(target.target.key, entry.key);
      if (!entry.value.isEnabled) {
        disabled.add(selectedKey);
        continue;
      }
      select(
        entry.key,
        target: target,
        generateFor: entry.value.generateFor,
        options: <String, dynamic>{
          ...entry.value.options,
          ...entry.value.devOptions,
        },
        explicit: true,
      );
    }

    if (target.target.autoApplyBuilders) {
      for (final definition in definitions.values) {
        final selectedKey = _selectedKey(target.target.key, definition.key);
        if (selected.containsKey(selectedKey)) continue;
        if (!definition.isPostProcess &&
            _autoAppliesToTarget(definition.normal!, target.package)) {
          select(definition.key, target: target, explicit: false);
        }
      }
    }
  }

  if (selected.isEmpty) {
    await _writeManifest(
      options,
      builders: const [],
      definitions: const [],
      workerSource: _workerSource(const []),
      triggerDigest: triggerDigest,
    );
    return;
  }

  // build.yaml remains the ordering source, while the
  // instantiated Builder is the expected-output source. Probe selected
  // multi-factory and option-dependent applications so target-local mapping
  // overrides remain lossless and package-specific Rust branches are unnecessary.
  final probeRequests = selected.entries
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
  final probedMappings = await _probeFactoryMappings(root, probeRequests);
  final canonicalMappings = <String, List<FactoryMapping>>{};
  for (final request in probeRequests) {
    final mappings = probedMappings[request.id];
    if (mappings != null) {
      canonicalMappings.putIfAbsent(request.definition.key, () => mappings);
    }
  }
  final compatibleDefinitions = <String, List<ManifestDefinition>>{};
  for (final info in definitions.values) {
    final converted = tryConvertDefinition(
      info,
      canonicalMappings[info.key],
      triggers: normalizedTriggerMap[info.key] ?? const [],
    );
    if (converted != null && converted.isNotEmpty) {
      compatibleDefinitions[info.key] = converted;
    }
  }

  for (final entry in selected.entries) {
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

  final activeEntries = <Map<String, dynamic>>[];
  final selectedDefinitions = <String>{};
  final allOutputSuffixes = <String>{
    for (final definitions in compatibleDefinitions.values)
      for (final definition in definitions) ...definition.outputSuffixes,
  };
  final normalDefinitions = <String, DefinitionInfo>{
    for (final entry in definitions.entries)
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
    for (final entry in rootConfig.globalOptions.entries)
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
    for (final definition in compatibleDefinitions[key] ?? const []) {
      if (definition.isPostProcess) continue;
      builderOrder[definition.id] = nextBuilderOrder++;
    }
  }
  for (final target in orderedTargets) {
    final componentIndex = targetOrder.componentIndex[target.target.key]!;
    final memberIndex = targetOrder.memberIndex[target.target.key]!;
    final targetBuilders = selected.values
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
          probedMappings[_selectedKey(
            target.target.key,
            candidateBuilder.definition.key,
          )];
      for (final candidate
          in compatibleDefinitions[candidateBuilder.definition.key] ??
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
      for (final converted in compatibleDefinitions[key]!) {
        selectedDefinitions.add(converted.id);
        final excludedInputSuffixes = converted.isPostProcess
            ? <String>[]
            : (<String>{
                for (final candidateKey in normalKeys)
                  for (final candidate in compatibleDefinitions[candidateKey]!)
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
              probedMappings[_selectedKey(target.target.key, key)],
              converted,
            ),
            phase: converted.isPostProcess
                ? 0
                : builderOrder[converted.id]! * targetOrder.maxComponentSize +
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
    for (final definitions in compatibleDefinitions.values) ...definitions,
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

  await _writeManifest(
    options,
    builders: activeEntries,
    definitions: definitionEntries,
    workerSource: _workerSource(catalogEntries),
    triggerDigest: triggerDigest,
  );
}

/// The manifest generator only needs the package graph's names, paths, root
/// marker, and direct dependencies. Keep this small graph local to the worker
/// package so manifest generation does not depend on the retired
/// `build_runner_core` package.
Future<PackageGraph> _loadPackageGraph(String packagePath) async {
  final root = p.canonicalize(packagePath);
  final rootPubspec = _pubspecForPath(root);
  final rootName = rootPubspec['name'];
  if (rootName is! String || rootName.isEmpty) {
    throw StateError('The current package has no name in pubspec.yaml.');
  }

  var packageConfigRoot = root;
  PackageConfig? packageConfig;
  while (true) {
    packageConfig = await findPackageConfig(
      Directory(packageConfigRoot),
      recurse: false,
    );
    if (packageConfig != null) break;
    final parent = p.dirname(packageConfigRoot);
    if (parent == packageConfigRoot) break;
    packageConfigRoot = parent;
  }
  if (packageConfig == null) {
    throw StateError('Unable to find package_config.json for $root.');
  }

  final packages = <String, PackageInfo>{};
  final orderedPackages = packageConfig.packages.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  for (final package in orderedPackages) {
    packages[package.name] = PackageInfo(
      name: package.name,
      path: package.root.toFilePath(),
      isRoot: package.name == rootName,
    );
  }

  PackageInfo packageNode(String name, {String? parent}) {
    final node = packages[name];
    if (node == null) {
      throw StateError(
        'Dependency $name ${parent == null ? '' : 'of $parent '}not '
        'present; run `dart pub get` first.',
      );
    }
    return node;
  }

  final rootNode = packageNode(rootName);
  rootNode.dependencies.addAll(
    _depsFromYaml(
      rootPubspec,
      includeDevDependencies: true,
    ).map((name) => packageNode(name, parent: rootName)),
  );
  for (final package in orderedPackages.where((p) => p.name != rootName)) {
    final pubspec = _pubspecForPath(package.root.toFilePath());
    packages[package.name]!.dependencies.addAll(
      _depsFromYaml(
        pubspec,
      ).map((name) => packageNode(name, parent: package.name)),
    );
  }

  return PackageGraph(root: rootNode, allPackages: packages);
}

YamlMap _pubspecForPath(String packagePath) {
  final path = p.join(packagePath, 'pubspec.yaml');
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('Unable to find $path.');
  }
  final value = loadYaml(file.readAsStringSync());
  if (value is! YamlMap) {
    throw StateError('$path does not contain a YAML map.');
  }
  return value;
}

List<String> _depsFromYaml(
  YamlMap pubspec, {
  bool includeDevDependencies = false,
}) {
  final dependencies = <String>{
    ..._yamlStringKeys(pubspec['dependencies'] as Map?),
    if (includeDevDependencies)
      ..._yamlStringKeys(pubspec['dev_dependencies'] as Map?),
  };
  return dependencies.toList()..sort();
}

Iterable<String> _yamlStringKeys(Map? values) =>
    values == null ? const <String>[] : values.keys.cast<String>();

bool _autoAppliesToTarget(BuilderDefinition definition, PackageInfo target) {
  switch (definition.autoApply) {
    case AutoApply.rootPackage:
      return target.isRoot;
    case AutoApply.allPackages:
      return true;
    case AutoApply.dependents:
      return target.dependencies.any(
        (dependency) => dependency.name == definition.package,
      );
    case AutoApply.none:
      return false;
  }
}

String _selectedKey(String target, String builder) => '$target|$builder';

Future<Map<String, List<FactoryMapping>>> _probeFactoryMappings(
  String root,
  Iterable<FactoryProbeRequest> requests,
) async {
  final probeRequests = requests.toList(growable: false);
  if (probeRequests.isEmpty) return const {};
  final packageConfig = _findPackageConfigPath(root);
  if (packageConfig == null) return const {};

  Directory? temporary;
  try {
    temporary = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-factory-probe-',
    );
    final probeFile = File(p.join(temporary.path, 'probe.dart'));
    final resultFile = File(p.join(temporary.path, 'result.json'));
    await probeFile.writeAsString(_factoryProbeSource(probeRequests));
    // Process.start is required here so a misbehaving factory probe can be
    // terminated instead of blocking manifest generation indefinitely.
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=$packageConfig',
      probeFile.path,
      resultFile.path,
    ], workingDirectory: root);
    // Consume both pipes while the probe runs; otherwise a verbose probe can
    // block on a full child-process pipe before the timeout is reached.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(_factoryProbeTimeout);
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(_factoryProbeKillGracePeriod);
      } on TimeoutException {
        // The child may be outside our control; the probe still must not
        // keep manifest generation blocked.
      }
      return const {};
    }
    if (exitCode != 0 || !resultFile.existsSync()) return const {};
    final decoded = jsonDecode(await resultFile.readAsString());
    if (decoded is! Map) return const {};

    final probed = <String, List<FactoryMapping>>{};
    for (final entry in decoded.entries) {
      final request = probeRequests
          .where((candidate) => candidate.id == entry.key)
          .firstOrNull;
      if (request == null || entry.value is! List) continue;
      final expectedFactories = request.definition.isPostProcess
          ? <String>[request.definition.postProcess!.builderFactory]
          : request.definition.normal!.builderFactories;
      final rawMappings = entry.value as List;
      if (rawMappings.length != expectedFactories.length) continue;
      final mappings = <FactoryMapping>[];
      var valid = true;
      for (var index = 0; index < rawMappings.length; index++) {
        final raw = rawMappings[index];
        if (raw is! Map || raw['factory'] != expectedFactories[index]) {
          valid = false;
          break;
        }
        final rawBuildExtensions = raw['build_extensions'];
        if (rawBuildExtensions is! Map) {
          valid = false;
          break;
        }
        final buildExtensions = <String, List<String>>{};
        for (final extension in rawBuildExtensions.entries) {
          final input = extension.key;
          final outputs = extension.value;
          if (input is! String ||
              outputs is! List ||
              outputs.any((output) => output is! String)) {
            valid = false;
            break;
          }
          buildExtensions[input] = outputs.cast<String>();
        }
        if (!valid) break;
        final rawInputExtensions = raw['input_extensions'];
        final inputExtensions = rawInputExtensions == null
            ? null
            : rawInputExtensions is List &&
                  rawInputExtensions.every((input) => input is String)
            ? rawInputExtensions.cast<String>()
            : null;
        if (raw.containsKey('input_extensions') && inputExtensions == null) {
          valid = false;
          break;
        }
        mappings.add(
          FactoryMapping(
            factory: raw['factory'] as String,
            buildExtensions: buildExtensions,
            inputExtensions: inputExtensions,
          ),
        );
      }
      if (valid) probed[request.id] = mappings;
    }
    return probed;
  } catch (_) {
    // A probe is an optimization boundary, not a reason to fail the build.
    // The caller treats a missing selected request as an unsupported manifest
    // and falls back to stock Dart build_runner in auto mode.
    return const {};
  } finally {
    if (temporary != null && temporary.existsSync()) {
      await temporary.delete(recursive: true);
    }
  }
}

String _factoryProbeSource(Iterable<FactoryProbeRequest> requests) {
  // These values are later emitted into executable Dart source. Keep the
  // probe boundary as strict as the manifest converter: only package imports
  // and identifier-shaped factory names may cross it. In particular, a raw
  // factory value must never reach the importPrefix.factory expression below.
  final safeRequests = requests
      .where((request) {
        if (request.definition.isPostProcess) {
          final postProcess = request.definition.postProcess!;
          return postProcess.import.startsWith('package:') &&
              manifestIdentifierPattern.hasMatch(postProcess.builderFactory);
        }
        final normal = request.definition.normal!;
        return normal.import.startsWith('package:') &&
            normal.builderFactories.every(manifestIdentifierPattern.hasMatch);
      })
      .toList(growable: false);
  final sorted = safeRequests.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final imports = <String, String>{};
  for (final request in sorted) {
    final importUri = request.definition.isPostProcess
        ? request.definition.postProcess!.import
        : request.definition.normal!.import;
    imports.putIfAbsent(
      importUri,
      () => 'builderImport' + imports.length.toString(),
    );
  }

  final output = StringBuffer()
    ..writeln('import \'dart:convert\';')
    ..writeln('import \'dart:io\';')
    ..writeln(
      "import 'package:build/build.dart' show Builder, BuilderOptions, PostProcessBuilder;",
    );
  for (final entry in imports.entries) {
    output.writeln(
      'import ' + _dartSourceString(entry.key) + ' as ' + entry.value + ';',
    );
  }
  output
    ..writeln()
    ..writeln('void main(List<String> args) {')
    ..writeln('  if (args.length != 1) {')
    ..writeln('    exitCode = 64;')
    ..writeln('    return;')
    ..writeln('  }')
    ..writeln('  final result = <String, dynamic>{};');
  for (final request in sorted) {
    final importUri = request.definition.isPostProcess
        ? request.definition.postProcess!.import
        : request.definition.normal!.import;
    final importPrefix = imports[importUri]!;
    final optionsLiteral = _dartSourceString(jsonEncode(request.options));
    final builderOptions =
        'BuilderOptions('
        'Map<String, dynamic>.from(jsonDecode($optionsLiteral) as Map), '
        'isRoot: ${request.isRoot})';
    output
      ..writeln('    try {')
      ..writeln('      result[${_dartSourceString(request.id)}] = <dynamic>[');
    if (request.definition.isPostProcess) {
      final factory = request.definition.postProcess!.builderFactory;
      output
        ..writeln('      <String, dynamic>{')
        ..writeln('        \'factory\': ${_dartSourceString(factory)},')
        ..writeln("        'build_extensions': <String, List<String>>{},")
        ..writeln(
          '        \'input_extensions\': _postProcessInputExtensions('
          '$importPrefix.$factory($builderOptions)),',
        )
        ..writeln('      },');
    } else {
      for (final factory in request.definition.normal!.builderFactories) {
        output
          ..writeln('      <String, dynamic>{')
          ..writeln('        \'factory\': ${_dartSourceString(factory)},')
          ..writeln("        'build_extensions': _builderBuildExtensions(")
          ..writeln('          $importPrefix.$factory($builderOptions),')
          ..writeln('        ),')
          ..writeln('      },');
      }
    }
    output
      ..writeln('      ];')
      ..writeln('    } catch (_) {}');
  }
  output
    ..writeln('  File(args.single).writeAsStringSync(jsonEncode(result));')
    ..writeln('}')
    ..writeln()
    ..writeln(
      'Map<String, List<String>> _builderBuildExtensions(Builder builder) => '
      '<String, List<String>>{'
      'for (final entry in builder.buildExtensions.entries) '
      'entry.key: entry.value.toList(growable: false),'
      '};',
    )
    ..writeln()
    ..writeln(
      'List<String> _postProcessInputExtensions(PostProcessBuilder builder) '
      '=> builder.inputExtensions.toList(growable: false);',
    );
  return output.toString();
}

String? _findPackageConfigPath(String root) {
  var packageConfigRoot = p.canonicalize(root);
  while (true) {
    final candidate = p.join(
      packageConfigRoot,
      '.dart_tool',
      'package_config.json',
    );
    if (File(candidate).existsSync()) return candidate;
    final parent = p.dirname(packageConfigRoot);
    if (parent == packageConfigRoot) return null;
    packageConfigRoot = parent;
  }
}

Map<String, dynamic> _jsonMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

String _workerSource(Iterable<CatalogEntry> entries) {
  final sorted = entries.toList()
    ..sort((left, right) => left.id.compareTo(right.id));
  final imports = <String, String>{};
  for (final entry in sorted) {
    imports.putIfAbsent(
      entry.importUri,
      () => 'builderImport' + imports.length.toString(),
    );
  }

  final output = StringBuffer()
    ..writeln(
      "import 'package:build/build.dart' show BuilderFactory, PostProcessBuilderFactory;",
    )
    ..writeln("import 'package:build_runner_accelerator/src/worker.dart';");
  for (final entry in imports.entries) {
    output.writeln(
      'import ' + _dartSourceString(entry.key) + ' as ' + entry.value + ';',
    );
  }
  output
    ..writeln()
    ..writeln('Future<void> main() => runWorker(')
    ..writeln('  catalog: <String, BuilderFactory>{');
  for (final entry in sorted.where((entry) => !entry.isPostProcess)) {
    output.writeln(
      '    ' +
          _dartSourceString(entry.id) +
          ': ' +
          imports[entry.importUri]! +
          '.' +
          entry.factory +
          ',',
    );
  }
  output
    ..writeln('  },')
    ..writeln('  postProcessCatalog: <String, PostProcessBuilderFactory>{');
  for (final entry in sorted.where((entry) => entry.isPostProcess)) {
    output.writeln(
      '    ' +
          _dartSourceString(entry.id) +
          ': ' +
          imports[entry.importUri]! +
          '.' +
          entry.factory +
          ',',
    );
  }
  output
    ..writeln('  },')
    ..writeln(');');
  return output.toString();
}

String _dartSourceString(String value) {
  final output = StringBuffer("'");
  for (final codeUnit in value.codeUnits) {
    if (codeUnit == 0x5c || codeUnit == 0x27 || codeUnit == 0x24) {
      output
        ..write('\\')
        ..writeCharCode(codeUnit);
    } else if (codeUnit < 0x20 ||
        codeUnit == 0x7f ||
        codeUnit == 0x2028 ||
        codeUnit == 0x2029) {
      output
        ..write('\\u')
        ..write(codeUnit.toRadixString(16).padLeft(4, '0'));
    } else {
      output.writeCharCode(codeUnit);
    }
  }
  output.write("'");
  return output.toString();
}

CatalogEntry _catalogEntry(ManifestDefinition definition) => CatalogEntry(
  id: definition.id,
  importUri: definition.importUri,
  factory: definition.factory,
  isPostProcess: definition.isPostProcess,
);

Future<void> _writeManifest(
  _Arguments options, {
  required Iterable<Map<String, dynamic>> builders,
  required Iterable<Map<String, dynamic>> definitions,
  required String workerSource,
  required String triggerDigest,
}) async {
  final manifestFile = File(options.manifest);
  final workerFile = File(options.workerEntrypoint);
  await manifestFile.parent.create(recursive: true);
  await workerFile.parent.create(recursive: true);
  await _writeAtomically(workerFile, workerSource);
  final manifest = <String, dynamic>{
    'version': _manifestVersion,
    'fingerprint': options.fingerprint,
    'trigger_digest': triggerDigest,
    'worker_entrypoint': workerFile.absolute.path,
    'builders': builders.toList(),
    'definitions': definitions.toList(),
  };
  await _writeAtomically(manifestFile, jsonEncode(manifest) + '\n');
}

Future<void> _writeAtomically(File file, String contents) async {
  final temporary = File(file.path + '.tmp.' + pid.toString());
  await temporary.writeAsString(contents);
  await temporary.rename(file.path);
}

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
