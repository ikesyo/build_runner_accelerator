import 'dart:convert';
import 'dart:typed_data';

import 'package:build_runner_accelerator/src/blake3.dart';
import 'package:test/test.dart';

void main() {
  test('matches known BLAKE3 vectors for text inputs', () {
    expect(
      blake3Hex(utf8.encode('')),
      'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
    );
    expect(
      blake3Hex(utf8.encode('abc')),
      '6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85',
    );
  });

  test('matches reference outputs across block, chunk and tree boundaries', () {
    // Expected values are the reference implementation's outputs for the
    // official test-vector input pattern (byte i is i % 251), at lengths
    // spanning single blocks, chunk edges (1024) and multi-level trees.
    const vectors = <int, String>{
      0: 'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
      1: '2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213',
      2: '7b7015bb92cf0b318037702a6cdd81dee41224f734684c2c122cd6359cb1ee63',
      3: 'e1be4d7a8ab5560aa4199eea339849ba8e293d55ca0a81006726d184519e647f',
      4: 'f30f5ab28fe047904037f77b6da4fea1e27241c5d132638d8bedce9d40494f32',
      63: 'e9bc37a594daad83be9470df7f7b3798297c3d834ce80ba85d6e207627b7db7b',
      64: '4eed7141ea4a5cd4b788606bd23f46e212af9cacebacdc7d1f4c6dc7f2511b98',
      65: 'de1e5fa0be70df6d2be8fffd0e99ceaa8eb6e8c93a63f2d8d1c30ecb6b263dee',
      100: '8e2eb1bba3040b8f611a1240a0e111c74b45cfc9caed10b95f6372db1c40b8b5',
      127: 'd81293fda863f008c09e92fc382a81f5a0b4a1251cba1634016a0f86a6bd640d',
      128: 'f17e570564b26578c33bb7f44643f539624b05df1a76c81f30acd548c44b45ef',
      129: '683aaae9f3c5ba37eaaf072aed0f9e30bac0865137bae68b1fde4ca2aebdcb12',
      130: '1a47dcca2a7e9531e659ab54595a82c6931877fb936395d13151e5ce7a1440c4',
      1023: '10108970eeda3eb932baac1428c7a2163b0e924c9a9e25b35bba72b28f70bd11',
      1024: '42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7',
      1025: 'd00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444',
      2048: 'e776b6028c7cd22a4d0ba182a8bf62205d2ef576467e838ed6f2529b85fba24a',
      2049: '5f4d72f40d7a5f82b15ca2b2e44b1de3c2ef86c426c95c1af0b6879522563030',
      3072: 'b98cb0ff3623be03326b373de6b9095218513e64f1ee2edd2525c7ad1e5cffd2',
      3073: '7124b49501012f81cc7f11ca069ec9226cecb8a2c850cfe644e327d22d3e1cd3',
      4096: '015094013f57a5277b59d8475c0501042c0b642e531b0a1c8f58d2163229e969',
      5120: '9cadc15fed8b5d854562b26a9536d9707cadeda9b143978f319ab34230535833',
      6144: '3e2e5b74e048f3add6d21faab3f83aa44d3b2278afb83b80b3c35164ebeca205',
      7168: '61da957ec2499a95d6b8023e2b0e604ec7f6b50e80a9678b89d2628e99ada77a',
      8192: 'aae792484c8efe4f19e2ca7d371d8c467ffb10748d8a5a1ae579948f718a2a63',
      8193: 'bab6c09cb8ce8cf459261398d2e7aef35700bf488116ceb94a36d0f5f1b7bc3b',
      16384: 'f875d6646de28985646f34ee13be9a576fd515f76b5b0a26bb324735041ddde4',
      31744: '62b6960e1a44bcc1eb1a611a8d6235b6b4b78f32e7abc4fb4c6cdcce94895c47',
      102400:
          'bc3e3d41a1146b069abffad3c0d44860cf664390afce4d9661f7902e7943e085',
    };
    for (final entry in vectors.entries) {
      final input = Uint8List(entry.key);
      for (var i = 0; i < entry.key; i++) {
        input[i] = i % 251;
      }
      expect(blake3Hex(input), entry.value, reason: 'length ${entry.key}');
    }
  });

  test('hashes views by their visible bytes, not the backing buffer', () {
    final backing = Uint8List.fromList(utf8.encode('xxabcxx'));
    final view = Uint8List.sublistView(backing, 2, 5);
    expect(blake3Hex(view), blake3Hex(utf8.encode('abc')));
  });

  test('hashes long views at nonzero offsets on both block-loading paths', () {
    // The 1025-byte reference input spans full blocks plus a one-byte
    // final chunk. A view at offset 4 is 4-byte aligned, so on a
    // little-endian host it exercises the aligned word-loading path with
    // a nonzero offsetInBytes; a view at offset 2 is unaligned and
    // exercises the byte loader. Both must hash to the reference digest.
    const digest1025 =
        'd00278ae47eb27b34faecf67b4fe263f82d5412916c1ffd97c8cb7fb814b8444';
    for (final offset in [4, 2]) {
      final backing = Uint8List(1025 + offset);
      for (var i = 0; i < 1025; i++) {
        backing[offset + i] = i % 251;
      }
      final view = Uint8List.sublistView(backing, offset, offset + 1025);
      expect(blake3Hex(view), digest1025, reason: 'offset $offset');
    }
  });
}
