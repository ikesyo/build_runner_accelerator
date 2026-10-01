// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Warms the shared on-disk analyzer byte store while the Rust frontend
/// compiles the worker AOT executable.
///
/// The Rust launcher spawns N copies of this script alongside the
/// synchronous `dart compile exe` call, then waits for them to finish after
/// compilation completes. They
/// run a plain (JIT) `AnalysisDriver` over the workspace sources and resolve
/// libraries into the same content-addressed byte store the AOT workers use,
/// so worker first-touch analysis becomes a disk hit.
///
/// Key identity notes: analyzer byte-store keys are content- and URI-addressed
/// (salt + feature set + language version + content hash + the `package:` URI
/// string); they do not include the filesystem path or workspace salt because
/// `createAnalysisDriver` leaves `analysisContext` unset, matching the worker
/// driver in `worker_resolvers.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/file_system/file_system.dart' show ResourceProvider;
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/file_source.dart';
// ignore: implementation_imports
import 'package:analyzer/src/clients/build_resolvers/build_resolvers.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/file_content_cache.dart';
import 'package:build/experiments.dart';
// ignore: implementation_imports
import 'package:build_runner/src/bootstrap/build_process_state.dart';
// ignore: implementation_imports
import 'package:build_runner/src/build/resolver/analysis_driver.dart'
    show sdkLanguageVersion;
import 'package:build_runner_accelerator/src/sdk_summary_lock.dart'
    show sharedSdkSummaryPath;
import 'package:build_runner_accelerator/src/worker_resolvers.dart'
    show sharedAnalysisByteStore;
import 'package:package_config/package_config.dart' as package_config;
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Directories of the workspace package whose Dart sources are worth warming.
/// `--dirs` overrides the set; the sentinel `none` warms only the SDK summary.
const _defaultWarmDirs = ['lib', 'test', 'integration_test'];

/// Minimal `package:` URI resolver backed by the workspace package config.
///
/// `PackageMapUriResolver` changed its constructor signature across the
/// supported analyzer window, so the prewarmer maps `package:pkg/x.dart` to
/// `<packageRoot>/lib/x.dart` itself. Resolved sources keep the original
/// `package:` URI, so byte-store keys match the worker driver exactly.
class _PackageUriResolver extends UriResolver {
  _PackageUriResolver(this._provider, this._libDirs);

  final ResourceProvider _provider;
  final Map<String, String> _libDirs;

  @override
  Source? resolveAbsolute(Uri uri) {
    if (!uri.isScheme('package')) return null;
    final segments = uri.pathSegments;
    if (segments.length < 2) return null;
    final libDir = _libDirs[segments[0]];
    if (libDir == null) return null;
    final file = _provider.getFile(p.joinAll([libDir, ...segments.skip(1)]));
    return FileSource(file, uri);
  }

  @override
  Uri? pathToUri(String path) {
    for (final entry in _libDirs.entries) {
      final prefix = entry.value + p.separator;
      if (path.startsWith(prefix)) {
        final relative = p.split(path.substring(prefix.length)).join('/');
        return Uri.parse('package:${entry.key}/$relative');
      }
    }
    return null;
  }
}

Future<void> main(List<String> args) async {
  var shard = 0;
  var shards = 1;
  var warmDirs = _defaultWarmDirs;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--shard':
        shard = int.parse(args[++i]);
      case '--shards':
        shards = int.parse(args[++i]);
      case '--dirs':
        warmDirs = args[++i]
            .split(',')
            .map((d) => d.trim())
            .where((d) => d.isNotEmpty && d != 'none')
            .toList();
    }
  }

  final root = Directory.current.path;
  // Belt-and-suspenders bound if the launcher is killed without reaping us.
  // Must be cancelled on the normal path — a live Timer keeps the isolate's
  // event loop (and the process) alive.
  final watchdog = Timer(const Duration(minutes: 5), () => exit(0));
  // `packageConfigUri` initializes itself from `Isolate.packageConfigSync`;
  // the launcher passes the workspace config via `--packages`.
  final packageConfig = await package_config.loadPackageConfigUri(
    Uri.parse(buildProcessState.packageConfigUri),
  );
  final sdkSummary = await sharedSdkSummaryPath();
  if (warmDirs.isEmpty) {
    watchdog.cancel();
    stderr.writeln('prewarm[$shard]: SDK summary ready');
    return;
  }
  final sdkSummaryBytes = await File(sdkSummary.path).readAsBytes();
  final provider = PhysicalResourceProvider.INSTANCE;

  String packageDir(package_config.Package package) =>
      p.fromUri(package.root).toString();

  final driver = createAnalysisDriver(
    resourceProvider: provider,
    fileContentCache: FileContentCache.ephemeral(provider),
    sdkSummaryBytes: sdkSummaryBytes,
    analysisOptions: AnalysisOptionsImpl()
      // ignore: deprecated_member_use
      ..contextFeatures = FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: sdkLanguageVersion,
        flags: enabledExperiments,
      ),
    uriResolvers: [
      _PackageUriResolver(provider, {
        for (final package in packageConfig.packages)
          package.name: p.join(packageDir(package), 'lib'),
      }),
    ],
    packages: Packages({
      for (final package in packageConfig.packages)
        package.name: Package(
          name: package.name,
          languageVersion: package.languageVersion == null
              ? sdkLanguageVersion
              : Version(
                  package.languageVersion!.major,
                  package.languageVersion!.minor,
                  0,
                ),
          rootFolder: provider.getFolder(packageDir(package)),
          libFolder: provider.getFolder(p.join(packageDir(package), 'lib')),
        ),
    }),
    byteStore: sharedAnalysisByteStore(sdkSummaryBytes, packageConfig),
  );
  final session = driver.currentSession;

  final files = <String>[];
  for (final dir in warmDirs) {
    final directory = Directory(p.join(root, dir));
    if (!directory.existsSync()) continue;
    files.addAll(
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path)
          .where((path) => path.endsWith('.dart')),
    );
  }
  files.sort();

  var warmed = 0;
  final stopwatch = Stopwatch()..start();
  for (var i = shard; i < files.length; i += shards) {
    try {
      await session.getResolvedLibraryContaining(files[i]);
    } on Object {
      // Unreadable or non-library sources simply miss; workers recompute them.
    }
    warmed++;
    if (warmed % 200 == 0) {
      stderr.writeln(
        'prewarm[$shard]: $warmed/${(files.length / shards).ceil()} files in '
        '${stopwatch.elapsed.inSeconds}s',
      );
    }
  }
  watchdog.cancel();
  stderr.writeln(
    'prewarm[$shard]: done, $warmed files in ${stopwatch.elapsed.inSeconds}s',
  );
}
