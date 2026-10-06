import 'dart:io';
import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/overlay_blob.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File file;
  final a = AssetId('app', 'lib/a.dart');
  final b = AssetId('app', 'lib/b.part');
  setUp(() {
    dir = Directory.systemTemp.createTempSync('overlay-blob-test');
    file = File('${dir.path}/reset.blob')..writeAsBytesSync([1, 2, 3]);
  });
  tearDown(() => dir.deleteSync(recursive: true));
  Map<String, Object> metadata(Map<String, Object> index, {int length = 3}) => {
    'path': file.path,
    'length': length,
    'index': index,
  };
  test('source/cache ranges and missing update never use old asset files', () {
    File('${dir.path}/old.dart').writeAsBytesSync([9]);
    final values = readOverlayBlob(
      metadata({
        'app|lib/a.dart': {'offset': 0, 'length': 2},
        'app|lib/b.part': {'offset': 2, 'length': 1},
      }),
      {a, b},
    );
    expect(values[a], [1, 2]);
    expect(values[b], [3]);
    expect(
      readOverlayBlob(
        metadata({
          'app|lib/b.part': {'offset': 0, 'length': 3},
        }),
        {a, b},
      ).containsKey(a),
      isFalse,
    );
  });
  test('multiple resets update delete recreate, empty delta', () {
    expect(
      readOverlayBlob(
        metadata({
          'app|lib/a.dart': {'offset': 0, 'length': 3},
        }),
        {a},
      )[a],
      [1, 2, 3],
    );
    file.writeAsBytesSync([]);
    expect(readOverlayBlob(metadata({}, length: 0), {}), isEmpty);
    file.writeAsBytesSync([8]);
    expect(
      readOverlayBlob(
        metadata({
          'app|lib/a.dart': {'offset': 0, 'length': 1},
        }, length: 1),
        {a},
      )[a],
      [8],
    );
  });
  test(
    'rejects bad ranges, unknown IDs, holes, trailing bytes and truncation',
    () {
      for (final range in [
        {'offset': -1, 'length': 3},
        {'offset': 0, 'length': -1},
        {'offset': 0, 'length': 4},
        {'offset': 1, 'length': 2},
        {'offset': 0, 'length': 2},
        {'offset': '0', 'length': 3},
      ]) {
        expect(
          () => readOverlayBlob(metadata({'app|lib/a.dart': range}), {a}),
          throwsFormatException,
        );
      }
      expect(
        () => readOverlayBlob(
          metadata({
            'app|lib/b.part': {'offset': 0, 'length': 3},
          }),
          {a},
        ),
        throwsFormatException,
      );
      file.writeAsBytesSync([1]);
      expect(
        () => readOverlayBlob(
          metadata({
            'app|lib/a.dart': {'offset': 0, 'length': 3},
          }),
          {a},
        ),
        throwsFormatException,
      );
      file.writeAsBytesSync([1, 2, 3, 4]);
      expect(
        () => readOverlayBlob(
          metadata({
            'app|lib/a.dart': {'offset': 0, 'length': 3},
          }),
          {a},
        ),
        throwsFormatException,
      );
    },
  );
  test('read failure releases file and next transport recovers', () {
    final data = metadata({
      'app|lib/a.dart': {'offset': 0, 'length': 3},
    });
    file.deleteSync();
    expect(
      () => readOverlayBlob(data, {a}),
      throwsA(isA<FileSystemException>()),
    );
    file.writeAsBytesSync([7, 8, 9]);
    expect(readOverlayBlob(data, {a})[a], [7, 8, 9]);
  });
  test('rejects malformed metadata', () {
    for (final value in <Map<String, Object?>>[
      {},
      {'path': 'relative', 'length': 0, 'index': {}},
      {'path': file.path, 'length': -1, 'index': {}},
    ]) {
      expect(() => readOverlayBlob(value, {a}), throwsFormatException);
    }
  });
}
