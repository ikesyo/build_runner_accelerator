import 'dart:convert';
import 'dart:io';

import 'package:build_runner_accelerator/src/manifest/emitter.dart';
import 'package:build_runner_accelerator/src/manifest/model.dart';
import 'package:test/test.dart';

void main() {
  test('workerSource is deterministic and groups builder kinds', () {
    final entries = <CatalogEntry>[
      CatalogEntry(
        id: 'z:post',
        importUri: 'package:shared/post.dart',
        factory: 'postFactory',
        isPostProcess: true,
      ),
      CatalogEntry(
        id: 'b:normal',
        importUri: 'package:shared/builder.dart',
        factory: 'secondFactory',
        isPostProcess: false,
      ),
      CatalogEntry(
        id: 'a:normal',
        importUri: 'package:shared/builder.dart',
        factory: 'firstFactory',
        isPostProcess: false,
      ),
    ];

    final source = workerSource(entries);
    final reversedSource = workerSource(entries.reversed);

    expect(reversedSource, source);
    expect(
      RegExp(
        r"import 'package:shared/builder\.dart'",
      ).allMatches(source).length,
      1,
    );
    expect(
      source,
      contains("import 'package:shared/builder.dart' as builderImport0;"),
    );
    expect(
      source,
      contains("import 'package:shared/post.dart' as builderImport1;"),
    );

    final normalCatalog = source.indexOf('catalog: <String, BuilderFactory>{');
    final postProcessCatalog = source.indexOf(
      'postProcessCatalog: <String, PostProcessBuilderFactory>{',
    );
    final firstBuilder = source.indexOf("'a:normal':");
    final secondBuilder = source.indexOf("'b:normal':");
    final postProcessBuilder = source.indexOf("'z:post':");

    expect(normalCatalog, greaterThan(-1));
    expect(postProcessCatalog, greaterThan(normalCatalog));
    expect(firstBuilder, greaterThan(normalCatalog));
    expect(secondBuilder, greaterThan(firstBuilder));
    expect(postProcessBuilder, greaterThan(postProcessCatalog));
  });

  test(
    'emitManifestArtifacts writes the manifest and worker without leftovers',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'build-runner-accelerator-manifest-emitter-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final manifest = File('${temporary.path}/nested/manifest.json');
      final worker = File('${temporary.path}/worker/generated.dart');
      await emitManifestArtifacts(
        manifestPath: manifest.path,
        workerEntrypoint: worker.path,
        fingerprint: 'fingerprint',
        triggerDigest: 'trigger-digest',
        builders: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'example:builder'},
        ],
        definitions: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'example:builder'},
        ],
        catalogEntries: <CatalogEntry>[
          CatalogEntry(
            id: 'example:builder',
            importUri: 'package:example/builder.dart',
            factory: 'createBuilder',
            isPostProcess: false,
          ),
        ],
      );

      final decoded = jsonDecode(await manifest.readAsString()) as Map;
      expect(decoded['version'], 8);
      expect(decoded['fingerprint'], 'fingerprint');
      expect(decoded['trigger_digest'], 'trigger-digest');
      expect(decoded['worker_entrypoint'], worker.absolute.path);
      expect(decoded['builders'], <Map<String, dynamic>>[
        <String, dynamic>{'id': 'example:builder'},
      ]);
      expect(decoded['definitions'], <Map<String, dynamic>>[
        <String, dynamic>{'id': 'example:builder'},
      ]);
      expect(
        await worker.readAsString(),
        contains("'example:builder': builderImport0.createBuilder"),
      );

      final leftovers = await temporary.list(recursive: true).toList();
      expect(
        leftovers.where((entity) => entity.path.contains('.tmp.')),
        isEmpty,
      );
    },
  );
}
