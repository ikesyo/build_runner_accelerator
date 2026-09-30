import 'package:build_config/build_config.dart';
import 'model.dart';
import 'ordering.dart';
import 'patterns.dart';
import 'package_graph.dart';
import 'selection.dart';
import 'emitter.dart';

// This library deliberately does not import Analyzer or runtime mappings.
// The authoritative generator and the early helper share these exact rules.
Future<void> generateWorkerCatalog(String root, String workerEntrypoint) async {
  final graph = await loadPackageGraph(root);
  final configs = await loadBuildConfigs(graph);
  final resolved = resolveBuilderCatalog(graph, configs);
  final selected = selectApplications(
    rootPackageName: resolved.rootPackageName,
    rootConfig: resolved.rootConfig,
    orderedTargets: resolved.orderedTargets,
    definitions: resolved.definitions,
  );
  if (selected.isNotEmpty) {
    await emitWorkerEntrypoint(workerEntrypoint, earlyCatalogEntries(selected));
  }
}

class ResolvedCatalog {
  const ResolvedCatalog({
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

ResolvedCatalog resolveBuilderCatalog(
  PackageGraph packageGraph,
  Map<String, BuildConfig> configs,
) {
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
  return ResolvedCatalog(
    rootPackageName: packageGraph.root.name,
    rootConfig: rootConfig,
    orderedTargets: orderedTargets,
    targetOrder: targetOrder,
    definitions: definitions,
  );
}

/// Includes every selected factory before runtime probing and conversion.
/// The full generator validates the resulting catalog before any build runs.
List<CatalogEntry> earlyCatalogEntries(
  Map<String, SelectedBuilder> selectedBuilders,
) {
  final seen = <String>{};
  final entries = <CatalogEntry>[];
  for (final selected in selectedBuilders.values) {
    final definition = selected.definition;
    if (definition.isPostProcess) {
      final postProcess = definition.postProcess!;
      if (seen.add(definition.key)) {
        entries.add(
          CatalogEntry(
            id: definition.key,
            importUri: postProcess.import,
            factory: postProcess.builderFactory,
            isPostProcess: true,
          ),
        );
      }
    } else {
      final normal = definition.normal!;
      for (var index = 0; index < normal.builderFactories.length; index++) {
        final id = manifestFactoryId(
          normal.key,
          index,
          normal.builderFactories.length,
        );
        if (seen.add(id)) {
          entries.add(
            CatalogEntry(
              id: id,
              importUri: normal.import,
              factory: normal.builderFactories[index],
              isPostProcess: false,
            ),
          );
        }
      }
    }
  }
  return entries;
}

String manifestFactoryId(String definitionKey, int factoryIndex, int count) =>
    count == 1 ? definitionKey : '$definitionKey#factory$factoryIndex';
