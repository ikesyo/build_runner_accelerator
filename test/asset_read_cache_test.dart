import 'dart:convert';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/asset_read_cache.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  test('asset MD5 matches concatenation across block boundaries and IDs', () {
    for (final path in ['lib/a.dart', 'lib/café.dart', 'lib/日本😀.dart']) {
      final id = AssetId('app', path);
      for (final length in [0, 1, 55, 56, 63, 64, 65, 127, 128, 1024]) {
        final bytes = List<int>.generate(length, (index) => index % 256);
        final content = AssetReadContent(bytes);
        expect(
          content.digestFor(id),
          md5.convert(<int>[...bytes, ...id.toString().codeUnits]),
          reason: '$id, $length bytes',
        );
        expect(content.cachedContentDigest, isNull);
      }
    }
  });

  test('digest is bound to owned immutable bytes, not caller buffers', () {
    final id = AssetId('app', 'lib/main.dart');
    final input = utf8.encode('original');
    final cache = AssetReadCache({id: input});
    final content = cache.contentFor(id)!;
    expect(content.cachedContentDigest, isNull);
    final expected = sha256.convert(input).toString();
    input[0] = 0;
    expect(content.contentDigest, expected);
    expect(() => cache[id]![0] = 0, throwsUnsupportedError);
    expect(() => content.bytes[0] = 0, throwsUnsupportedError);
    expect(
      () => content.bytes.buffer.asByteData().setUint8(0, 0),
      throwsUnsupportedError,
    );
    expect(content.contentDigest, expected);
    expect(content.cachedContentDigest, expected);
  });

  test('replacement, delete/recreate and clear discard the old digest', () {
    final id = AssetId('app', 'lib/main.dart');
    final input = utf8.encode('first');
    final cache = AssetReadCache({id: input});
    final firstDigest = cache.contentFor(id)!.contentDigest;
    // Reusing the same input object after mutation must create a new snapshot.
    input[0] = 0;
    cache[id] = input;
    expect(cache.contentFor(id)!.contentDigest, isNot(firstDigest));
    cache.remove(id);
    expect(cache.contentFor(id), isNull);
    cache[id] = utf8.encode('first');
    expect(cache.contentFor(id)!.cachedContentDigest, isNull);
    expect(cache.contentFor(id)!.contentDigest, firstDigest);
    cache.clear();
    cache[id] = utf8.encode('first');
    expect(cache.contentFor(id)!.cachedContentDigest, isNull);
    expect(cache.contentFor(id)!.contentDigest, firstDigest);
  });
}
