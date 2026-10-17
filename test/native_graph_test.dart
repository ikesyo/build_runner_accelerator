import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/native_graph.dart';
import 'package:test/test.dart';

List<int> integer(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> string(String value) {
  final bytes = utf8.encode(value);
  return [...integer(bytes.length), ...bytes];
}

List<int> payload({int schema = 4, bool retained = true}) => [
  ...integer(schema),
  ...string('config'),
  // Empty snapshot, actions, resolver edges, output locations, input order,
  // glob membership and watch exclusions.
  for (var i = 0; i < 7; i++) ...integer(0),
  retained ? 1 : 0,
];

List<int> graph(List<int> payload, {int format = 3}) => [
  ...ascii.encode('BRAG'),
  format,
  ...integer(payload.length),
  ...payload,
];

void main() {
  late Directory root;
  late File file;
  setUp(() {
    root = Directory.systemTemp.createTempSync('native-graph-');
    file = File(
      '${root.path}/.dart_tool/build_runner_accelerator/graph-v3.bin',
    );
    file.parent.createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('only complete current graphs can report retained history', () {
    expect(hasRetainedNativeOutputState(root.path), isFalse);
    for (final retained in [true, false]) {
      file.writeAsBytesSync(graph(payload(retained: retained)));
      expect(hasRetainedNativeOutputState(root.path), retained);
    }
  });

  test(
    'obsolete format/schema and malformed records are native cold state',
    () {
      final valid = payload();
      final malformed = <List<int>>[
        for (final format in [1, 2, 99]) graph(valid, format: format),
        graph(payload(schema: 1)),
        [0, ...graph(valid).skip(1)], // magic
        [...graph(valid), 1], // mismatched header length
        graph([...valid, 1]), // trailing payload
        graph(valid.sublist(0, valid.length - 1)), // missing history
        graph([...valid.take(valid.length - 1), 2]), // invalid boolean
        graph([...integer(4), ...integer(1), 0xff, ...valid.skip(14)]), // UTF-8
        graph([...valid.take(14), ...integer(4000001), ...valid.skip(18)]),
      ];
      for (final bytes in malformed) {
        file.writeAsBytesSync(bytes);
        expect(
          hasRetainedNativeOutputState(root.path),
          isFalse,
          reason: '$bytes',
        );
      }
      for (var end = 0; end < graph(valid).length; end++) {
        file.writeAsBytesSync(graph(valid).sublist(0, end));
        expect(hasRetainedNativeOutputState(root.path), isFalse);
      }
    },
  );

  test('duplicate map keys invalidate retained history', () {
    // Two identically named snapshot entries; all other collections are empty.
    final snapshot = [
      ...integer(2),
      for (var i = 0; i < 2; i++) ...[
        ...string('app|lib/a.txt'),
        1,
        ...string('digest'),
        ...List.filled(8, 0),
      ],
    ];
    file.writeAsBytesSync(
      graph([...payload().take(14), ...snapshot, ...payload().skip(18)]),
    );
    expect(hasRetainedNativeOutputState(root.path), isFalse);
  });

  test('oversized graph is rejected before reading its payload', () {
    final handle = file.openSync(mode: FileMode.write);
    handle.writeFromSync(graph(payload()));
    handle.truncateSync(9 + 256 * 1024 * 1024 + 1);
    handle.closeSync();
    expect(hasRetainedNativeOutputState(root.path), isFalse);
  });
}
