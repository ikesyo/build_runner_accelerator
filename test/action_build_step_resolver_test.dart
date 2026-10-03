import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/build_step_impl.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_resolver.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_step_resolver.dart';
import 'package:build_runner_accelerator/src/action_build_step_resolver.dart';
import 'package:test/test.dart';

final asset = AssetId('app', 'lib/a.dart');

void main() {
  test(
    'queued transitive query retries after a different policy fails',
    () async {
      final failed = Completer<void>();
      final driver = _Driver()
        ..syncResults.addAll([failed.future, Future<void>.value()]);
      final resolver = ActionBuildStepResolver(driver, _Step());
      final first = resolver.libraryFor(asset);
      final failure = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final queued = resolver.libraryFor(asset, allowSyntaxErrors: true);
      await Future<void>.delayed(Duration.zero);
      expect(driver.syncs, [true]);
      failed.completeError(StateError('first sync failed'));
      await failure;
      expect(await queued, same(driver.library));
      expect(driver.syncs, [true, true]);
      expect(driver.libraryCalls, [true]);
      expect(driver.maxActive, 1);
    },
  );

  test(
    'pending old synchronization cannot satisfy a newer generation',
    () async {
      var generation = 0;
      final old = Completer<void>();
      final driver = _Driver()
        ..syncResults.addAll([old.future, Future<void>.value()]);
      final resolver = ActionBuildStepResolver(
        driver,
        _Step(),
        cacheGeneration: () => generation,
      );
      final first = resolver.libraryFor(asset);
      await Future<void>.delayed(Duration.zero);
      generation++;
      final second = resolver.libraryFor(asset);
      await Future<void>.delayed(Duration.zero);
      old.complete();
      await Future.wait([first, second]);
      expect(driver.syncs, [true, true]);
      expect(driver.maxActive, 1);
    },
  );

  test(
    'library streams retain all action entrypoints after invalidation',
    () async {
      var generation = 0;
      final other = AssetId('app', 'lib/b.dart');
      final driver = _Driver();
      final resolver = ActionBuildStepResolver(
        driver,
        _Step(),
        cacheGeneration: () => generation,
      );
      await resolver.libraryFor(other);
      generation++;
      final libraries = await resolver.libraries.toList();
      expect(libraries, hasLength(2));
      expect(libraries, contains(driver.library));
      expect(libraries, contains(driver.librariesById[other]));
      expect(driver.syncedIds, [other, asset, other]);
    },
  );

  test(
    'nested-action invalidation repeats analysis and driver synchronization',
    () async {
      var generation = 0;
      final driver = _Driver();
      final resolver = ActionBuildStepResolver(
        driver,
        _Step(),
        cacheGeneration: () => generation,
      );
      for (var i = 0; i < 2; i++) {
        await resolver.isLibrary(asset);
        await resolver.compilationUnitFor(asset);
        await resolver.libraryFor(asset);
        generation++;
      }
      expect(driver.isLibraryCalls, 2);
      expect(driver.unitCalls, [false, false]);
      expect(driver.libraryCalls, [false, false]);
      expect(driver.syncs, [false, true, false, true]);
    },
  );

  test(
    'an old failed Future cannot evict pending work after invalidation',
    () async {
      var generation = 0;
      final old = Completer<LibraryElement>();
      final next = Completer<LibraryElement>();
      final driver = _Driver()
        ..libraryResults.addAll([old.future, next.future]);
      final resolver = ActionBuildStepResolver(
        driver,
        _Step(),
        cacheGeneration: () => generation,
      );
      final first = resolver.libraryFor(asset);
      final failure = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      generation++;
      final second = resolver.libraryFor(asset);
      await Future<void>.delayed(Duration.zero);
      old.completeError(StateError('old generation'));
      await failure;
      final third = resolver.libraryFor(asset);
      await Future<void>.delayed(Duration.zero);
      expect(driver.libraryCalls, [false, false]);
      next.complete(driver.library);
      expect(await second, same(driver.library));
      expect(await third, same(driver.library));
    },
  );

  test('transitive synchronization satisfies later shallow requests', () async {
    final driver = _Driver();
    final resolver = ActionBuildStepResolver(driver, _Step());
    await resolver.libraryFor(asset);
    await resolver.isLibrary(asset);
    await resolver.compilationUnitFor(asset);
    expect(driver.syncs, [true]);
  });

  test('different entrypoints still synchronize serially', () async {
    final driver = _Driver()..gate = Completer<void>();
    final resolver = ActionBuildStepResolver(driver, _Step());
    final first = resolver.isLibrary(asset);
    final second = resolver.compilationUnitFor(AssetId('app', 'lib/b.dart'));
    await Future<void>.delayed(Duration.zero);
    expect(driver.syncs, [false]);
    driver.gate!.complete();
    await first;
    await second;
    expect(driver.syncs, [false, false]);
    expect(driver.maxActive, 1);
  });

  test('same calls reduce upstream API and synchronization counts', () async {
    final stockDriver = _Driver();
    final cachedDriver = _Driver();
    for (final resolver in <ReleasableResolver>[
      BuildStepResolver(stockDriver, _Step()),
      ActionBuildStepResolver(cachedDriver, _Step()),
    ]) {
      await resolver.isLibrary(asset);
      await resolver.isLibrary(asset);
      await resolver.compilationUnitFor(asset);
      await resolver.compilationUnitFor(asset);
      await resolver.libraryFor(asset);
      await resolver.libraryFor(asset);
    }
    expect(stockDriver.isLibraryCalls, 2);
    expect(cachedDriver.isLibraryCalls, 1);
    expect(stockDriver.unitCalls, [false, false]);
    expect(cachedDriver.unitCalls, [false]);
    expect(stockDriver.libraryCalls, [false, false]);
    expect(cachedDriver.libraryCalls, [false]);
    expect(stockDriver.syncs, [false, false, false, false, true]);
    expect(cachedDriver.syncs, [false, true]);
  });

  test(
    'pending API work is shared and shallow synchronization spans APIs',
    () async {
      final driver = _Driver()..gate = Completer<void>();
      final step = _Step();
      final resolver = ActionBuildStepResolver(driver, step);
      final calls = [resolver.isLibrary(asset), resolver.isLibrary(asset)];
      final unit = resolver.compilationUnitFor(asset);
      await Future<void>.delayed(Duration.zero);
      expect(driver.syncs, [false]);
      driver.gate!.complete();
      expect(await Future.wait(calls), [true, true]);
      await unit;
      await resolver.isLibrary(asset);
      await resolver.compilationUnitFor(asset);
      expect(driver.isLibraryCalls, 1);
      expect(driver.unitCalls, [false]);
      expect(driver.syncs, [false]);
      expect(step.readChecks, 5);
      expect(driver.maxActive, 1);
    },
  );

  test(
    'syntax policy keys and shallow to transitive upgrade stay distinct',
    () async {
      final driver = _Driver();
      final resolver = ActionBuildStepResolver(driver, _Step());
      await resolver.compilationUnitFor(asset);
      await resolver.compilationUnitFor(asset, allowSyntaxErrors: true);
      await Future.wait([
        resolver.libraryFor(asset),
        resolver.libraryFor(asset),
        resolver.libraryFor(asset, allowSyntaxErrors: true),
      ]);
      await resolver.compilationUnitFor(asset);
      expect(driver.unitCalls, [false, true]);
      expect(driver.libraryCalls, [false, true]);
      expect(driver.syncs, [false, true]);
      expect(driver.maxActive, 1);
    },
  );

  test('failed synchronization and API results can be retried', () async {
    final driver = _Driver()..failSync = true;
    final resolver = ActionBuildStepResolver(driver, _Step());
    await expectLater(resolver.libraryFor(asset), throwsStateError);
    driver.failSync = false;
    driver.failLibrary = true;
    await expectLater(resolver.libraryFor(asset), throwsStateError);
    driver.failLibrary = false;
    await resolver.libraryFor(asset);
    expect(driver.syncs, [true, true]);
    expect(driver.libraryCalls, [false, false]);
  });

  test(
    'visibility is checked on cache hits and missing assets can be retried',
    () async {
      final driver = _Driver();
      final step = _Step()..readable = false;
      final resolver = ActionBuildStepResolver(driver, step);
      expect(await resolver.isLibrary(asset), false);
      await expectLater(
        resolver.compilationUnitFor(asset),
        throwsA(isA<AssetNotFoundException>()),
      );
      step.readable = true;
      expect(await resolver.isLibrary(asset), true);
      step.readable = false;
      expect(await resolver.isLibrary(asset), false);
      expect(driver.isLibraryCalls, 1);
    },
  );

  test(
    'release remains a no-op and separate actions repeat tracking and work',
    () async {
      final driver = _Driver();
      final first = ActionBuildStepResolver(driver, _Step());
      await first.isLibrary(asset);
      first.release();
      await first.isLibrary(asset);
      final second = ActionBuildStepResolver(driver, _Step());
      await second.isLibrary(asset);
      expect(driver.syncs, [false, false]);
      expect(driver.isLibraryCalls, 2);
    },
  );
}

