import 'package:build_config/build_config.dart';
import 'package:build_runner/src/build_plan/build_triggers.dart'
    show AnnotationBuildTrigger, BuildTriggers, ImportBuildTrigger;

import 'model.dart';

final manifestIdentifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _captureGroupRegexp = RegExp(r'\{\{(\w*)\}\}');

bool requiresRuntimeProbe(SelectedBuilder selectedBuilder) {
  final definition = selectedBuilder.definition;
  if (definition.isPostProcess) {
    // ignore: deprecated_member_use
    return definition.postProcess!.inputExtensions == null &&
        _knownPostProcessInputExtensions(definition.postProcess!) == null;
  }
  return definition.normal!.builderFactories.length > 1 ||
      selectedBuilder.options.isNotEmpty;
}

Map<String, List<ManifestTrigger>> normalizedTriggers(
  BuildTriggers buildTriggers,
) {
  final result = <String, List<ManifestTrigger>>{};
  for (final entry in buildTriggers.triggers.entries) {
    final triggers = <ManifestTrigger>[];
    for (final trigger in entry.value) {
      if (trigger is ImportBuildTrigger) {
        triggers.add(ManifestTrigger(kind: 'import', value: trigger.import));
      } else if (trigger is AnnotationBuildTrigger) {
        triggers.add(
          ManifestTrigger(kind: 'annotation', value: trigger.annotation),
        );
      } else {
        throw StateError(
          'Unsupported build trigger type for ${entry.key}: '
          '${trigger.runtimeType}',
        );
      }
    }
    triggers.sort((left, right) {
      final kind = left.kind.compareTo(right.kind);
      return kind != 0 ? kind : left.value.compareTo(right.value);
    });
    result[entry.key] = triggers;
  }
  return result;
}

FactoryMapping? factoryMappingFor(
  DefinitionInfo info,
  List<FactoryMapping>? mappings,
  ManifestDefinition definition,
) {
  if (mappings == null) return null;
  final index = info.isPostProcess
      ? 0
      : info.normal!.builderFactories.indexOf(definition.factory);
  if (index < 0 || index >= mappings.length) return null;
  return mappings[index];
}

Map<String, dynamic>? runtimeMappingJson(
  DefinitionInfo info,
  List<FactoryMapping>? mappings,
  ManifestDefinition definition,
) {
  final mapping = factoryMappingFor(info, mappings, definition);
  if (mapping == null) return null;
  if (info.isPostProcess) {
    final inputExtensions = mapping.inputExtensions;
    if (inputExtensions == null) return null;
    return <String, dynamic>{'input_extensions': inputExtensions};
  }
  final extensions = manifestExtensions(mapping.buildExtensions);
  if (extensions == null) return null;
  return <String, dynamic>{
    'extensions': [for (final extension in extensions) extension.toJson()],
  };
}

List<String> runtimeOutputSuffixes(
  DefinitionInfo info,
  List<FactoryMapping>? mappings,
  ManifestDefinition definition,
) {
  final mapping = factoryMappingFor(info, mappings, definition);
  if (mapping == null || info.isPostProcess) {
    return definition.outputSuffixes;
  }
  final extensions = manifestExtensions(mapping.buildExtensions);
  if (extensions == null) return definition.outputSuffixes;
  return <String>[
    for (final extension in extensions) ...extension.outputSuffixes,
  ];
}

List<ManifestDefinition>? tryConvertDefinition(
  DefinitionInfo info,
  List<FactoryMapping>? probedMappings, {
  required List<ManifestTrigger> triggers,
}) {
  if (info.isPostProcess) {
    final runtimeInputExtensions = probedMappings?.length == 1
        ? probedMappings!.single.inputExtensions
        : null;
    final converted = _tryConvertPostProcessDefinition(
      info.postProcess!,
      runtimeInputExtensions: runtimeInputExtensions,
      triggers: triggers,
    );
    return converted == null ? null : [converted];
  }
  final definition = info.normal!;
  if (!definition.import.startsWith('package:')) return null;
  if (definition.builderFactories.any(
    (factory) => !manifestIdentifierPattern.hasMatch(factory),
  )) {
    return null;
  }
  final requiredInputSuffixes = definition.requiredInputs.toList(
    growable: false,
  );
  if (requiredInputSuffixes.any((suffix) => !_simpleExtension(suffix))) {
    return null;
  }
  final factoryMappings =
      probedMappings ??
      (definition.builderFactories.length == 1
          ? <FactoryMapping>[
              FactoryMapping(
                factory: definition.builderFactories.single,
                buildExtensions: definition.buildExtensions,
              ),
            ]
          : null);
  if (factoryMappings == null ||
      factoryMappings.length != definition.builderFactories.length) {
    return null;
  }

  final converted = <ManifestDefinition>[];
  for (
    var factoryIndex = 0;
    factoryIndex < factoryMappings.length;
    factoryIndex++
  ) {
    final mapping = factoryMappings[factoryIndex];
    if (mapping.factory != definition.builderFactories[factoryIndex]) {
      return null;
    }
    final extensions = manifestExtensions(mapping.buildExtensions);
    if (extensions == null) return null;
    converted.add(
      ManifestDefinition(
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
        isOptional: definition.isOptional,
        requiredInputSuffixes: requiredInputSuffixes,
        triggers: triggers,
      ),
    );
  }
  return converted;
}

