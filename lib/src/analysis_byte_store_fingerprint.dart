import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Keeps the existing byte-store namespace without copying the SDK summary
/// into a boxed integer list. Chunk boundaries do not enter the digest.
String analysisByteStoreFingerprint(
  Uint8List sdkSummaryBytes, {
  required List<String> experiments,
  required String analyzerRoot,
}) {
  final output = _DigestSink();
  final input = sha256.startChunkedConversion(output);
  input.add(sdkSummaryBytes);
  input.add(utf8.encode(experiments.join(' ')));
  input.add(utf8.encode(analyzerRoot));
  input.close();
  return output.digest.toString().substring(0, 16);
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
