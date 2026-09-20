import 'package:build_config/build_config.dart';

import 'model.dart';

/// Selects the builder applications for each ordered target.
///
/// This is kept separate from manifest I/O so the precedence rules can be
/// tested without loading a package graph or starting a runtime probe.
Map<String, SelectedBuilder> selectApplications({
  required String rootPackageName,
  required BuildConfig rootConfig,
  required List<TargetInfo> orderedTargets,
  required Map<String, DefinitionInfo> definitions,
}) {
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
        target.package.name != rootPackageName &&
        definition.normal!.buildTo == BuildTo.source) {
      return;
    }
    if (!definition.isPostProcess &&
        target.package.name != rootPackageName &&
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
  return selected;
}

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