List<ManifestExtension>? manifestExtensions(
  Map<String, List<String>> buildExtensions,
) {
  if (buildExtensions.isEmpty) return null;
  final extensions = <ManifestExtension>[];
  for (final entry in buildExtensions.entries) {
    // build_runner gives the empty input key a distinct meaning: it matches
    // every input asset. Keep that meaning explicit in the manifest instead
    // of turning it into a synthetic extension or wildcard.
    final inputIsAll = entry.key.isEmpty;
    final inputIsAnchored = !inputIsAll && entry.key.startsWith('^');
    final input = inputIsAnchored ? entry.key.substring(1) : entry.key;
    final captureNames = _captureGroupNames(input);
    final inputIsCapture = captureNames != null;
    final inputIsExact = inputIsAnchored && !inputIsCapture;
    final inputIsValid = inputIsAll
        ? true
        : inputIsCapture
        ? _simpleCapturePath(input)
        : inputIsExact
        ? _simplePath(input)
        : _simpleExtension(input);
    if (!inputIsValid) {
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
      inputIsAll
          ? (suffix) => !_simpleExtension(suffix)
          : inputIsCapture
          ? (suffix) => !_validCaptureOutput(suffix, captureNames)
          : inputIsExact
          ? (suffix) => !_simplePath(suffix)
          : (suffix) => !_simpleExtension(suffix),
    )) {
      return null;
    }
    extensions.add(
      ManifestExtension(
        inputSuffix: input,
        inputMatch: inputIsAll
            ? 'all'
            : inputIsCapture
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

ManifestDefinition? _tryConvertPostProcessDefinition(
  PostProcessBuilderDefinition definition, {
  List<String>? runtimeInputExtensions,
  required List<ManifestTrigger> triggers,
}) {
  if (triggers.isNotEmpty) return null;
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
  if (!manifestIdentifierPattern.hasMatch(definition.builderFactory))
    return null;
  if (inputExtensions.any((extension) => !_simpleExtension(extension))) {
    return null;
  }

  return ManifestDefinition(
    id: definition.key,
    importUri: definition.import,
    factory: definition.builderFactory,
    kind: 'post_process',
    extensions: const [],
    inputExtensions: inputExtensions,
    buildTo: definition.buildTo == BuildTo.source ? 'source' : 'cache',
    outputIsOptional: true,
    isOptional: false,
    requiredInputSuffixes: const [],
    triggers: const [],
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

PatternSet targetPatterns(
  BuildTarget target,
  PackageInfo package,
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
  return patterns(target.sources);
}

PatternSet patterns(InputSet inputSet) {
  final include = inputSet.include;
  final includePatterns = include == null || include.isEmpty
      ? const ['**']
      : include.toList(growable: false);
  final excludePatterns = inputSet.exclude?.toList(growable: false) ?? const [];
  return _patternSet(includePatterns, excludePatterns);
}

PatternSet _patternSet(List<String> include, List<String> exclude) {
  if (include.any((pattern) => !_supportedPattern(pattern)) ||
      exclude.any((pattern) => !_supportedPattern(pattern))) {
    throw StateError('target sources contain an unsupported glob');
  }
  return PatternSet(include, exclude);
}

bool _supportedPattern(String pattern) =>
    pattern.isNotEmpty &&
    !pattern.contains('\\') &&
    !pattern.contains(RegExp(r'[\[\]{}!]'));
