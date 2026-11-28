import 'dart:typed_data';

/// BLAKE3 content digest (unkeyed hash, 32-byte output) as lowercase hex.
///
/// The Rust frontend identifies content by BLAKE3 (`b3-` digests in
/// `rust/src/digest.rs`); the worker's persistent caches key entries by
/// content digest, so the worker needs the same function to form and look
/// up those keys (ADR 0054). `package:crypto` has no BLAKE3 and the
/// available packages are too small to take as a core-path dependency, so
/// the unkeyed hash is implemented here directly from the BLAKE3
/// specification. Correctness is pinned by `test/blake3_test.dart`
/// against reference outputs for inputs spanning every chunk and tree
/// boundary.
///
/// Only the whole-buffer form is provided: every caller already holds
/// the full content in memory.
String blake3Hex(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final cv = Uint32List(8);
  _hashInto(data, cv);
  return _encodeHex(cv);
}

const _iv0 = 0x6A09E667;
const _iv1 = 0xBB67AE85;
const _iv2 = 0x3C6EF372;
const _iv3 = 0xA54FF53A;
const _iv4 = 0x510E527F;
const _iv5 = 0x9B05688C;
const _iv6 = 0x1F83D9AB;
const _iv7 = 0x5BE0CD19;

/// Read-only IV words used as the input chaining value for parent nodes.
final _ivWords = Uint32List.fromList(const <int>[
  _iv0,
  _iv1,
  _iv2,
  _iv3,
  _iv4,
  _iv5,
  _iv6,
  _iv7,
]);

/// ASCII codes for lowercase hexadecimal digits '0'..'9', 'a'..'f'.
const _hexDigits = <int>[
  0x30,
  0x31,
  0x32,
  0x33,
  0x34,
  0x35,
  0x36,
  0x37,
  0x38,
  0x39,
  0x61,
  0x62,
  0x63,
  0x64,
  0x65,
  0x66,
];

const _blockLen = 64;
const _chunkLen = 1024;
const _flagChunkStart = 1 << 0;
const _flagChunkEnd = 1 << 1;
const _flagParent = 1 << 2;
const _flagRoot = 1 << 3;
const _mask32 = 0xFFFFFFFF;

@pragma('vm:prefer-inline')
int _rotr16(int x) => ((x >>> 16) | (x << 16)) & _mask32;

@pragma('vm:prefer-inline')
int _rotr12(int x) => ((x >>> 12) | (x << 20)) & _mask32;

@pragma('vm:prefer-inline')
int _rotr8(int x) => ((x >>> 8) | (x << 24)) & _mask32;

@pragma('vm:prefer-inline')
int _rotr7(int x) => ((x >>> 7) | (x << 25)) & _mask32;

