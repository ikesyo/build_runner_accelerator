import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';

import 'analysis_startup_gate.dart';
import 'resolver_metrics.dart';

/// Gates linking calls and optionally times resolver entry points.
///
/// The first `libraryFor`/`libraries` call is where the analyzer loads the
/// transitive library cycle: separating the call's wall time from the
/// dep-graph walk and pending-change application measured inside
/// `updateDriver` shows the element-model (summary link/load) share.
class WorkerStepResolver implements ReleasableResolver {
  WorkerStepResolver(
    this._delegate, {
    this.startupGate,
    required this.timingEnabled,
  });

  final ReleasableResolver _delegate;
  final AnalysisStartupGate? startupGate;
  final bool timingEnabled;
  AnalysisStartupLease? _lease;
  Future<void>? _analysisStarted;
  int _linkingCalls = 0;

  Future<void> _ensureAnalysisStarted() => _analysisStarted ??= () async {
    final timer = timingEnabled ? (Stopwatch()..start()) : null;
    _lease = await startupGate?.acquire();
    if (timer != null) {
      resolverActionMetrics.analysisStartupWaitUs += timer.elapsedMicroseconds;
    }
  }();

  void _finishLinking() {
    if (--_linkingCalls != 0) return;
    // Publication happens when the analyzer call completes. Builder code
    // after that call can be slow or even depend on another worker, so it
    // must not keep ownership of the shared analysis cache.
    _lease?.release();
    _lease = null;
    _analysisStarted = null;
  }

  Future<T> _time<T>(
    String name,
    Future<T> Function() call, {
    bool links = false,
  }) async {
    final timer = timingEnabled ? (Stopwatch()..start()) : null;
    if (links) _linkingCalls++;
    try {
      if (links && startupGate?.isReady == false) {
        await _ensureAnalysisStarted();
      }
      return await call();
    } finally {
      if (links) _finishLinking();
      if (timer != null) {
        final us = timer.elapsedMicroseconds;
        resolverActionMetrics.resolverFirstCallUs.putIfAbsent(name, () => us);
        resolverActionMetrics.resolverCallUs.update(
          name,
          (total) => total + us,
          ifAbsent: () => us,
        );
      }
    }
  }

  @override
  Stream<LibraryElement> get libraries async* {
    final timer = Stopwatch()..start();
    StreamIterator<LibraryElement>? iterator;
    try {
      while (true) {
        _linkingCalls++;
        bool hasNext;
        try {
          if (startupGate?.isReady == false) await _ensureAnalysisStarted();
          // Listening can start analysis. Subscribe only after ownership has
          // been acquired, and pause between events until the next acquire.
          iterator ??= StreamIterator(_delegate.libraries);
          hasNext = await iterator.moveNext();
        } finally {
          _finishLinking();
        }
        if (!hasNext) break;
        if (timingEnabled) resolverActionMetrics.librariesCount++;
        // Consumer work between events does not own the startup lock.
        yield iterator.current;
      }
    } finally {
      await iterator?.cancel();
      if (timingEnabled) {
        resolverActionMetrics.librariesStreamUs += timer.elapsedMicroseconds;
      }
    }
  }

  @override
  Future<LibraryElement?> findLibraryByName(String libraryName) => _time(
    'findLibraryByName',
    () => _delegate.findLibraryByName(libraryName),
    links: true,
  );

  @override
  Future<bool> isLibrary(AssetId assetId) =>
      _time('isLibrary', () => _delegate.isLibrary(assetId));

  @override
  Future<AstNode?> astNodeFor(Fragment fragment, {bool resolve = false}) =>
      _time(
        'astNodeFor',
        () => _delegate.astNodeFor(fragment, resolve: resolve),
        links: resolve,
      );

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId assetId, {
    bool allowSyntaxErrors = false,
  }) => _time(
    'compilationUnitFor',
    () => _delegate.compilationUnitFor(
      assetId,
      allowSyntaxErrors: allowSyntaxErrors,
    ),
  );

  @override
  Future<LibraryElement> libraryFor(
    AssetId assetId, {
    bool allowSyntaxErrors = false,
  }) => _time(
    'libraryFor',
    () => _delegate.libraryFor(assetId, allowSyntaxErrors: allowSyntaxErrors),
    links: true,
  );

  @override
  Future<AssetId> assetIdForElement(Element element) =>
      _time('assetIdForElement', () => _delegate.assetIdForElement(element));

  @override
  void release() {
    try {
      _delegate.release();
    } finally {
      _lease?.release();
      _lease = null;
    }
  }
}
