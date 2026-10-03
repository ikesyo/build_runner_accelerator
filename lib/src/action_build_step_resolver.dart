// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:pool/pool.dart';

// ignore: implementation_imports
import 'package:build_runner/src/build/build_step_impl.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/build_resolver.dart';

/// Action-local fork of build_runner 2.16.1's BuildStepResolver.
///
/// Keeps its visibility checks, input tracking, library stream and pool ordering,
/// adding successful/pending API results and non-transitive synchronization.
/// Do not retain this object across actions or resolver phase resets.
class ActionBuildStepResolver implements ReleasableResolver {
  final BuildResolver _buildResolver;
  final BuildStepImpl _buildStep;
  final int Function()? _cacheGeneration;
  int? _generation;

  // A nested optional action can change the shared driver's phase or produce
  // new visible assets while this action is suspended. Re-synchronize on resume.
  void _refreshCaches() {
    final generation = _cacheGeneration?.call();
    if (generation == _generation) return;
    _generation = generation;
    _syncedEntryPoints.clear();
    _syncs.clear();
    _isLibrary.clear();
    _units.clear();
    _libraries.clear();
  }

  final _entryPoints = <AssetId>{};
  final _syncedEntryPoints = <AssetId>{};
  // Transitive synchronization is already deduplicated by the success set and
  // pool. Only the upstream gap (shallow synchronization) needs a Future cache.
  final _syncs = <AssetId, Future<void>>{};
  final _isLibrary = <AssetId, Future<bool>>{};
  final _units = <(AssetId, bool), Future<CompilationUnit>>{};
  final _libraries = <(AssetId, bool), Future<LibraryElement>>{};