/// The BLAKE3 compression function over one 64-byte block of 16 little-endian
/// words starting at [wordOffset] in [words], writing the 8-word output
/// chaining value (or 32-byte root digest when `_flagRoot` is set) into [out].
///
/// Aliasing: all 8 input chaining value words (`cv[0..7]`) and all 16 message
/// words (`words[wordOffset..wordOffset + 15]`) are loaded into local variables
/// before any round runs, and [out] is only written after all 7 rounds finish.
/// Callers may therefore safely pass the same buffer for [cv] and [out] (for
/// example, updating a chunk's chaining value in place).
void _compress(
  Uint32List cv,
  Uint32List words,
  int wordOffset,
  int counter,
  int blockLen,
  int flags,
  Uint32List out,
) {
  var v0 = cv[0];
  var v1 = cv[1];
  var v2 = cv[2];
  var v3 = cv[3];
  var v4 = cv[4];
  var v5 = cv[5];
  var v6 = cv[6];
  var v7 = cv[7];
  var v8 = _iv0;
  var v9 = _iv1;
  var v10 = _iv2;
  var v11 = _iv3;
  var v12 = counter & _mask32;
  var v13 = (counter >>> 32) & _mask32;
  var v14 = blockLen;
  var v15 = flags;

  final m0 = words[wordOffset];
  final m1 = words[wordOffset + 1];
  final m2 = words[wordOffset + 2];
  final m3 = words[wordOffset + 3];
  final m4 = words[wordOffset + 4];
  final m5 = words[wordOffset + 5];
  final m6 = words[wordOffset + 6];
  final m7 = words[wordOffset + 7];
  final m8 = words[wordOffset + 8];
  final m9 = words[wordOffset + 9];
  final m10 = words[wordOffset + 10];
  final m11 = words[wordOffset + 11];
  final m12 = words[wordOffset + 12];
  final m13 = words[wordOffset + 13];
  final m14 = words[wordOffset + 14];
  final m15 = words[wordOffset + 15];

  // Seven rounds with the BLAKE3 message schedule pre-permuted per round.
  // Round 0: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  v0 = (v0 + v4 + m0) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m1) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m2) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m3) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m4) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m5) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m6) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m7) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m8) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m9) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m10) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m11) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m12) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m13) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m14) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m15) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  // Round 1: [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
  v0 = (v0 + v4 + m2) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m6) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m3) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m10) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m7) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m0) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m4) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m13) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m1) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m11) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m12) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m5) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m9) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m14) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m15) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m8) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  // Round 2: [3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1]
  v0 = (v0 + v4 + m3) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m4) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m10) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m12) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m13) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m2) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m7) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m14) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m6) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m5) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m9) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m0) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m11) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m15) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m8) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m1) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  // Round 3: [10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6]
  v0 = (v0 + v4 + m10) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m7) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m12) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m9) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m14) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m3) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m13) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m15) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m4) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m0) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m11) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m2) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m5) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m8) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m1) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m6) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  // Round 4: [12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4]
  v0 = (v0 + v4 + m12) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m13) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m9) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m11) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m15) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m10) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m14) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m8) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m7) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m2) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m5) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m3) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m0) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m1) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m6) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m4) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  // Round 5: [9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7]
  v0 = (v0 + v4 + m9) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m14) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m11) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m5) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m8) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m12) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m15) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m1) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m13) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m3) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m0) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m10) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m2) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m6) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m4) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m7) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  // Round 6: [11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13]
  v0 = (v0 + v4 + m11) & _mask32;
  v12 = _rotr16(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr12(v4 ^ v8);
  v0 = (v0 + v4 + m15) & _mask32;
  v12 = _rotr8(v12 ^ v0);
  v8 = (v8 + v12) & _mask32;
  v4 = _rotr7(v4 ^ v8);

  v1 = (v1 + v5 + m5) & _mask32;
  v13 = _rotr16(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr12(v5 ^ v9);
  v1 = (v1 + v5 + m0) & _mask32;
  v13 = _rotr8(v13 ^ v1);
  v9 = (v9 + v13) & _mask32;
  v5 = _rotr7(v5 ^ v9);

  v2 = (v2 + v6 + m1) & _mask32;
  v14 = _rotr16(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr12(v6 ^ v10);
  v2 = (v2 + v6 + m9) & _mask32;
  v14 = _rotr8(v14 ^ v2);
  v10 = (v10 + v14) & _mask32;
  v6 = _rotr7(v6 ^ v10);

  v3 = (v3 + v7 + m8) & _mask32;
  v15 = _rotr16(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr12(v7 ^ v11);
  v3 = (v3 + v7 + m6) & _mask32;
  v15 = _rotr8(v15 ^ v3);
  v11 = (v11 + v15) & _mask32;
  v7 = _rotr7(v7 ^ v11);

  v0 = (v0 + v5 + m14) & _mask32;
  v15 = _rotr16(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr12(v5 ^ v10);
  v0 = (v0 + v5 + m10) & _mask32;
  v15 = _rotr8(v15 ^ v0);
  v10 = (v10 + v15) & _mask32;
  v5 = _rotr7(v5 ^ v10);

  v1 = (v1 + v6 + m2) & _mask32;
  v12 = _rotr16(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr12(v6 ^ v11);
  v1 = (v1 + v6 + m12) & _mask32;
  v12 = _rotr8(v12 ^ v1);
  v11 = (v11 + v12) & _mask32;
  v6 = _rotr7(v6 ^ v11);

  v2 = (v2 + v7 + m3) & _mask32;
  v13 = _rotr16(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr12(v7 ^ v8);
  v2 = (v2 + v7 + m4) & _mask32;
  v13 = _rotr8(v13 ^ v2);
  v8 = (v8 + v13) & _mask32;
  v7 = _rotr7(v7 ^ v8);

  v3 = (v3 + v4 + m7) & _mask32;
  v14 = _rotr16(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr12(v4 ^ v9);
  v3 = (v3 + v4 + m13) & _mask32;
  v14 = _rotr8(v14 ^ v3);
  v9 = (v9 + v14) & _mask32;
  v4 = _rotr7(v4 ^ v9);

  out[0] = v0 ^ v8;
  out[1] = v1 ^ v9;
  out[2] = v2 ^ v10;
  out[3] = v3 ^ v11;
  out[4] = v4 ^ v12;
  out[5] = v5 ^ v13;
  out[6] = v6 ^ v14;
  out[7] = v7 ^ v15;
}

/// Loads up to 64 bytes from `bytes[start .. start + length)` as little-endian
/// 32-bit words into the reused 16-word [block] scratch buffer, zero-padding
/// any remaining bytes/words.
void _loadBlockWords(Uint8List bytes, int start, int length, Uint32List block) {
  final fullWords = length >> 2;
  for (var i = 0; i < fullWords; i++) {
    final o = start + (i << 2);
    block[i] =
        bytes[o] |
        (bytes[o + 1] << 8) |
        (bytes[o + 2] << 16) |
        (bytes[o + 3] << 24);
  }
  var nextWord = fullWords;
  final remaining = length & 3;
  if (remaining != 0) {
    final tail = start + (fullWords << 2);
    var word = bytes[tail];
    if (remaining > 1) word |= bytes[tail + 1] << 8;
    if (remaining > 2) word |= bytes[tail + 2] << 16;
    block[nextWord++] = word;
  }
  for (var i = nextWord; i < 16; i++) {
    block[i] = 0;
  }
}

/// Compresses one chunk of `bytes[start .. start + chunkLength)` into [cv].
///
/// Pass [extraEndFlags] = `_flagRoot` when this chunk is the entire input, or
/// `0` when it feeds into a parent node.
void _compressChunk(
  Uint8List bytes,
  Uint32List? alignedWords,
  int start,
  int chunkLength,
  int counter,
  int extraEndFlags,
  Uint32List cv,
  Uint32List block,
) {
  cv[0] = _iv0;
  cv[1] = _iv1;
  cv[2] = _iv2;
  cv[3] = _iv3;
  cv[4] = _iv4;
  cv[5] = _iv5;
  cv[6] = _iv6;
  cv[7] = _iv7;

  var pos = 0;
  while (true) {
    final remaining = chunkLength - pos;
    final isLastBlock = remaining <= _blockLen;
    final blockLen = isLastBlock ? remaining : _blockLen;
    var flags = 0;
    if (pos == 0) flags |= _flagChunkStart;
    if (isLastBlock) flags |= _flagChunkEnd | extraEndFlags;
    if (blockLen == _blockLen && alignedWords != null) {
      // Full 64-byte block on a 4-byte-aligned little-endian buffer: read
      // message words directly from the view without copying into [block].
      _compress(
        cv,
        alignedWords,
        (start + pos) >> 2,
        counter,
        _blockLen,
        flags,
        cv,
      );
    } else {
      _loadBlockWords(bytes, start + pos, blockLen, block);
      _compress(cv, block, 0, counter, blockLen, flags, cv);
    }
    if (isLastBlock) return;
    pos += _blockLen;
  }
}

/// Compresses the parent node of `cvStack[leftOffset .. leftOffset + 8)` and
/// `cv[0..8)`, overwriting [cv] with the resulting chaining value (or root
/// digest when `_flagRoot` is included in [flags]).
void _compressParent(
  Uint32List cvStack,
  int leftOffset,
  Uint32List cv,
  Uint32List block,
  int flags,
) {
  for (var i = 0; i < 8; i++) {
    block[i] = cvStack[leftOffset + i];
    block[i + 8] = cv[i];
  }
  _compress(_ivWords, block, 0, 0, _blockLen, flags, cv);
}

/// Computes the 8-word (32-byte) BLAKE3 root digest of [bytes] into [cv].
///
/// All scratch storage (`block`, optional `alignedWords` view, and `cvStack`
/// for multi-chunk inputs) is allocated once here and reused across every
/// block and chunk. Nothing escapes [blake3Hex].
void _hashInto(Uint8List bytes, Uint32List cv) {
  final length = bytes.length;
  final alignedWords =
      length >= _blockLen &&
          Endian.host == Endian.little &&
          (bytes.offsetInBytes & 3) == 0
      ? Uint32List.view(bytes.buffer, bytes.offsetInBytes, length >> 2)
      : null;
  final block = Uint32List(16);

  if (length <= _chunkLen) {
    _compressChunk(bytes, alignedWords, 0, length, 0, _flagRoot, cv, block);
    return;
  }

  // Flat stack of 8-word chaining values. After processing k < numChunks
  // chunks, the stack holds popcount(k) <= (numChunks - 1).bitLength entries.
  final numChunks = (length + _chunkLen - 1) ~/ _chunkLen;
  final cvStack = Uint32List((numChunks - 1).bitLength * 8);
  var stackLen = 0;
  var offset = 0;
  var chunkCounter = 0;

  while (true) {
    final remaining = length - offset;
    final isLastChunk = remaining <= _chunkLen;
    final chunkLength = isLastChunk ? remaining : _chunkLen;
    _compressChunk(
      bytes,
      alignedWords,
      offset,
      chunkLength,
      chunkCounter,
      0,
      cv,
      block,
    );
    if (isLastChunk) {
      while (stackLen > 0) {
        stackLen--;
        final flags = stackLen == 0 ? (_flagParent | _flagRoot) : _flagParent;
        _compressParent(cvStack, stackLen * 8, cv, block, flags);
      }
      return;
    }

    var totalChunks = chunkCounter + 1;
    while ((totalChunks & 1) == 0) {
      stackLen--;
      _compressParent(cvStack, stackLen * 8, cv, block, _flagParent);
      totalChunks >>>= 1;
    }

    final dstOffset = stackLen * 8;
    for (var i = 0; i < 8; i++) {
      cvStack[dstOffset + i] = cv[i];
    }
    stackLen++;
    offset += _chunkLen;
    chunkCounter++;
  }
}

/// Formats 8 little-endian 32-bit digest words as a 64-character lowercase hex
/// string using a single 64-byte ASCII code-unit buffer.
String _encodeHex(Uint32List digestWords) {
  final hex = Uint8List(64);
  for (var i = 0; i < 8; i++) {
    final word = digestWords[i];
    final b0 = word & 0xFF;
    final b1 = (word >>> 8) & 0xFF;
    final b2 = (word >>> 16) & 0xFF;
    final b3 = (word >>> 24) & 0xFF;
    final o = i * 8;
    hex[o] = _hexDigits[b0 >>> 4];
    hex[o + 1] = _hexDigits[b0 & 0xF];
    hex[o + 2] = _hexDigits[b1 >>> 4];
    hex[o + 3] = _hexDigits[b1 & 0xF];
    hex[o + 4] = _hexDigits[b2 >>> 4];
    hex[o + 5] = _hexDigits[b2 & 0xF];
    hex[o + 6] = _hexDigits[b3 >>> 4];
    hex[o + 7] = _hexDigits[b3 & 0xF];
  }
  return String.fromCharCodes(hex);
}