class _Step implements BuildStepImpl {
  bool readable = true;
  int readChecks = 0;
  @override
  AssetId get inputId => asset;
  @override
  Future<bool> canRead(AssetId id, {bool track = true}) async {
    readChecks++;
    return readable;
  }

  @override
  T trackStage<T>(
    String label,
    T Function() action, {
    bool isExternal = false,
  }) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Library implements LibraryElement {
  @override
  bool get isInSdk => false;
  @override
  LibraryFragment get firstFragment => _Fragment();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fragment implements LibraryFragment {
  @override
  List<LibraryImport> get libraryImports => [];
  @override
  List<LibraryExport> get libraryExports => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Driver implements BuildResolver {
  final syncs = <bool>[];
  final syncResults = <Future<void>>[];
  final syncedIds = <AssetId>[];
  final librariesById = <AssetId, LibraryElement>{};
  @override
  Stream<LibraryElement> get sdkLibraries => const Stream.empty();
  final unitCalls = <bool>[];
  final libraryCalls = <bool>[];
  final libraryResults = <Future<LibraryElement>>[];
  int isLibraryCalls = 0;
  int active = 0;
  int maxActive = 0;
  bool failSync = false;
  bool failLibrary = false;
  Completer<void>? gate;
  final unit = parseString(content: 'class A {}').unit;
  final library = _Library();
  @override
  Future<void> updateDriverForEntrypoint({
    required BuildStepImpl buildStep,
    required AssetId entrypoint,
    required bool transitive,
  }) async {
    syncs.add(transitive);
    syncedIds.add(entrypoint);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await gate?.future;
      if (syncResults.isNotEmpty) await syncResults.removeAt(0);
      if (failSync) throw StateError('sync');
    } finally {
      active--;
    }
  }

  @override
  Future<bool> isLibrary(AssetId id) async {
    isLibraryCalls++;
    return true;
  }

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId id, {
    bool allowSyntaxErrors = false,
  }) async {
    unitCalls.add(allowSyntaxErrors);
    return unit;
  }

  @override
  Future<LibraryElement> libraryFor(
    AssetId id, {
    bool allowSyntaxErrors = false,
  }) async {
    libraryCalls.add(allowSyntaxErrors);
    if (libraryResults.isNotEmpty) return libraryResults.removeAt(0);
    if (failLibrary) throw StateError('library');
    return id == asset ? library : librariesById.putIfAbsent(id, _Library.new);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