  // Store pending work too. Failures are evicted before reaching callers so
  // missing optional assets and failed analysis can be retried in this action.
  Future<T> _memo<K, T>(
    Map<K, Future<T>> cache,
    K key,
    Future<T> Function() load,
  ) {
    final cached = cache[key];
    if (cached != null) return cached;
    late final Future<T> pending;
    pending = Future<T>.sync(load).then(
      (value) => value,
      onError: (Object error, StackTrace stack) {
        // An invalidation may have installed newer work for the same key.
        if (identical(cache[key], pending)) cache.remove(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    cache[key] = pending;
    return pending;
  }

  // Ensures we only resolve one entrypoint at a time from the same build step,
  // otherwise there are race conditions with `_entryPoints` being updated
  // before it is actually ready, or resolving entrypoints more than once.
  final Pool _perActionResolvePool = Pool(1);

  ActionBuildStepResolver(
    this._buildResolver,
    this._buildStep, {
    int Function()? cacheGeneration,
  }) : _cacheGeneration = cacheGeneration;

  Stream<LibraryElement> get _librariesFromEntrypoints async* {
    await _updateDriverForEntrypoint(_buildStep.inputId, transitive: true);

    final seen = <LibraryElement>{};
    final toVisit = Queue<LibraryElement>();

    // keep a copy of entry points in case [libraryFor] is called
    // before this stream is done.
    final entryPoints = _entryPoints.toList();
    for (final entryPoint in entryPoints) {
      await _updateDriverForEntrypoint(entryPoint, transitive: true);
      if (!await _buildResolver.isLibrary(entryPoint)) continue;
      final library = await _buildResolver.libraryFor(
        entryPoint,
        allowSyntaxErrors: true,
      );
      toVisit.add(library);
      seen.add(library);
    }
    while (toVisit.isNotEmpty) {
      final current = toVisit.removeFirst();
      // TODO - avoid crawling or returning libraries which are not visible via
      // `BuildStep.canRead`. They'd still be reachable by crawling the element
      // model manually.
      yield current;
      final toCrawl = current.firstFragment.libraryImports
          .map((import) => import.importedLibrary)
          .followedBy(
            current.firstFragment.libraryExports.map(
              (export) => export.exportedLibrary,
            ),
          )
          .nonNulls
          .where((library) => !seen.contains(library))
          .toSet();
      toVisit.addAll(toCrawl);
      seen.addAll(toCrawl);
    }
  }

  @override
  Stream<LibraryElement> get libraries async* {
    yield* _buildResolver.sdkLibraries;
    yield* _librariesFromEntrypoints.where((library) => !library.isInSdk);
  }

  @override
  Future<LibraryElement?> findLibraryByName(String libraryName) =>
      _buildStep.trackStage('findLibraryByName $libraryName', () async {
        await for (final library in libraries) {
          if (library.name == libraryName) return library;
        }
        return null;
      });

  @override
  Future<bool> isLibrary(AssetId assetId) =>
      _buildStep.trackStage('isLibrary $assetId', () async {
        if (!await _buildStep.canRead(assetId)) return false;
        _refreshCaches();
        return _memo(_isLibrary, assetId, () async {
          await _updateDriverForEntrypoint(assetId, transitive: false);
          return _buildResolver.isLibrary(assetId);
        });
      });

  @override
  Future<AstNode?> astNodeFor(Fragment fragment, {bool resolve = false}) =>
      _buildStep.trackStage(
        'astNodeFor $fragment',
        () => _buildResolver.astNodeFor(fragment, resolve: resolve),
      );

  @override
  Future<CompilationUnit> compilationUnitFor(
    AssetId assetId, {
    bool allowSyntaxErrors = false,
  }) => _buildStep.trackStage('compilationUnitFor $assetId', () async {
    if (!await _buildStep.canRead(assetId)) {
      throw AssetNotFoundException(assetId);
    }
    _refreshCaches();
    return _memo(_units, (assetId, allowSyntaxErrors), () async {
      await _updateDriverForEntrypoint(assetId, transitive: false);
      return _buildResolver.compilationUnitFor(
        assetId,
        allowSyntaxErrors: allowSyntaxErrors,
      );
    });
  });

  @override
  Future<LibraryElement> libraryFor(
    AssetId assetId, {
    bool allowSyntaxErrors = false,
  }) => _buildStep.trackStage('libraryFor $assetId', () async {
    if (!await _buildStep.canRead(assetId)) {
      throw AssetNotFoundException(assetId);
    }
    _refreshCaches();
    return _memo(_libraries, (assetId, allowSyntaxErrors), () async {
      await _updateDriverForEntrypoint(assetId, transitive: true);
      return _buildResolver.libraryFor(
        assetId,
        allowSyntaxErrors: allowSyntaxErrors,
      );
    });
  });

  /// Updates the analysis driver with updated source of [entrypoint] at
  /// the phase viewed by this build step.
  ///
  /// If [transitive], then all the transitive imports from [entrypoint] are
  /// also updated.
  ///
  /// Records what was read in the build step's `InputTracker`.
  Future<void> _updateDriverForEntrypoint(
    AssetId entrypoint, {
    required bool transitive,
  }) {
    _refreshCaches();
    final generation = _generation;
    Future<void> synchronize() => _perActionResolvePool.withResource(() async {
      if (!_syncedEntryPoints.contains(entrypoint)) {
        // The resolver will only visit assets that haven't been resolved
        // in this step yet.
        await _buildStep.trackStage(
          'Resolving library $entrypoint',
          () => _buildResolver.updateDriverForEntrypoint(
            buildStep: _buildStep,
            entrypoint: entrypoint,
            transitive: transitive,
          ),
        );
        // Record only successful transitive synchronization for the library
        // stream. The pool serializes upgrades and synchronization of
        // different entrypoints; API caches share identical pending queries.
        if (transitive) {
          _entryPoints.add(entrypoint);
          // Pending work from an invalidated generation must not mark a
          // newer generation as synchronized when it completes.
          if (_generation == generation &&
              _cacheGeneration?.call() == generation) {
            _syncedEntryPoints.add(entrypoint);
          }
        }
      }
    });
    return transitive ? synchronize() : _memo(_syncs, entrypoint, synchronize);
  }

  // Upstream release is a no-op. Keep that contract; all maps belong only to
  // this build step and become unreachable with it.
  @override
  void release() {}

  @override
  Future<AssetId> assetIdForElement(Element element) =>
      _buildResolver.assetIdForElement(element);
}
