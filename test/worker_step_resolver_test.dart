import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/analysis_startup_gate.dart';
import 'package:build_runner_accelerator/src/worker_step_resolver.dart';
import 'package:test/test.dart';

class _Resolver implements ReleasableResolver {
  int releases = 0;
  int libraryCalls = 0;
  Future<void> Function()? linking;
  Stream<LibraryElement> libraryStream = const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<AstNode?> astNodeFor(
    Fragment fragment, {
    bool resolve = false,
  }) async => null;

  @override
  Stream<LibraryElement> get libraries => libraryStream;

  @override
  Future<LibraryElement?> findLibraryByName(String name) async => null;

  @override
  Future<bool> isLibrary(AssetId asset) async => false;

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId asset, {
    bool allowSyntaxErrors = false,
  }) async => throw StateError('syntax');

  @override
  Future<LibraryElement> libraryFor(
    AssetId asset, {
    bool allowSyntaxErrors = false,
  }) async {
    libraryCalls++;
    await linking?.call();
    throw StateError('linking');
  }

  @override
  void release() => releases++;
}

class _Fragment implements Fragment {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Library implements LibraryElement {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory dir;
  late AnalysisStartupGate gate;
  late _Resolver delegate;
  late WorkerStepResolver resolver;
  var checks = 0;
  var warm = false;
  final asset = AssetId('app', 'lib/model.dart');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('worker-step-resolver-');
    checks = 0;
    warm = false;
    gate = AnalysisStartupGate(
      '${dir.path}/startup.lock',
      isWarm: () {
        checks++;
        return warm;
      },
    );
    delegate = _Resolver();
    resolver = WorkerStepResolver(
      delegate,
      startupGate: gate,
      timingEnabled: false,
    );
  });
  tearDown(() {
    resolver.release();
    dir.deleteSync(recursive: true);
  });

  test('syntax-only methods do not acquire the startup gate', () async {
    expect(await resolver.isLibrary(asset), isFalse);
    expect(await resolver.astNodeFor(_Fragment()), isNull);
    await expectLater(resolver.compilationUnitFor(asset), throwsStateError);
    expect(checks, 0);
    expect(File(gate.lockPath).existsSync(), isFalse);
  });

  for (final method in ['libraries', 'findLibraryByName', 'astNodeFor']) {
    test('$method acquires the gate before linking', () async {
      switch (method) {
        case 'libraries':
          await resolver.libraries.drain<void>();
        case 'findLibraryByName':
          await resolver.findLibraryByName('model');
        case 'astNodeFor':
          await resolver.astNodeFor(_Fragment(), resolve: true);
      }
      expect(checks, 2);
    });
  }

  test('failed linking releases ownership before the step ends', () async {
    await expectLater(resolver.libraryFor(asset), throwsStateError);
    expect(checks, 2);
    expect(delegate.libraryCalls, 1);
    resolver.release();
    expect(delegate.releases, 1);
    // No linked entries were published, so another action takes ownership.
    final next = await gate.acquire();
    expect(next, isNotNull);
    next!.release();
    expect(checks, 4);
  });

  test('concurrent linking calls share one lease', () async {
    final started = Completer<void>();
    final finishFirst = Completer<void>();
    final finishSecond = Completer<void>();
    delegate.linking = () {
      if (delegate.libraryCalls == 1) return finishFirst.future;
      started.complete();
      return finishSecond.future;
    };
    final pending = Future.wait([
      expectLater(resolver.libraryFor(asset), throwsStateError),
      expectLater(resolver.libraryFor(asset), throwsStateError),
    ]);
    await started.future;
    expect(checks, 1);
    finishFirst.complete();
    await Future<void>.delayed(Duration.zero);
    // The second concurrent analysis still owns the same lease.
    expect(checks, 1);
    warm = true;
    finishSecond.complete();
    await pending;
    expect(checks, 2);
    expect(delegate.libraryCalls, 2);
    expect(await gate.acquire(), isNull);
  });

  test('published analysis opens the gate before builder release', () async {
    delegate.linking = () async {
      warm = true;
    };
    await Future.wait([
      expectLater(resolver.libraryFor(asset), throwsStateError),
    ]);
    expect(checks, 2);
    expect(delegate.releases, 0);
    expect(await gate.acquire(), isNull);
  });

  test('library stream consumer does not retain cache ownership', () async {
    delegate.libraryStream = () async* {
      expect(checks, 1, reason: 'stream analysis starts only under ownership');
      warm = true;
      yield _Library();
    }();
    final iterator = StreamIterator(resolver.libraries);
    expect(await iterator.moveNext(), isTrue);
    expect(delegate.releases, 0);
    expect(checks, 2);
    expect(await gate.acquire(), isNull);
    await iterator.cancel();
  });
}
