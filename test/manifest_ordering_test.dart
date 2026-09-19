import 'package:build_runner_accelerator/src/manifest/ordering.dart';
import 'package:test/test.dart';

class _TargetNode {
  const _TargetNode(this.key, this.dependencies);

  final String key;
  final List<String> dependencies;
}

void main() {
  test('orders target dependencies first and preserves SCC metadata', () {
    final result = orderTargets<_TargetNode>(
      const <_TargetNode>[
        _TargetNode('app:app', <String>['dependency:dependency']),
        _TargetNode('dependency:dependency', <String>[]),
      ],
      keyOf: (target) => target.key,
      dependenciesOf: (target) => target.dependencies,
    );

    expect(result.targets.map((target) => target.key), <String>[
      'dependency:dependency',
      'app:app',
    ]);
    expect(result.componentIndex['dependency:dependency'], 0);
    expect(result.componentIndex['app:app'], 1);
    expect(result.maxComponentSize, 1);
  });

  test('keeps cyclic targets in one stable component', () {
    final result = orderTargets<_TargetNode>(
      const <_TargetNode>[
        _TargetNode('a:a', <String>['b:b']),
        _TargetNode('b:b', <String>['a:a']),
      ],
      keyOf: (target) => target.key,
      dependenciesOf: (target) => target.dependencies,
    );

    expect(result.targets.map((target) => target.key), <String>['a:a', 'b:b']);
    expect(result.componentIndex['a:a'], 0);
    expect(result.componentIndex['b:b'], 0);
    expect(result.memberIndex['a:a'], 0);
    expect(result.memberIndex['b:b'], 1);
    expect(result.maxComponentSize, 2);
  });

  test('reports missing target dependencies', () {
    expect(
      () => orderTargets<_TargetNode>(
        const <_TargetNode>[
          _TargetNode('app:app', <String>['missing:missing']),
        ],
        keyOf: (target) => target.key,
        dependenciesOf: (target) => target.dependencies,
      ),
      throwsStateError,
    );
  });

  test('orders builders by required input outputs', () {
    final definitions = <String, BuilderOrderDefinition>{
      'consumer': const BuilderOrderDefinition(
        requiredInputs: <String>['.json'],
        buildExtensionOutputs: <Iterable<String>>[
          <String>['.json'],
        ],
        runsBefore: <String>[],
      ),
      'producer': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[
          <String>['.json'],
        ],
        runsBefore: <String>[],
      ),
    };

    expect(
      orderBuilders(<String>['consumer', 'producer'], definitions, const {}),
      <String>['producer', 'consumer'],
    );
  });

  test('orders builders by definition runsBefore', () {
    final definitions = <String, BuilderOrderDefinition>{
      'early': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[],
        runsBefore: <String>['late'],
      ),
      'late': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[],
        runsBefore: <String>[],
      ),
    };

    expect(
      orderBuilders(
        <String>['early', 'late'],
        definitions,
        const <String, Iterable<String>>{},
      ),
      <String>['early', 'late'],
    );
  });

  test('orders builders by global runsBefore', () {
    final definitions = <String, BuilderOrderDefinition>{
      'early': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[],
        runsBefore: <String>[],
      ),
      'late': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[],
        runsBefore: <String>[],
      ),
    };

    expect(
      orderBuilders(
        <String>['early', 'late'],
        definitions,
        const <String, Iterable<String>>{
          'early': <String>['late'],
        },
      ),
      <String>['early', 'late'],
    );
  });

  test('reports builder ordering cycles', () {
    final definitions = <String, BuilderOrderDefinition>{
      'a': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[],
        runsBefore: <String>['b'],
      ),
      'b': const BuilderOrderDefinition(
        requiredInputs: <String>[],
        buildExtensionOutputs: <Iterable<String>>[],
        runsBefore: <String>['a'],
      ),
    };

    expect(
      () => orderBuilders(
        <String>['a', 'b'],
        definitions,
        const <String, Iterable<String>>{},
      ),
      throwsStateError,
    );
  });
}
