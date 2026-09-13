import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _manifestVersion = 6;
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

  final rootConfig = configs[packageGraph.root.name];
  if (rootConfig == null) {
    throw StateError('Root package config was not loaded');
  }
  final targets = <_TargetInfo>[];
  for (final package in packageGraph.allPackages.values) {
    if (package.name == r'$sdk') continue;
    final config = configs[package.name];
    if (config == null) {
      throw StateError('Package config is unavailable: ' + package.name);
    }
    for (final target in config.buildTargets.values) {
      targets.add(
        _TargetInfo(
          package: package,
          target: target,
          sources: _targetPatterns(target, package, config),
        ),
      );
    }
  }
  final targetOrder = _orderTargets(targets);
  final orderedTargets = targetOrder.targets;
  final rootTargetKey = packageGraph.root.name + ':' + packageGraph.root.name;
  final rootTarget = orderedTargets
      .where((target) => target.target.key == rootTargetKey)
      .firstOrNull;
  if (rootTarget == null) {
    throw StateError('Root target is unavailable: ' + rootTargetKey);
  }
  final definitions = <String, _DefinitionInfo>{};
  for (final config in configs.values) {
    for (final definition in config.builderDefinitions.values) {
      // Match build_runner's build-script rule: relative imports from
      // dependency packages cannot be imported by the root worker script.
      if (!definition.import.startsWith('package:') &&
          definition.package != packageGraph.root.name) {
        continue;
      }
      definitions[definition.key] = _DefinitionInfo.normal(definition);
    }
    for (final definition in config.postProcessBuilderDefinitions.values) {
      // Post-process builders use the same package:builder key namespace as
      // normal builders, but are resolved through a different factory type.
      if (!definition.import.startsWith('package:') &&
          definition.package != packageGraph.root.name) {
        continue;
      }
      definitions[definition.key] = _DefinitionInfo.postProcess(definition);
    }
  }

  final selected = <String, _SelectedBuilder>{};
  final disabled = <String>{};

  void select(
    String key, {
    required _TargetInfo target,
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
    selected[selectedKey] = _SelectedBuilder(
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
    );
    return;
  }

  // A build.yaml definition may expose more than one factory. build_runner
  // creates one build phase per factory, and each factory is allowed to
  // advertise a different buildExtensions map. Keep those factories as
  // separate manifest definitions so the Rust planner can make the same
  // per-factory decisions about inputs and outputs.
  final selectedDefinitionKeys = selected.values
      .map((builder) => builder.definition.key)
      .toSet();
  final probeDefinitions = definitions.values
      .where((info) {
        if (!selectedDefinitionKeys.contains(info.key)) return false;
        if (info.isPostProcess) {
          // Post-process builders in older build_config versions do not carry
          // their input extensions in build.yaml. Probe the runtime builder in
          // that case (source_gen and drift both use this shape).
          // ignore: deprecated_member_use
          return info.postProcess!.inputExtensions == null &&
              _knownPostProcessInputExtensions(info.postProcess!) == null;
        }
        return info.normal!.builderFactories.length > 1;
      })
      .toList(growable: false);
  final probedMappings = await _probeFactoryMappings(root, probeDefinitions);
  final compatibleDefinitions = <String, List<_ManifestDefinition>>{};
  for (final info in definitions.values) {
    final converted = _tryConvertDefinition(info, probedMappings[info.key]);
    if (converted != null && converted.isNotEmpty) {
      compatibleDefinitions[info.key] = converted;
    }
  }

  for (final selectedBuilder in selected.values) {
    if (selectedBuilder.options.containsKey('build_extensions')) {
      if (!selectedBuilder.definition.isPostProcess) {
        throw StateError(
          'Builder options that override build_extensions are not supported: ' +
              selectedBuilder.definition.key,
        );
      }
    }
    if (!compatibleDefinitions.containsKey(selectedBuilder.definition.key)) {
      throw StateError(
        'Builder is outside the dynamic worker subset: ' +
            selectedBuilder.definition.key,
      );
    }
  }

  final activeEntries = <Map<String, dynamic>>[];
  final selectedDefinitions = <String>{};
  final allOutputSuffixes = <String>{
    for (final definitions in compatibleDefinitions.values)
      for (final definition in definitions) ...definition.outputSuffixes,
  };
  final normalDefinitions = <String, _DefinitionInfo>{
    for (final entry in definitions.entries)
      if (!entry.value.isPostProcess) entry.key: entry.value,
  };
  final globallyOrderedKeys = _orderBuilders(
    normalDefinitions.keys.toList(),
    normalDefinitions,
    rootConfig.globalOptions,
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
    final orderedKeys = <String>[...normalKeys, ...postProcessKeys];
    for (final key in orderedKeys) {
      final selectedBuilder = targetBuilders.firstWhere(
        (builder) => builder.definition.key == key,
      );
      final patterns = _patterns(selectedBuilder.generateFor);
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
                      ...candidate.outputSuffixes,
              }.toList()..sort());
        activeEntries.add(
          converted.toJson(
            generateFor: patterns.include,
            generateForExclude: patterns.exclude,
            targetSources: target.sources.include,
            targetSourcesExclude: target.sources.exclude,
            options: _jsonMap(selectedBuilder.options),
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

  final allCompatibleDefinitions = <_ManifestDefinition>[
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

  final catalogEntries = <_CatalogEntry>[
    for (final definition in allCompatibleDefinitions)
      if (selectedDefinitions.contains(definition.id))
        _catalogEntry(definition),
  ];

  await _writeManifest(
    options,
    builders: activeEntries,
    definitions: definitionEntries,
    workerSource: _workerSource(catalogEntries),
  );
}

/// The manifest generator only needs the package graph's names, paths, root
/// marker, and direct dependencies. Keep this small graph local to the worker
/// package so manifest generation does not depend on the retired
/// `build_runner_core` package.
class _PackageGraph {
  _PackageGraph({required this.root, required this.allPackages});

  final _PackageInfo root;
  final Map<String, _PackageInfo> allPackages;
}

class _PackageInfo {
  _PackageInfo({required this.name, required this.path, required this.isRoot});

  final String name;
  final String path;
  final bool isRoot;
  final List<_PackageInfo> dependencies = <_PackageInfo>[];
}

Future<_PackageGraph> _loadPackageGraph(String packagePath) async {
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

  final packages = <String, _PackageInfo>{};
  final orderedPackages = packageConfig.packages.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  for (final package in orderedPackages) {
    packages[package.name] = _PackageInfo(
      name: package.name,
      path: package.root.toFilePath(),
      isRoot: package.name == rootName,
    );
  }

  _PackageInfo packageNode(String name, {String? parent}) {
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

  return _PackageGraph(root: rootNode, allPackages: packages);
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

bool _autoAppliesToTarget(BuilderDefinition definition, _PackageInfo target) {
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

_PatternSet _targetPatterns(
  BuildTarget target,
  _PackageInfo package,
  BuildConfig config,
) {
  final include = target.sources.include;
  if (include == null || include.isEmpty) {
    final defaults = package.isRoot
        ? const ['**']
        : <String>[
            'CHANGELOG*',
            'lib/**',
            'bin/**',
            'LICENSE*',
            'pubspec.yaml',
            'README*',
            ...config.additionalPublicAssets,
          ];
    return _patternSet(
      defaults,
      target.sources.exclude?.toList(growable: false) ?? const [],
    );
  }
  return _patterns(target.sources);
}

_TargetOrder _orderTargets(List<_TargetInfo> targets) {
  final byKey = <String, _TargetInfo>{
    for (final target in targets) target.target.key: target,
  };
  final indexes = <String, int>{};
  final lowLinks = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final components = <List<_TargetInfo>>[];
  var nextIndex = 0;

  void visit(String key) {
    if (indexes.containsKey(key)) return;
    final target = byKey[key];
    if (target == null) {
      throw StateError('Target dependency is unavailable: ' + key);
    }

    indexes[key] = nextIndex;
    lowLinks[key] = nextIndex;
    nextIndex++;
    stack.add(key);
    onStack.add(key);

    for (final dependency in target.target.dependencies) {
      if (!byKey.containsKey(dependency)) {
        throw StateError('Target dependency is unavailable: ' + dependency);
      }
      if (!indexes.containsKey(dependency)) {
        visit(dependency);
        lowLinks[key] = _min(lowLinks[key]!, lowLinks[dependency]!);
      } else if (onStack.contains(dependency)) {
        lowLinks[key] = _min(lowLinks[key]!, indexes[dependency]!);
      }
    }

    if (lowLinks[key] == indexes[key]) {
      final component = <_TargetInfo>[];
      String member;
      do {
        member = stack.removeLast();
        onStack.remove(member);
        component.add(byKey[member]!);
      } while (member != key);
      components.add(component);
    }
  }

  // build_runner's graph helper starts with the last graph node. Reversing
  // the stable PackageGraph/BuildConfig insertion order preserves its
  // dependency-first SCC order and member order without a builder-specific
  // path.
  for (final target in targets.reversed) {
    visit(target.target.key);
  }

  final ordered = <_TargetInfo>[];
  final componentIndex = <String, int>{};
  final memberIndex = <String, int>{};
  var maxComponentSize = 1;
  for (var component = 0; component < components.length; component++) {
    final members = components[component];
    maxComponentSize = _max(maxComponentSize, members.length);
    for (var member = 0; member < members.length; member++) {
      final key = members[member].target.key;
      componentIndex[key] = component;
      memberIndex[key] = member;
    }
    ordered.addAll(members);
  }
  return _TargetOrder(ordered, componentIndex, memberIndex, maxComponentSize);
}

int _min(int left, int right) => left < right ? left : right;

int _max(int left, int right) => left > right ? left : right;

List<String> _orderBuilders(
  List<String> keys,
  Map<String, _DefinitionInfo> definitions,
  Map<String, GlobalBuilderConfig> globalOptions,
) {
  final sorted = keys.toList()..sort();
  final outgoing = <String, Set<String>>{
    for (final key in sorted) key: <String>{},
  };
  final indegree = <String, int>{for (final key in sorted) key: 0};

  void addEdge(String before, String after) {
    if (!outgoing.containsKey(before) ||
        !outgoing.containsKey(after) ||
        before == after ||
        !outgoing[before]!.add(after)) {
      return;
    }
    indegree[after] = indegree[after]! + 1;
  }

  for (final parentKey in sorted) {
    final parent = definitions[parentKey]!.normal!;
    for (final childKey in sorted) {
      if (parentKey == childKey) continue;
      final child = definitions[childKey]!.normal!;
      final childOutputs = child.buildExtensions.values.expand(
        (value) => value,
      );
      final childProvidesRequiredInput = parent.requiredInputs.any(
        (required) => childOutputs.any((output) => output.endsWith(required)),
      );
      if (childProvidesRequiredInput) {
        addEdge(childKey, parentKey);
      }
      if (parent.runsBefore.contains(childKey)) {
        addEdge(parentKey, childKey);
      }
      if (parent.appliesBuilders.contains(childKey) &&
          !childProvidesRequiredInput) {
        // Applied builders consume outputs produced by their parent phase.
        // An existing required-input edge takes precedence when an applied
        // builder prepares inputs for its parent.
        addEdge(parentKey, childKey);
      }
      final childGlobal = globalOptions[childKey];
      if (childGlobal != null && childGlobal.runsBefore.contains(parentKey)) {
        addEdge(childKey, parentKey);
      }
    }
  }

  final result = <String>[];
  final remaining = <String>{
    for (final key in sorted)
      if (indegree[key] == 0) key,
  };
  while (remaining.isNotEmpty) {
    final key = remaining.toList()..sort();
    final next = key.first;
    remaining.remove(next);
    result.add(next);
    for (final child in outgoing[next]!) {
      indegree[child] = indegree[child]! - 1;
      if (indegree[child] == 0) remaining.add(child);
    }
  }
  if (result.length != sorted.length) {
    throw StateError('Builder ordering contains a cycle');
  }
  return result;
}

Future<Map<String, List<_FactoryMapping>>> _probeFactoryMappings(
  String root,
  Iterable<_DefinitionInfo> definitions,
) async {
  final probeDefinitions = definitions.toList(growable: false);
  if (probeDefinitions.isEmpty) return const {};
  final packageConfig = _findPackageConfigPath(root);
  if (packageConfig == null) return const {};

  Directory? temporary;
  try {
    temporary = await Directory.systemTemp.createTemp(
      'build-runner-accelerator-factory-probe-',
    );
    final probeFile = File(p.join(temporary.path, 'probe.dart'));
    final resultFile = File(p.join(temporary.path, 'result.json'));
    await probeFile.writeAsString(_factoryProbeSource(probeDefinitions));
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

    final probed = <String, List<_FactoryMapping>>{};
    for (final entry in decoded.entries) {
      final info = probeDefinitions
          .where((candidate) => candidate.key == entry.key)
          .firstOrNull;
      if (info == null || entry.value is! List) continue;
      final expectedFactories = info.isPostProcess
          ? <String>[info.postProcess!.builderFactory]
          : info.normal!.builderFactories;
      final rawMappings = entry.value as List;
      if (rawMappings.length != expectedFactories.length) continue;
      final mappings = <_FactoryMapping>[];
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
          _FactoryMapping(
            factory: raw['factory'] as String,
            buildExtensions: buildExtensions,
            inputExtensions: inputExtensions,
          ),
        );
      }
      if (valid) probed[entry.key as String] = mappings;
    }
    return probed;
  } catch (_) {
    // A probe is an optimization boundary, not a reason to fail the build.
    // The caller will leave any definition without a trustworthy probe in
    // the normal Dart fallback path.
    return const {};
  } finally {
    if (temporary != null && temporary.existsSync()) {
      await temporary.delete(recursive: true);
    }
  }
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

String _factoryProbeSource(Iterable<_DefinitionInfo> definitions) {
  // These values are later emitted into executable Dart source. Keep the
  // probe boundary as strict as the manifest converter: only package imports
  // and identifier-shaped factory names may cross it. In particular, a raw
  // factory value must never reach `$importPrefix.$factory` below.
  final safeDefinitions = definitions
      .where((definition) {
        if (definition.isPostProcess) {
          final postProcess = definition.postProcess!;
          return postProcess.import.startsWith('package:') &&
              _identifier.hasMatch(postProcess.builderFactory);
        }
        final normal = definition.normal!;
        return normal.import.startsWith('package:') &&
            normal.builderFactories.every(_identifier.hasMatch);
      })
      .toList(growable: false);
  final sorted = safeDefinitions.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final imports = <String, String>{};
  for (final definition in sorted) {
    final importUri = definition.isPostProcess
        ? definition.postProcess!.import
        : definition.normal!.import;
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
  for (final definition in sorted) {
    final importUri = definition.isPostProcess
        ? definition.postProcess!.import
        : definition.normal!.import;
    final importPrefix = imports[importUri]!;
    output
      ..writeln('    try {')
      ..writeln(
        '      result[${_dartSourceString(definition.key)}] = <dynamic>[',
      );
    if (definition.isPostProcess) {
      final factory = definition.postProcess!.builderFactory;
      output
        ..writeln('      <String, dynamic>{')
        ..writeln('        \'factory\': ${_dartSourceString(factory)},')
        ..writeln("        'build_extensions': <String, List<String>>{},")
        ..writeln(
          '        \'input_extensions\': _postProcessInputExtensions('
          '$importPrefix.$factory(BuilderOptions(<String, dynamic>{}))),',
        )
        ..writeln('      },');
    } else {
      for (final factory in definition.normal!.builderFactories) {
        output
          ..writeln('      <String, dynamic>{')
          ..writeln('        \'factory\': ${_dartSourceString(factory)},')
          ..writeln("        'build_extensions': _builderBuildExtensions(")
          ..writeln(
            '          $importPrefix.$factory('
            'BuilderOptions(<String, dynamic>{}, isRoot: true)),',
          )
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

List<_ManifestDefinition>? _tryConvertDefinition(
  _DefinitionInfo info,
  List<_FactoryMapping>? probedMappings,
) {
  if (info.isPostProcess) {
    final runtimeInputExtensions = probedMappings?.length == 1
        ? probedMappings!.single.inputExtensions
        : null;
    final converted = _tryConvertPostProcessDefinition(
      info.postProcess!,
      runtimeInputExtensions: runtimeInputExtensions,
    );
    return converted == null ? null : [converted];
  }
  final definition = info.normal!;
  if (!definition.import.startsWith('package:')) return null;
  if (definition.builderFactories.any(
    (factory) => !_identifier.hasMatch(factory),
  )) {
    return null;
  }
  if (definition.requiredInputs.length > 1) return null;
  if (definition.requiredInputs.isNotEmpty &&
      !_simpleExtension(definition.requiredInputs.single)) {
    return null;
  }
  // Optional builders require build_runner's demand-driven phase semantics,
  // which the Rust action planner does not model yet.
  if (definition.isOptional) return null;

  final factoryMappings = definition.builderFactories.length == 1
      ? <_FactoryMapping>[
          _FactoryMapping(
            factory: definition.builderFactories.single,
            buildExtensions: definition.buildExtensions,
          ),
        ]
      : probedMappings;
  if (factoryMappings == null ||
      factoryMappings.length != definition.builderFactories.length) {
    return null;
  }

  final converted = <_ManifestDefinition>[];
  for (
    var factoryIndex = 0;
    factoryIndex < factoryMappings.length;
    factoryIndex++
  ) {
    final mapping = factoryMappings[factoryIndex];
    if (mapping.factory != definition.builderFactories[factoryIndex]) {
      return null;
    }
    final extensions = _manifestExtensions(mapping.buildExtensions);
    if (extensions == null) return null;
    converted.add(
      _ManifestDefinition(
        id: _manifestFactoryId(
          definition.key,
          factoryIndex,
          definition.builderFactories.length,
        ),
        importUri: definition.import,
        factory: mapping.factory,
        kind: 'normal',
        extensions: extensions,
        inputExtensions: const [],
        buildTo: definition.buildTo == BuildTo.source ? 'source' : 'cache',
        outputIsOptional: false,
        requiredInputSuffix: definition.requiredInputs.isEmpty
            ? null
            : definition.requiredInputs.single,
      ),
    );
  }
  return converted;
}

List<_ManifestExtension>? _manifestExtensions(
  Map<String, List<String>> buildExtensions,
) {
  if (buildExtensions.isEmpty) return null;
  final extensions = <_ManifestExtension>[];
  for (final entry in buildExtensions.entries) {
    final inputIsAnchored = entry.key.startsWith('^');
    final input = inputIsAnchored ? entry.key.substring(1) : entry.key;
    final captureNames = _captureGroupNames(input);
    final inputIsCapture = captureNames != null;
    final inputIsExact = inputIsAnchored && !inputIsCapture;
    if ((inputIsCapture
            ? !_simpleCapturePath(input)
            : inputIsExact
            ? !_simplePath(input)
            : !_simpleExtension(input)) ||
        entry.value.isEmpty) {
      return null;
    }
    final outputSuffixes = entry.value
        .map(
          inputIsCapture || inputIsExact
              ? _normalizePathOutput
              : _normalizeOutputSuffix,
        )
        .toList(growable: false);
    if (outputSuffixes.any(
      inputIsCapture
          ? (suffix) => !_validCaptureOutput(suffix, captureNames)
          : inputIsExact
          ? (suffix) => !_simplePath(suffix)
          : (suffix) => !_simpleExtension(suffix),
    )) {
      return null;
    }
    extensions.add(
      _ManifestExtension(
        inputSuffix: input,
        inputMatch: inputIsCapture
            ? 'capture'
            : inputIsExact
            ? 'exact'
            : 'suffix',
        inputAnchored: inputIsAnchored,
        outputSuffixes: outputSuffixes,
      ),
    );
  }
  return extensions;
}

_ManifestDefinition? _tryConvertPostProcessDefinition(
  PostProcessBuilderDefinition definition, {
  List<String>? runtimeInputExtensions,
}) {
  // build_config 1.2 exposes this field as deprecated while retaining it for
  // the v1 post-process manifest shape.
  // ignore: deprecated_member_use
  final configuredInputExtensions = definition.inputExtensions?.toList(
    growable: false,
  );
  // Current source_gen deliberately leaves this legacy config field unset and
  // supplies the extension from the runtime FileDeletingBuilder instead.
  // Keep the known built-in cleanup builder in the converted subset so current
  // json_serializable builds can preserve source_gen's .g.part cleanup.
  final inputExtensions =
      configuredInputExtensions ??
      runtimeInputExtensions ??
      _knownPostProcessInputExtensions(definition);
  if (inputExtensions == null || inputExtensions.isEmpty) return null;
  if (!definition.import.startsWith('package:')) return null;
  if (!_identifier.hasMatch(definition.builderFactory)) return null;
  if (inputExtensions.any((extension) => !_simpleExtension(extension))) {
    return null;
  }

  return _ManifestDefinition(
    id: definition.key,
    importUri: definition.import,
    factory: definition.builderFactory,
    kind: 'post_process',
    extensions: const [],
    inputExtensions: inputExtensions,
    buildTo: 'cache',
    outputIsOptional: true,
    requiredInputSuffix: null,
  );
}

List<String>? _knownPostProcessInputExtensions(
  PostProcessBuilderDefinition definition,
) {
  // These package-specific cases are intentional compatibility fallbacks:
  // build_config leaves inputExtensions unset for these legacy cleanup builders,
  // while runtime probing adds a measurable startup cost during manifest
  // generation. Keep the fallback narrow and covered by compatibility fixtures;
  // unknown post-process builders still use the generic runtime probe. If a
  // dependency changes its cleanup inputs, update this mapping or restore probing.

  if (definition.key == 'source_gen:part_cleanup' &&
      definition.import == 'package:source_gen/builder.dart' &&
      definition.builderFactory == 'partCleanup') {
    return const <String>['.g.part'];
  }
  if (definition.key == 'drift_dev:cleanup' &&
      definition.import == 'package:drift_dev/integrations/build.dart' &&
      definition.builderFactory == 'driftCleanup') {
    return const <String>[
      '.temp.dart',
      '.drift_prep.json',
      '.drift_module.json',
    ];
  }
  return null;
}

String _manifestFactoryId(String definitionKey, int factoryIndex, int count) =>
    count == 1 ? definitionKey : '$definitionKey#factory$factoryIndex';

class _FactoryMapping {
  _FactoryMapping({
    required this.factory,
    required this.buildExtensions,
    this.inputExtensions,
  });

  final String factory;
  final Map<String, List<String>> buildExtensions;
  final List<String>? inputExtensions;
}

bool _simpleExtension(String value) =>
    value.startsWith('.') &&
    value.length > 1 &&
    !value.contains('{{}}') &&
    !value.contains(RegExp(r'[*?\[\]{}]'));

List<String>? _captureGroupNames(String value) {
  final matches = _captureGroupRegexp.allMatches(value).toList();
  if (matches.isEmpty) return null;
  final names = matches.map((match) => match.group(1)!).toList();
  return names.toSet().length == names.length ? names : null;
}

bool _simpleCapturePath(String value) {
  if (_captureGroupNames(value) == null) return false;
  final normalized = value.replaceAll(_captureGroupRegexp, 'capture');
  return _simplePath(normalized);
}

bool _validCaptureOutput(String value, List<String> names) {
  if (!_simpleCapturePath(value)) return false;
  final used = <String>{};
  for (final match in _captureGroupRegexp.allMatches(value)) {
    final name = match.group(1)!;
    if (!names.contains(name) || !used.add(name)) return false;
  }
  return used.length == names.length;
}

bool _simplePath(String value) =>
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !value.contains('\\') &&
    !value.contains('|') &&
    !value.contains('..') &&
    !value.contains(RegExp(r'[*?\[\]{}]'));

String _normalizeOutputSuffix(String configured) {
  if (_simpleExtension(configured)) return configured;
  // Some build_config definitions expose an extension without the leading
  // dot even though the builder protocol treats it as a suffix. This is a
  // shape normalization, independent of any builder package.
  final normalized = '.$configured';
  return _simpleExtension(normalized) ? normalized : configured;
}

String _normalizePathOutput(String configured) => configured;

_PatternSet _patterns(InputSet inputSet) {
  final include = inputSet.include;
  final includePatterns = include == null || include.isEmpty
      ? const ['**']
      : include.toList(growable: false);
  final excludePatterns = inputSet.exclude?.toList(growable: false) ?? const [];
  return _patternSet(includePatterns, excludePatterns);
}

_PatternSet _patternSet(List<String> include, List<String> exclude) {
  if (include.any((pattern) => !_supportedPattern(pattern)) ||
      exclude.any((pattern) => !_supportedPattern(pattern))) {
    throw StateError('target sources contain an unsupported glob');
  }
  return _PatternSet(include, exclude);
}

bool _supportedPattern(String pattern) =>
    pattern.isNotEmpty &&
    !pattern.contains('\\') &&
    !pattern.contains(RegExp(r'[\[\]{}!]'));

Map<String, dynamic> _jsonMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

String _workerSource(Iterable<_CatalogEntry> entries) {
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

_CatalogEntry _catalogEntry(_ManifestDefinition definition) => _CatalogEntry(
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
}) async {
  final manifestFile = File(options.manifest);
  final workerFile = File(options.workerEntrypoint);
  await manifestFile.parent.create(recursive: true);
  await workerFile.parent.create(recursive: true);
  await _writeAtomically(workerFile, workerSource);
  final manifest = <String, dynamic>{
    'version': _manifestVersion,
    'fingerprint': options.fingerprint,
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

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _captureGroupRegexp = RegExp(r'\{\{(\w*)\}\}');

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

class _DefinitionInfo {
  _DefinitionInfo.normal(this.normal) : postProcess = null;
  _DefinitionInfo.postProcess(this.postProcess) : normal = null;

  final BuilderDefinition? normal;
  final PostProcessBuilderDefinition? postProcess;

  bool get isPostProcess => postProcess != null;
  String get key => normal?.key ?? postProcess!.key;
  TargetBuilderConfigDefaults get defaults =>
      normal?.defaults ?? postProcess!.defaults;
  Iterable<String> get appliesBuilders => normal?.appliesBuilders ?? const [];
}

class _TargetInfo {
  _TargetInfo({
    required this.package,
    required this.target,
    required this.sources,
  });

  final _PackageInfo package;
  final BuildTarget target;
  final _PatternSet sources;
}

class _TargetOrder {
  const _TargetOrder(
    this.targets,
    this.componentIndex,
    this.memberIndex,
    this.maxComponentSize,
  );

  final List<_TargetInfo> targets;
  final Map<String, int> componentIndex;
  final Map<String, int> memberIndex;
  final int maxComponentSize;
}

class _SelectedBuilder {
  _SelectedBuilder(
    this.definition,
    this.target,
    this.generateFor,
    this.options,
  );

  final _DefinitionInfo definition;
  final _TargetInfo target;
  final InputSet generateFor;
  final Map<String, dynamic> options;
}

class _PatternSet {
  const _PatternSet(this.include, this.exclude);

  final List<String> include;
  final List<String> exclude;
}

class _ManifestExtension {
  const _ManifestExtension({
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

class _ManifestDefinition {
  _ManifestDefinition({
    required this.id,
    required this.importUri,
    required this.factory,
    required this.kind,
    required this.extensions,
    required this.inputExtensions,
    required this.buildTo,
    required this.outputIsOptional,
    required this.requiredInputSuffix,
  });

  final String id;
  final String importUri;
  final String factory;
  final String kind;
  final List<_ManifestExtension> extensions;
  final List<String> inputExtensions;
  final String buildTo;
  final bool outputIsOptional;
  final String? requiredInputSuffix;

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
    'output_is_optional': outputIsOptional,
    'required_input_suffix': requiredInputSuffix,
    'excluded_input_suffixes': excludedInputSuffixes,
    'generate_for': generateFor,
    'generate_for_exclude': generateForExclude,
    'target_sources': targetSources,
    'target_sources_exclude': targetSourcesExclude,
    'options': options,
  };
}

class _CatalogEntry {
  _CatalogEntry({
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
