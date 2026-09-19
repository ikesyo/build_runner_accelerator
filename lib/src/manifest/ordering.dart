import 'model.dart';

/// Orders graph nodes with the same stable SCC semantics used by the
/// manifest generator. The callbacks keep this algorithm independent from
/// build_config, which makes the ordering rules directly testable.
TargetOrder<T> orderTargets<T>(
  List<T> targets, {
  required String Function(T) keyOf,
  required Iterable<String> Function(T) dependenciesOf,
}) {
  final byKey = <String, T>{
    for (final target in targets) keyOf(target): target,
  };
  final indexes = <String, int>{};
  final lowLinks = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final components = <List<T>>[];
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

    for (final dependency in dependenciesOf(target)) {
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
      final component = <T>[];
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
    visit(keyOf(target));
  }

  final ordered = <T>[];
  final componentIndex = <String, int>{};
  final memberIndex = <String, int>{};
  var maxComponentSize = 1;
  for (var component = 0; component < components.length; component++) {
    final members = components[component];
    maxComponentSize = _max(maxComponentSize, members.length);
    for (var member = 0; member < members.length; member++) {
      final key = keyOf(members[member]);
      componentIndex[key] = component;
      memberIndex[key] = member;
    }
    ordered.addAll(members);
  }
  return TargetOrder(ordered, componentIndex, memberIndex, maxComponentSize);
}

class BuilderOrderDefinition {
  const BuilderOrderDefinition({
    required this.requiredInputs,
    required this.buildExtensionOutputs,
    required this.runsBefore,
  });

  final Iterable<String> requiredInputs;
  final Iterable<Iterable<String>> buildExtensionOutputs;
  final Iterable<String> runsBefore;
}

List<String> orderBuilders(
  List<String> keys,
  Map<String, BuilderOrderDefinition> definitions,
  Map<String, Iterable<String>> globalRunsBefore,
) {
  // Keep this graph isomorphic to build_runner's findBuilderOrder. The
  // upstream helper models an edge from a builder to the builder it depends
  // on, then reverses the topological result. In particular, applies_builders
  // controls application, not ordering; a required_inputs or runs_before edge
  // is needed to establish a phase boundary.
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
    final parent = definitions[parentKey]!;
    for (final childKey in sorted) {
      if (parentKey == childKey) continue;
      final child = definitions[childKey]!;
      final childOutputs = child.buildExtensionOutputs.expand((value) => value);
      final childProvidesRequiredInput = parent.requiredInputs.any(
        (required) => childOutputs.any((output) => output.endsWith(required)),
      );
      if (childProvidesRequiredInput) {
        addEdge(parentKey, childKey);
      }
      if (child.runsBefore.contains(parentKey)) {
        addEdge(parentKey, childKey);
      }
      final childGlobal = globalRunsBefore[childKey];
      if (childGlobal != null && childGlobal.contains(parentKey)) {
        addEdge(parentKey, childKey);
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
  return result.reversed.toList(growable: false);
}

int _min(int left, int right) => left < right ? left : right;

int _max(int left, int right) => left > right ? left : right;
