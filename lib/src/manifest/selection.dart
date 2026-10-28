import 'dart:io';

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
  Iterable<PackageInfo>? workspaceOutputPackages,
  bool release = false,
  Map<String, Map<String, dynamic>> overrides = const {},
}) {
  // In a workspace build, auto-application is scoped to packages which
  // participate in a common output package's dependency closure.
  Set<String> closureOf(PackageInfo package) {
    final visited = <String>{};
    final pending = <PackageInfo>[package];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (visited.add(current.name)) pending.addAll(current.dependencies);
    }
    return visited;
  }

  final workspaceClosures = workspaceOutputPackages == null
      ? null
      : {
          for (final package in workspaceOutputPackages)
            package.name: closureOf(package),
        };
  final outputNames = workspaceClosures?.keys.toSet();

  bool isOutput(PackageInfo package) =>
      outputNames?.contains(package.name) ?? package.name == rootPackageName;

  final selected = <String, SelectedBuilder>{};
  final disabled = <String>{};
  for (final key in overrides.keys) {
    if (!definitions.containsKey(key)) {
      stderr.writeln('Ignoring options overrides for unknown builder `$key`.');
    }
  }

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
    // build_runner hides source outputs on non-output packages. Its phase
    // filter therefore does not schedule those applications, even when a
    // dependency package's own build.yaml mentions the builder.
    if (!definition.isPostProcess &&
        !isOutput(target.package) &&
        definition.normal!.buildTo == BuildTo.source) {
      return;
    }
    if (!definition.isPostProcess &&
        !isOutput(target.package) &&
        definition.normal!.appliesBuilders.any(
          (applied) => definitions[applied]?.normal?.buildTo == BuildTo.source,
        )) {
      // A hidden cache builder which applies a visible source builder is also
      // filtered out by build_runner for non-output packages.
      return;
    }
    final selectedKey = _selectedKey(target.target.key, key);
    if (!explicit && disabled.contains(selectedKey)) return;
    if (!explicit && selected.containsKey(selectedKey)) return;

    final global = rootConfig.globalOptions[key];
    final mergedOptions = <String, dynamic>{
      ...definition.defaults.options,
      ...(release
          ? definition.defaults.releaseOptions
          : definition.defaults.devOptions),
    };
    if (options != null) mergedOptions.addAll(options);
    if (global != null) {
      mergedOptions.addAll(global.options);
      mergedOptions.addAll(release ? global.releaseOptions : global.devOptions);
    }
    mergedOptions.addAll(overrides[key] ?? const {});
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
      if (!entry.value.isEnabled) {
        disabled.add(_selectedKey(target.target.key, entry.key));
      }
    }

    for (final entry in target.target.builders.entries) {
      if (!entry.value.isEnabled) {
        continue;
      }
      select(
        entry.key,
        target: target,
        generateFor: entry.value.generateFor,
        options: <String, dynamic>{
          ...entry.value.options,
          ...(release ? entry.value.releaseOptions : entry.value.devOptions),
        },
        explicit: true,
      );
    }

    if (target.target.autoApplyBuilders) {
      for (final definition in definitions.values) {
        final selectedKey = _selectedKey(target.target.key, definition.key);
        if (selected.containsKey(selectedKey)) continue;
        if (!definition.isPostProcess &&
            _autoAppliesToTarget(
              definition.normal!,
              target.package,
              isOutput: workspaceClosures == null
                  ? target.package.isRoot
                  : isOutput(target.package),
              workspaceClosures: workspaceClosures,
            )) {
          select(definition.key, target: target, explicit: false);
        }
      }
    }
  }
  return selected;
}

bool _autoAppliesToTarget(
  BuilderDefinition definition,
  PackageInfo target, {
  required bool isOutput,
  required Map<String, Set<String>>? workspaceClosures,
}) {
  switch (definition.autoApply) {
    case AutoApply.rootPackage:
      return isOutput &&
          (workspaceClosures == null ||
              (workspaceClosures[target.name]?.contains(definition.package) ??
                  false));
    case AutoApply.allPackages:
      return workspaceClosures == null ||
          workspaceClosures.values.any(
            (closure) =>
                closure.contains(target.name) &&
                closure.contains(definition.package),
          );
    case AutoApply.dependents:
      return target.dependencies.any(
        (dependency) => dependency.name == definition.package,
      );
    case AutoApply.none:
      return false;
  }
}

String _selectedKey(String target, String builder) => '$target|$builder';
