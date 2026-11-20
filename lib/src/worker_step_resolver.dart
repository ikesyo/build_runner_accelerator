import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';

import 'analysis_startup_gate.dart';
import 'remote_build_step.dart';
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
    required this.primaryInput,
    this.readerWriter,
  });

  final ReleasableResolver _delegate;
  final AnalysisStartupGate? startupGate;
  final bool timingEnabled;

  /// The action's reader/writer, used to attribute the delegate's
  /// internal readability probes to the resolver channel (ADR 0056):
  /// `libraryFor`, `isLibrary` and `compilationUnitFor` first call
  /// `canRead` on the build step, which preloads the target through
  /// the shared content path, and without scoping that preload lands
  /// in the action's direct reads even though the builder never read
  /// the source. Null when the step's filesystem is not the remote
  /// one (probes then stay direct, the safe side).
  final RemoteAssetReaderWriter? readerWriter;

  /// Runs a delegate resolver call with its reads attributed to the
  /// resolver channel; see [readerWriter].
  Future<T> _scoped<T>(Future<T> Function() call) {
    final scope = readerWriter;
    if (scope == null) return call();
    return scope.runAsResolver(call);
  }

  /// The action's primary input asset.
  final AssetId primaryInput;

  /// Libraries this step touched as source text through
  /// [compilationUnitFor] or [astNodeFor], excluding the primary
  /// input itself: the downgrade evidence for API-signature early
  /// cutoff (ADR 0056). Element-model access such as [libraryFor]
  /// observes only API, so it is not recorded; AST access observes
  /// source, including bodies and comments the API fingerprint does
  /// not cover.
  final Set<AssetId> contentReads = <AssetId>{};

  /// Library element to asset memo for [astNodeFor] recording: a step
  /// typically asks for many fragments of the same few libraries.
  final Map<LibraryElement, AssetId> _libraryAssets =
      <LibraryElement, AssetId>{};

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
        resolverActionMetrics.resolverCallCounts.update(
          name,
          (count) => count + 1,
          ifAbsent: () => 1,
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
      _time('isLibrary', () => _scoped(() => _delegate.isLibrary(assetId)));

  @override
  Future<AstNode?> astNodeFor(Fragment fragment, {bool resolve = false}) async {
    await _recordFragmentLibrary(fragment);
    return _time(
      'astNodeFor',
      () => _delegate.astNodeFor(fragment, resolve: resolve),
      links: resolve,
    );
  }

  /// Records the asset [fragment] was read from as a content read,
  /// unless it is the primary input itself.
  Future<void> _recordFragmentLibrary(Fragment fragment) async {
    try {
      final unitAsset = _unitAsset(fragment);
      if (unitAsset != null) {
        if (unitAsset != primaryInput) contentReads.add(unitAsset);
        return;
      }
      final library = fragment.element.library;
      if (library == null) return;
      var asset = _libraryAssets[library];
      if (asset == null) {
        asset = await _delegate.assetIdForElement(library);
        _libraryAssets[library] = asset;
      }
      if (asset != primaryInput) contentReads.add(asset);
    } on Object {
      // Recording must never break the action: a library that is not
      // backed by a readable asset (SDK libraries, summaries) cannot
      // appear in the build graph, so there is nothing to record.
    }
  }

  /// The asset of the compilation unit holding [fragment], when that
  /// unit's source is a package or asset URI; otherwise null. A
  /// declaration in a part file lives in its own unit, and the
  /// library fallback in [_recordFragmentLibrary] names the defining
  /// unit instead, which would miss the part file entirely (or
  /// record nothing at all when the defining unit is the primary
  /// input). Units outside a package's `lib/` (a primary input
  /// under `test/`, say) carry `asset:` URIs rather than `package:`
  /// ones, and their parts must resolve just the same.
  AssetId? _unitAsset(Fragment fragment) {
    try {
      final uri = fragment.libraryFragment?.source.uri;
      if (uri == null) return null;
      if (uri.scheme != 'package' && uri.scheme != 'asset') return null;
      return AssetId.resolve(uri);
    } on Object {
      return null;
    }
  }

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId assetId, {
    bool allowSyntaxErrors = false,
  }) {
    if (assetId != primaryInput) contentReads.add(assetId);
    return _time(
      'compilationUnitFor',
      () => _scoped(
        () => _delegate.compilationUnitFor(
          assetId,
          allowSyntaxErrors: allowSyntaxErrors,
        ),
      ),
    );
  }

  @override
  Future<LibraryElement> libraryFor(
    AssetId assetId, {
    bool allowSyntaxErrors = false,
  }) => _time(
    'libraryFor',
    () => _scoped(
      () => _delegate.libraryFor(assetId, allowSyntaxErrors: allowSyntaxErrors),
    ),
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
