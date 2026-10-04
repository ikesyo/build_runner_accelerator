import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:crypto/crypto.dart';
import 'package:build_runner_accelerator/src/protocol.dart';
import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:build_runner_accelerator/src/resolver_metrics.dart';
import 'package:build_runner_accelerator/src/remote_build_step.dart';
import 'package:build_runner_accelerator/src/resolver_reads.dart';
import 'package:package_config/package_config.dart';
import 'package:test/test.dart';

void main() {
  test(
    'persistent extraction remaps relative and file URIs after reset',
    () async {
      final directory = await Directory.systemTemp.createTemp('resolver-uris-');
      final stores = <IndexedBlobStore>[];
      addTearDown(() async {
        for (final store in stores) {
          store.close();
        }
        await directory.delete(recursive: true);
      });
      ResolverDependencyCache newCache() {
        final store = IndexedBlobStore('${directory.path}/store.bin');
        stores.add(store);
        return ResolverDependencyCache(directiveStore: store);
      }

      final content = utf8.encode(
        "import 'relative.dart' if /* comment */ (dart.library.io) "
        "'file:///workspace/package/lib/alternate.dart' "
        "if (dart.library.html) 'package:other/web.dart'; "
        "export 'package:other/base.dart' if (dart.library.html) 'dart:html';",
      );
      final configA = PackageConfig([
        Package('old', Uri.parse('file:///workspace/package/')),
      ]);
      final configB = PackageConfig([
        Package('new', Uri.parse('file:///workspace/package/')),
      ]);
      Future<Set<AssetId>> collect(
        ResolverDependencyCache cache,
        PackageConfig config,
        String input,
      ) async {
        final asset = AssetId('app', input);
        final reads = <AssetId, List<int>>{
          asset: content,
          AssetId('app', input.replaceFirst('main.dart', 'relative.dart')): [],
          AssetId('old', 'lib/alternate.dart'): [],
          AssetId('new', 'lib/alternate.dart'): [],
          AssetId('other', 'lib/base.dart'): [],
          AssetId('other', 'lib/web.dart'): [],
        };
        final io = RemoteAssetReaderWriter(readCache: reads, readableCache: {});
        io.observedReads.add(asset);
        await collectResolverReads(io, config, cache);
        return io.observedReads;
      }

      resolverActionMetrics.beginAction();
      final first = await collect(newCache(), configA, 'lib/main.dart');
      expect(
        first,
        containsAll([
          AssetId('app', 'lib/relative.dart'),
          AssetId('old', 'lib/alternate.dart'),
          AssetId('other', 'lib/base.dart'),
        ]),
      );
      expect(resolverActionMetrics.resolverReadsParses, 1);
      resolverActionMetrics.beginAction();
      final cache = newCache();
      final second = await collect(cache, configB, 'lib/nested/main.dart');
      expect(
        second,
        containsAll([
          AssetId('app', 'lib/nested/relative.dart'),
          AssetId('new', 'lib/alternate.dart'),
          AssetId('other', 'lib/base.dart'),
        ]),
      );
      expect(second, isNot(contains(AssetId('old', 'lib/alternate.dart'))));
      expect(resolverActionMetrics.resolverReadsParses, 0);
      expect(resolverActionMetrics.resolverReadsPersistentHits, greaterThan(0));
      // A package_config change also invalidates resolved in-memory AssetIds.
      final remapped = await collect(cache, configA, 'lib/nested/main.dart');
      expect(remapped, contains(AssetId('old', 'lib/alternate.dart')));
      expect(remapped, isNot(contains(AssetId('new', 'lib/alternate.dart'))));
      cache.clear();
      resolverActionMetrics.beginAction();
      await collect(cache, configA, 'lib/nested/main.dart');
      expect(resolverActionMetrics.resolverReadsParses, 0);
    },
  );

  test('invalid persistent values are reparsed and repaired', () async {
    final directory = await Directory.systemTemp.createTemp(
      'resolver-corrupt-',
    );
    final store = IndexedBlobStore('${directory.path}/store.bin');
    addTearDown(() async {
      store.close();
      await directory.delete(recursive: true);
    });
    final main = AssetId('app', 'lib/main.dart');
    final bytes = utf8.encode(
      "export 'base.dart' if (dart.library.io) 'io.dart';",
    );
    store.put(sha256.convert(bytes).toString(), utf8.encode('[42]'));
    final io = RemoteAssetReaderWriter(
      readCache: {
        main: bytes,
        AssetId('app', 'lib/base.dart'): [],
        AssetId('app', 'lib/io.dart'): [],
      },
      readableCache: {},
    );
    io.observedReads.add(main);
    resolverActionMetrics.beginAction();
    await collectResolverReads(
      io,
      PackageConfig([]),
      ResolverDependencyCache(directiveStore: store),
    );
    expect(
      io.observedReads,
      containsAll([
        AssetId('app', 'lib/base.dart'),
        AssetId('app', 'lib/io.dart'),
      ]),
    );
    expect(resolverActionMetrics.resolverReadsParses, 1);
  });

  test('a hidden generated candidate is inspected when it appears', () async {
    final config = PackageConfig([]);
    final main = AssetId('app', 'lib/main.dart');
    final generated = AssetId('app', 'lib/generated.dart');
    final leaf = AssetId('app', 'lib/leaf.dart');
    final io = RemoteAssetReaderWriter(
      readCache: {
        main: utf8.encode(
          "import 'generated.dart' if (dart.library.io) 'dart:io';",
        ),
        generated: utf8.encode(
          "export 'leaf.dart' if (dart.library.io) 'dart:io';",
        ),
        leaf: [],
      },
      readableCache: {},
    );
    final cache = ResolverDependencyCache();
    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: null,
      blockedAssets: {generated},
    );
    io.observedReads.add(main);
    await collectResolverReads(io, config, cache);
    expect(io.observedReads, contains(generated));
    expect(io.observedReads, isNot(contains(leaf)));
    io.endAction();
    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: null,
      blockedAssets: {},
    );
    io.observedReads.add(main);
    await collectResolverReads(io, config, cache);
    expect(io.observedReads, containsAll([main, generated, leaf]));
    io.endAction();
  });

  test(
    'ordinary directives without if skip the AST parse on a cold miss',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'resolver-prefilter-',
      );
      final store = IndexedBlobStore('${directory.path}/store.bin');
      addTearDown(() async {
        store.close();
        await directory.delete(recursive: true);
      });
      final main = AssetId('app', 'lib/main.dart');
      final io = RemoteAssetReaderWriter(
        readCache: {
          main: utf8.encode(
            "import 'ordinary.dart'; export 'another.dart'; class Main {}",
          ),
        },
        readableCache: {},
      );
      io.observedReads.add(main);
      resolverActionMetrics.beginAction();
      await collectResolverReads(
        io,
        PackageConfig([]),
        ResolverDependencyCache(directiveStore: store),
      );
      expect(io.observedReads, {main});
      expect(resolverActionMetrics.resolverReadsPersistentMisses, 1);
      expect(resolverActionMetrics.resolverReadsParses, 0);
    },
  );

  test('cached dependencies still obey the active action visibility', () async {
    final packageConfigUri = await Isolate.packageConfig;
    expect(packageConfigUri, isNotNull);
    final packageConfig = await loadPackageConfigUri(packageConfigUri!);
    final shared = AssetId('app', 'lib/shared.dart');
    final dependency = AssetId('app', 'lib/dependency.dart');
    final anotherInput = AssetId('app', 'lib/other.dart');
    final readCache = <AssetId, List<int>>{
      shared: utf8.encode(
        "import 'dependency.dart' if (dart.library.io) 'dependency_io.dart';",
      ),
      dependency: utf8.encode('class Dependency {}'),
      AssetId('app', 'lib/dependency_io.dart'): utf8.encode(
        'class DependencyIo {}',
      ),
    };
    final io = RemoteAssetReaderWriter(
      readCache: readCache,
      readableCache: <AssetId>{},
    );
    final cache = ResolverDependencyCache();

    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: null,
      blockedAssets: <AssetId>{},
    );
    io.observedReads.add(shared);
    await collectResolverReads(io, packageConfig, cache);
    expect(io.observedReads, contains(dependency));
    io.endAction();

    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: anotherInput,
      blockedAssets: <AssetId>{},
    );
    io.observedReads.add(shared);
    await collectResolverReads(io, packageConfig, cache);
    expect(io.observedReads, contains(shared));
    expect(io.observedReads, isNot(contains(dependency)));
    io.endAction();

    io.beginAction(
      rpc: _rpc(),
      package: 'app',
      primaryInput: null,
      blockedAssets: <AssetId>{shared},
    );
    io.observedReads.add(shared);
    await collectResolverReads(io, packageConfig, cache);
    expect(io.observedReads, contains(shared));
    expect(io.observedReads, isNot(contains(dependency)));
    io.endAction();
  });

  test('propagates non-asset-not-found read failures', () async {
    final packageConfigUri = await Isolate.packageConfig;
    expect(packageConfigUri, isNotNull);
    final packageConfig = await loadPackageConfigUri(packageConfigUri!);
    final io = RemoteAssetReaderWriter(
      readCache: <AssetId, List<int>>{},
      readableCache: <AssetId>{},
    );
    io.observedReads.add(AssetId('app', 'lib/main.dart'));

    await expectLater(
      collectResolverReads(io, packageConfig, ResolverDependencyCache()),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'recomputes dependencies when a post-process output changes bytes',
    () async {
      final packageConfigUri = await Isolate.packageConfig;
      expect(packageConfigUri, isNotNull);
      final packageConfig = await loadPackageConfigUri(packageConfigUri!);
      final main = AssetId('app', 'lib/main.dart');
      final fallback = AssetId('app', 'lib/fallback.dart');
      final replacement = AssetId('app', 'lib/replacement.dart');
      final fallbackIo = AssetId('app', 'lib/fallback_io.dart');
      final replacementIo = AssetId('app', 'lib/replacement_io.dart');
      final io = RemoteAssetReaderWriter(
        readCache: <AssetId, List<int>>{
          fallback: utf8.encode('class Fallback {}'),
          replacement: utf8.encode('class Replacement {}'),
          fallbackIo: utf8.encode('class FallbackIo {}'),
          replacementIo: utf8.encode('class ReplacementIo {}'),
        },
        readableCache: <AssetId>{},
      );
      final cache = ResolverDependencyCache();

      Future<Set<AssetId>> collectPostProcessOutput(String target) async {
        io.beginAction(
          rpc: _rpc(),
          package: 'app',
          primaryInput: main,
          blockedAssets: <AssetId>{},
        );
        try {
          final alternateTarget = target.replaceFirst('.dart', '_io.dart');
          await io.writeAsString(
            main,
            "import '$target' if (dart.library.io) '$alternateTarget';",
          );
          io.observedReads.add(main);
          await collectResolverReads(io, packageConfig, cache);
          return Set<AssetId>.of(io.observedReads);
        } finally {
          io.endAction();
        }
      }

      final firstReads = await collectPostProcessOutput('fallback.dart');
      expect(firstReads, containsAll(<AssetId>[main, fallback, fallbackIo]));
      expect(firstReads, isNot(contains(replacement)));

      final secondReads = await collectPostProcessOutput('replacement.dart');
      expect(
        secondReads,
        containsAll(<AssetId>[main, replacement, replacementIo]),
      );
      expect(secondReads, isNot(contains(fallback)));
      expect(secondReads, isNot(contains(fallbackIo)));
    },
  );

  test(
    'reuses same-content dependencies and refreshes changed content',
    () async {
      final packageConfigUri = await Isolate.packageConfig;
      expect(packageConfigUri, isNotNull);
      final packageConfig = await loadPackageConfigUri(packageConfigUri!);
      final main = AssetId('app', 'lib/main.dart');
      final fallback = AssetId('app', 'lib/fallback.dart');
      final ioVariant = AssetId('app', 'lib/io.dart');
      final base = AssetId('app', 'lib/base.dart');
      final htmlVariant = AssetId('app', 'lib/html.dart');
      final semicolonMain = AssetId('app', 'lib/semicolon_main.dart');
      final replacement = AssetId('app', 'lib/replacement.dart');
      final replacementIo = AssetId('app', 'lib/replacement_io.dart');
      final semicolonFallback = AssetId('app', 'lib/semicolon;fallback.dart');
      final semicolonVariant = AssetId('app', 'lib/semicolon;html.dart');
      final noise = AssetId('app', 'lib/noise.dart');
      final readCache = <AssetId, List<int>>{
        main: utf8.encode(
          "import 'fallback.dart' if (dart.library.io) 'io.dart';",
        ),
        semicolonMain: utf8.encode(
          "import 'semicolon;fallback.dart' if (dart.library.html) "
          "'semicolon;html.dart';",
        ),
        fallback: utf8.encode(
          "export 'base.dart' if (dart.library.html) 'html.dart';",
        ),
        ioVariant: utf8.encode('class IoVariant {}'),
        base: utf8.encode('class Base {}'),
        htmlVariant: utf8.encode('class HtmlVariant {}'),
        semicolonFallback: utf8.encode('class SemicolonFallback {}'),
        semicolonVariant: utf8.encode('class SemicolonVariant {}'),
        replacement: utf8.encode('class Replacement {}'),
        replacementIo: utf8.encode('class ReplacementIo {}'),
        noise: utf8.encode(
          '''// import 'comment.dart' if (dart.library.io) 'comment_io.dart';
final text = "export 'string.dart' if (dart.library.io) 'string_io.dart';";''',
        ),
      };
      final cache = ResolverDependencyCache();

      Future<Set<AssetId>> collectPass() async {
        final io = RemoteAssetReaderWriter(
          readCache: readCache,
          readableCache: <AssetId>{},
        );
        io.observedReads.add(main);
        io.observedReads.add(semicolonMain);
        io.observedReads.add(noise);
        await collectResolverReads(io, packageConfig, cache);
        return Set<AssetId>.of(io.observedReads);
      }

      final firstReads = await collectPass();
      expect(
        firstReads,
        containsAll(<AssetId>[
          main,
          fallback,
          ioVariant,
          base,
          htmlVariant,
          semicolonMain,
          semicolonFallback,
          semicolonVariant,
          noise,
        ]),
      );
      expect(cache.scannedAssetCount, 9);
      expect(
        firstReads.intersection(<AssetId>{
          AssetId('app', 'lib/comment.dart'),
          AssetId('app', 'lib/comment_io.dart'),
          AssetId('app', 'lib/string.dart'),
          AssetId('app', 'lib/string_io.dart'),
        }),
        isEmpty,
      );
      final cachedMainDependencies = cache.dependenciesFor(
        main,
        readCache[main]!,
      );
      expect(cachedMainDependencies, isNotNull);

      final repeatedReads = await collectPass();
      expect(
        repeatedReads,
        containsAll(<AssetId>[
          main,
          fallback,
          ioVariant,
          base,
          htmlVariant,
          semicolonMain,
          semicolonFallback,
          semicolonVariant,
          noise,
        ]),
      );
      expect(cache.scannedAssetCount, 9);
      expect(
        cache.dependenciesFor(main, readCache[main]!),
        same(cachedMainDependencies),
      );

      readCache[main] = utf8.encode(
        "import 'replacement.dart' if (dart.library.io) 'replacement_io.dart';",
      );
      final samePhaseReads = await collectPass();
      expect(
        samePhaseReads,
        containsAll(<AssetId>[main, replacement, replacementIo]),
      );
      expect(samePhaseReads, isNot(contains(fallback)));
      expect(samePhaseReads, isNot(contains(ioVariant)));
      expect(cache.scannedAssetCount, 11);

      cache.clear();
      final nextPhaseReads = await collectPass();
      expect(
        nextPhaseReads,
        containsAll(<AssetId>[main, replacement, replacementIo]),
      );
      expect(nextPhaseReads, isNot(contains(fallback)));
      expect(nextPhaseReads, isNot(contains(ioVariant)));
      expect(
        nextPhaseReads,
        containsAll(<AssetId>[semicolonFallback, semicolonVariant]),
      );
      expect(cache.scannedAssetCount, 7);
    },
  );
}

RpcSession _rpc() => RpcSession(
  FrameReader(Stream<List<int>>.empty()),
  FrameWriter(IOSink(_DiscardingConsumer())),
  buildId: 1,
  phase: 0,
  postProcess: false,
);

class _DiscardingConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}
