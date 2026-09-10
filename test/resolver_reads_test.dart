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
      collectResolverReads(io, packageConfig),
      throwsA(isA<StateError>()),
    );
  });
}
