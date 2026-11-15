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
  final digest = _hash(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  final hex = StringBuffer();
  for (final byte in digest) {
    hex.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

const _iv = <int>[
  0x6A09E667,
  0xBB67AE85,
  0x3C6EF372,
  0xA54FF53A,
  0x510E527F,
  0x9B05688C,
  0x1F83D9AB,
  0x5BE0CD19,
];

const _msgPermutation = <int>[
  2,
  6,
  3,
  10,
  7,
  0,
  4,
  13,
  1,
  11,
  12,
  5,
  9,
  14,
  15,
  8,
];

const _blockLen = 64;
const _chunkLen = 1024;
const _flagChunkStart = 1 << 0;
const _flagChunkEnd = 1 << 1;
const _flagParent = 1 << 2;
const _flagRoot = 1 << 3;
const _mask32 = 0xFFFFFFFF;

int _rotr32(int value, int count) =>
    ((value >> count) | (value << (32 - count))) & _mask32;

/// The BLAKE3 compression function over one 64-byte block of words.
Uint32List _compress(
  Uint32List cv,
  Uint32List block,
  int counter,
  int blockLen,
  int flags,
) {
  final state = Uint32List(16);
  state.setRange(0, 8, cv);
  state[8] = _iv[0];
  state[9] = _iv[1];
  state[10] = _iv[2];
  state[11] = _iv[3];
  state[12] = counter & _mask32;
  state[13] = (counter >> 32) & _mask32;
  state[14] = blockLen;
  state[15] = flags;

  void g(int a, int b, int c, int d, int x, int y) {
    state[a] = (state[a] + state[b] + x) & _mask32;
    state[d] = _rotr32(state[d] ^ state[a], 16);
    state[c] = (state[c] + state[d]) & _mask32;
    state[b] = _rotr32(state[b] ^ state[c], 12);
    state[a] = (state[a] + state[b] + y) & _mask32;
    state[d] = _rotr32(state[d] ^ state[a], 8);
    state[c] = (state[c] + state[d]) & _mask32;
    state[b] = _rotr32(state[b] ^ state[c], 7);
  }

  void round(Uint32List m) {
    g(0, 4, 8, 12, m[0], m[1]);
    g(1, 5, 9, 13, m[2], m[3]);
    g(2, 6, 10, 14, m[4], m[5]);
    g(3, 7, 11, 15, m[6], m[7]);
    g(0, 5, 10, 15, m[8], m[9]);
    g(1, 6, 11, 12, m[10], m[11]);
    g(2, 7, 8, 13, m[12], m[13]);
    g(3, 4, 9, 14, m[14], m[15]);
  }

  var message = block;
  for (var roundIndex = 0; roundIndex < 7; roundIndex++) {
    round(message);
    if (roundIndex < 6) {
      final permuted = Uint32List(16);
      for (var i = 0; i < 16; i++) {
        permuted[i] = message[_msgPermutation[i]];
      }
      message = permuted;
    }
  }

  final out = Uint32List(16);
  for (var i = 0; i < 8; i++) {
    out[i] = state[i + 8] ^ state[i];
    out[i + 8] = state[i] ^ cv[i];
  }
  return out;
}

/// One block's compression output, from which either a chaining value or
/// root output bytes are derived.
class _Output {
  _Output(
    this.inputCv,
    this.blockWords,
    this.counter,
    this.blockLen,
    this.flags,
  );

  final Uint32List inputCv;
  final Uint32List blockWords;
  final int counter;
  final int blockLen;
  final int flags;

  Uint32List chainingValue() {
    final out = _compress(inputCv, blockWords, counter, blockLen, flags);
    return Uint32List.sublistView(out, 0, 8);
  }

  Uint8List rootBytes() {
    final out = _compress(
      inputCv,
      blockWords,
      counter,
      blockLen,
      flags | _flagRoot,
    );
    final bytes = Uint8List(32);
    final view = ByteData.view(bytes.buffer);
    for (var i = 0; i < 8; i++) {
      view.setUint32(i * 4, out[i], Endian.little);
    }
    return bytes;
  }
}

Uint32List _blockWords(Uint8List bytes, int start, int length) {
  final words = Uint32List(16);
  final view = ByteData.view(bytes.buffer, bytes.offsetInBytes + start);
  for (var i = 0; i < length ~/ 4; i++) {
    words[i] = view.getUint32(i * 4, Endian.little);
  }
  // A trailing partial word is zero-padded; whole words were read above.
  final remaining = length % 4;
  if (remaining > 0) {
    var word = 0;
    for (var i = 0; i < remaining; i++) {
      word |= bytes[start + (length ~/ 4) * 4 + i] << (8 * i);
    }
    words[length ~/ 4] = word;
  }
  return words;
}

_Output _chunkOutput(Uint8List bytes, int start, int length, int counter) {
  var cv = Uint32List.fromList(_iv);
  var pos = 0;
  while (true) {
    final remaining = length - pos;
    final isLastBlock = remaining <= _blockLen;
    final blockLen = isLastBlock ? remaining : _blockLen;
    var flags = 0;
    if (pos == 0) flags |= _flagChunkStart;
    if (isLastBlock) flags |= _flagChunkEnd;
    final output = _Output(
      cv,
      _blockWords(bytes, start + pos, blockLen),
      counter,
      blockLen,
      flags,
    );
    if (isLastBlock) return output;
    cv = output.chainingValue();
    pos += _blockLen;
  }
}

_Output _parentOutput(Uint32List leftCv, Uint32List rightCv) {
  final block = Uint32List(16);
  block.setRange(0, 8, leftCv);
  block.setRange(8, 16, rightCv);
  return _Output(Uint32List.fromList(_iv), block, 0, _blockLen, _flagParent);
}

Uint8List _hash(Uint8List bytes) {
  final cvStack = <Uint32List>[];
  var offset = 0;
  var chunkCounter = 0;
  while (true) {
    final remaining = bytes.length - offset;
    final isLastChunk = remaining <= _chunkLen;
    final chunkLength = isLastChunk ? remaining : _chunkLen;
    final output = _chunkOutput(bytes, offset, chunkLength, chunkCounter);
    if (isLastChunk) {
      var root = output;
      while (cvStack.isNotEmpty) {
        root = _parentOutput(cvStack.removeLast(), root.chainingValue());
      }
      return root.rootBytes();
    }
    var cv = output.chainingValue();
    var totalChunks = chunkCounter + 1;
    while (totalChunks % 2 == 0) {
      cv = _parentOutput(cvStack.removeLast(), cv).chainingValue();
      totalChunks ~/= 2;
    }
    cvStack.add(cv);
    offset += _chunkLen;
    chunkCounter++;
  }
}
