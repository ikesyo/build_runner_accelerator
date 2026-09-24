import 'dart:convert';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/remote_build_step.dart';
import 'package:build_runner_accelerator/src/resolver_reads.dart';
import 'package:package_config/package_config.dart';
import 'package:test/test.dart';

void main() {
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
    'reuses conditional dependencies until the resolver cache is cleared',
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
      final cachedMainDependencies = cache.dependenciesFor(main);
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
      expect(cache.dependenciesFor(main), same(cachedMainDependencies));

      readCache[main] = utf8.encode(
        "import 'replacement.dart' if (dart.library.io) 'replacement_io.dart';",
      );
      final samePhaseReads = await collectPass();
      expect(samePhaseReads, isNot(contains(replacement)));

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
