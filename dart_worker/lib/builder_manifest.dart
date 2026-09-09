import 'dart:convert';
import 'dart:io';

import 'package:build_config/build_config.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _manifestVersion = 6;

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

  final compatibleDefinitions = <String, _ManifestDefinition>{};
  for (final info in definitions.values) {
    final converted = _tryConvertDefinition(info);
    if (converted != null) {
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
    for (final key in compatibleDefinitions.keys)
      ...compatibleDefinitions[key]!.outputSuffixes,
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
  final builderOrder = <String, int>{
    for (var index = 0; index < globallyOrderedKeys.length; index++)
      globallyOrderedKeys[index]: index,
  };
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
    final outputSuffixes = <String>{
      for (final key in normalKeys)
        ...compatibleDefinitions[key]!.outputSuffixes,
    };
    for (final key in orderedKeys) {
      final selectedBuilder = targetBuilders.firstWhere(
        (builder) => builder.definition.key == key,
      );
      final converted = compatibleDefinitions[key]!;
      final patterns = _patterns(selectedBuilder.generateFor);
      selectedDefinitions.add(key);
      activeEntries.add(
        converted.toJson(
          generateFor: patterns.include,
          generateForExclude: patterns.exclude,
          targetSources: target.sources.include,
          targetSourcesExclude: target.sources.exclude,
          options: _jsonMap(selectedBuilder.options),
          phase: converted.isPostProcess
              ? 0
              : builderOrder[key]! * targetOrder.maxComponentSize + memberIndex,
          target: target.target.key,
          package: target.package.name,
          targetOrder: componentIndex,
          excludedInputSuffixes: outputSuffixes.toList()..sort(),
        ),
      );
    }
  }

  final definitionEntries = <Map<String, dynamic>>[
    for (final key in compatibleDefinitions.keys.toList()..sort())
      compatibleDefinitions[key]!.toJson(
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
    for (final key in selectedDefinitions)
      _catalogEntry(compatibleDefinitions[key]!),
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
      _depsFromYaml(pubspec)
          .map((name) => packageNode(name, parent: package.name)),
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
      if (parent.requiredInputs.any(
        (required) => childOutputs.any((output) => output.endsWith(required)),
      )) {
        addEdge(childKey, parentKey);
      }
      if (parent.runsBefore.contains(childKey)) {
        addEdge(parentKey, childKey);
      }
      if (parent.appliesBuilders.contains(childKey)) {
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

_ManifestDefinition? _tryConvertDefinition(_DefinitionInfo info) {
  if (info.isPostProcess) {
    return _tryConvertPostProcessDefinition(info.postProcess!);
  }
  final definition = info.normal!;
  if (definition.builderFactories.length != 1) return null;
  if (!definition.import.startsWith('package:')) return null;
  if (!_identifier.hasMatch(definition.builderFactories.single)) return null;
  if (definition.buildExtensions.isEmpty) return null;

  final extensions = <_ManifestExtension>[];
  for (final entry in definition.buildExtensions.entries) {
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
  if (definition.requiredInputs.length > 1) return null;
  if (definition.requiredInputs.isNotEmpty &&
      !_simpleExtension(definition.requiredInputs.single)) {
    return null;
  }
  // Optional builders require build_runner's demand-driven phase semantics,
  // which the Rust action planner does not model yet.
  if (definition.isOptional) return null;

  return _ManifestDefinition(
    id: definition.key,
    importUri: definition.import,
    factory: definition.builderFactories.single,
    kind: 'normal',
    extensions: extensions,
    inputExtensions: const [],
    buildTo: definition.buildTo == BuildTo.source ? 'source' : 'cache',
    outputIsOptional: false,
    requiredInputSuffix: definition.requiredInputs.isEmpty
        ? null
        : definition.requiredInputs.single,
  );
}

_ManifestDefinition? _tryConvertPostProcessDefinition(
  PostProcessBuilderDefinition definition,
) {
  // build_config 1.2 exposes this field as deprecated while retaining it for
  // the v1 post-process manifest shape.
  // ignore: deprecated_member_use
  final configuredInputExtensions = definition.inputExtensions?.toList(
    growable: false,
  );
  // Current source_gen deliberately leaves this legacy config field unset and
  // supplies the extension from the runtime FileDeletingBuilder instead.
  // Keep the known built-in cleanup builder in the dynamic subset so current
  // json_serializable builds can preserve source_gen's .g.part cleanup.
  final inputExtensions = configuredInputExtensions == null
      ? definition.key == 'source_gen:part_cleanup' &&
                definition.import == 'package:source_gen/builder.dart' &&
                definition.builderFactory == 'partCleanup'
            ? const <String>['.g.part']
            : null
      : configuredInputExtensions;
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
    ..writeln("import 'package:fast_build_runner_worker/worker.dart';");
  for (final entry in imports.entries) {
    output.writeln(
      'import ' + _dartString(entry.key) + ' as ' + entry.value + ';',
    );
  }
  output
    ..writeln()
    ..writeln('Future<void> main() => runWorker(')
    ..writeln('  catalog: <String, BuilderFactory>{');
  for (final entry in sorted.where((entry) => !entry.isPostProcess)) {
    output.writeln(
      '    ' +
          _dartString(entry.id) +
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
          _dartString(entry.id) +
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

String _dartString(String value) => jsonEncode(value);

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
