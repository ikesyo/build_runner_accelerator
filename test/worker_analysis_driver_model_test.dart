import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_runner_accelerator/src/api_fingerprint.dart';
import 'package:build_runner_accelerator/src/blake3.dart';
import 'package:build_runner_accelerator/src/indexed_blob_store.dart';
import 'package:build_runner_accelerator/src/worker_analysis_driver_model.dart';
import 'package:test/test.dart';

void main() {
  final idA = AssetId('app', 'lib/a.dart');
  final idB = AssetId('app', 'lib/b.dart');
  const sourceA = 'int alpha() => 1;\n';
  const sourceB = 'String beta() => "b";\n';

  group('ApiFingerprintLedger', () {
    late Directory dir;
    late ApiFingerprintCache cache;

    setUp(() {
      final previousVersions = ApiFingerprintCache.packageLanguageVersions;
      addTearDown(
        () => ApiFingerprintCache.packageLanguageVersions = previousVersions,
      );
      ApiFingerprintCache.packageLanguageVersions = {'app': '3.13'};

      dir = Directory.systemTemp.createTempSync('api-fingerprint-ledger-');
      addTearDown(() => dir.deleteSync(recursive: true));
      cache = ApiFingerprintCache(
        store: IndexedBlobStore('${dir.path}/store.bin'),
      );
    });

    test('defaults to learning disabled and an empty learned map', () {
      final ledger = ApiFingerprintLedger();
      expect(ledger.learningEnabled, isFalse);
      expect(ledger.learned, isEmpty);
    });

    test('two ledgers do not share learning flag or learned entries', () {
      final ledgerA = ApiFingerprintLedger();
      final ledgerB = ApiFingerprintLedger();

      ledgerA.learningEnabled = true;
      expect(ledgerA.learningEnabled, isTrue);
      expect(ledgerB.learningEnabled, isFalse);

      ledgerA.record(idA, sourceA, cache: cache);
      expect(ledgerA.learned.keys, [idA.toString()]);
      expect(ledgerB.learned, isEmpty);

      ledgerB.record(idB, sourceB, cache: cache);
      expect(ledgerB.learned.keys, [idB.toString()]);

      ledgerA.clear();
      expect(ledgerA.learned, isEmpty);
      expect(ledgerB.learned.keys, [idB.toString()]);
    });

    test('invalidate removes only specified assets and clears their memos', () {
      final ledger = ApiFingerprintLedger();
      final keyA = idA.toString();
      final keyB = idB.toString();
      final expectedDigestA = blake3Hex(utf8.encode(sourceA));
      final expectedFingerprintA = apiFingerprintForContent(
        sourceA,
        package: 'app',
      );
      expect(expectedFingerprintA, isNotNull);

      ledger.record(idA, sourceA, cache: cache);
      ledger.record(idB, sourceB, cache: cache);
      final entryB = ledger.learned[keyB];
      expect(entryB, isNotNull);

      // With identical content memoized, record returns early without
      // overwriting the learned entry.
      const sentinel = (digest: 'sentinel', fingerprint: 'sentinel');
      ledger.learned[keyA] = sentinel;
      ledger.record(idA, sourceA, cache: cache);
      expect(ledger.learned[keyA], sentinel);

      // Invalidating idA drops both its learned value and its memos, while
      // leaving idB untouched.
      ledger.invalidate([idA]);
      expect(ledger.learned.containsKey(keyA), isFalse);
      expect(ledger.learned[keyB], entryB);

      // Recording the exact same sourceA instance after invalidate must
      // recompute rather than hit a stale memo.
      ledger.record(idA, sourceA, cache: cache);
      expect(ledger.learned[keyA], (
        digest: expectedDigestA,
        fingerprint: expectedFingerprintA,
      ));
    });

    test('clear empties learned entries and resets memos', () {
      final ledger = ApiFingerprintLedger();
      final keyA = idA.toString();
      final expectedDigestA = blake3Hex(utf8.encode(sourceA));
      final expectedFingerprintA = apiFingerprintForContent(
        sourceA,
        package: 'app',
      );

      ledger.record(idA, sourceA, cache: cache);
      ledger.record(idB, sourceB, cache: cache);
      expect(ledger.learned, hasLength(2));

      ledger.clear();
      expect(ledger.learned, isEmpty);

      // Re-recording the same content instance after clear repopulates learned.
      ledger.record(idA, sourceA, cache: cache);
      expect(ledger.learned[keyA], (
        digest: expectedDigestA,
        fingerprint: expectedFingerprintA,
      ));
    });

    test('frontendDigest path binds cached entry only to matching bytes', () {
      final ledger = ApiFingerprintLedger();
      final keyA = idA.toString();
      final digestA = blake3Hex(utf8.encode(sourceA));
      final digestB = blake3Hex(utf8.encode(sourceB));
      final fingerprintA = cache.fingerprintFor(
        digestA,
        sourceA,
        package: 'app',
      );
      final fingerprintB = apiFingerprintForContent(sourceB, package: 'app');
      expect(fingerprintA, isNotNull);
      expect(fingerprintB, isNotNull);

      ledger.record(idA, sourceA, cache: cache, frontendDigest: digestA);
      expect(ledger.learned[keyA], (
        digest: digestA,
        fingerprint: fingerprintA,
      ));

      // Newer content arriving under the stale snapshot digest must not reuse
      // the cached fingerprint for digestA.
      ledger.record(idA, sourceB, cache: cache, frontendDigest: digestA);
      expect(ledger.learned[keyA], (
        digest: digestB,
        fingerprint: fingerprintB,
      ));
    });

    test('closing AST model gate replaces memoized value with unavailable', () {
      final ledger = ApiFingerprintLedger();
      final keyA = idA.toString();
      final digestA = blake3Hex(utf8.encode(sourceA));

      ledger.record(idA, sourceA, cache: cache);
      expect(ledger.learned[keyA]?.fingerprint, isNotNull);

      debugSetAstModelSupported(false);
      addTearDown(() => debugSetAstModelSupported(null));

      // Even with the identical content string, closing the AST model gate must
      // record the unavailable marker instead of memo-hitting the old value.
      ledger.record(idA, sourceA, cache: cache);
      expect(ledger.learned[keyA], (digest: digestA, fingerprint: null));

      // Subsequent visit with identical content while closed keeps unavailable.
      ledger.record(idA, sourceA, cache: cache);
      expect(ledger.learned[keyA], (digest: digestA, fingerprint: null));
    });
  });

  group('WorkerAnalysisDriverModel', () {
    test('two instances isolate fingerprintLearningEnabled', () {
      final modelA = WorkerAnalysisDriverModel();
      final modelB = WorkerAnalysisDriverModel();

      expect(modelA.fingerprintLearningEnabled, isFalse);
      expect(modelB.fingerprintLearningEnabled, isFalse);

      modelA.setFingerprintLearningEnabled(true);
      expect(modelA.fingerprintLearningEnabled, isTrue);
      expect(modelB.fingerprintLearningEnabled, isFalse);

      modelB.setFingerprintLearningEnabled(true);
      modelA.setFingerprintLearningEnabled(false);
      expect(modelA.fingerprintLearningEnabled, isFalse);
      expect(modelB.fingerprintLearningEnabled, isTrue);
    });

    test(
      'two instances isolate learnedApiFingerprints, invalidate, and clear',
      () {
        final modelA = WorkerAnalysisDriverModel();
        final modelB = WorkerAnalysisDriverModel();
        final keyA = idA.toString();
        final keyB = idB.toString();
        const entryA = (digest: 'digest-a', fingerprint: 'fp-a');
        const entryB = (digest: 'digest-b', fingerprint: 'fp-b');

        expect(modelA.learnedApiFingerprints(), isEmpty);
        expect(modelB.learnedApiFingerprints(), isEmpty);
        expect(
          modelA.learnedApiFingerprints(),
          isNot(same(modelB.learnedApiFingerprints())),
        );

        modelA.learnedApiFingerprints()[keyA] = entryA;
        modelA.learnedApiFingerprints()[keyB] = entryB;
        modelB.learnedApiFingerprints()[keyA] = entryA;

        modelA.invalidatePendingFingerprints([idA]);
        expect(modelA.learnedApiFingerprints().containsKey(keyA), isFalse);
        expect(modelA.learnedApiFingerprints()[keyB], entryB);
        expect(modelB.learnedApiFingerprints()[keyA], entryA);

        modelA.clearLearnedApiFingerprints();
        expect(modelA.learnedApiFingerprints(), isEmpty);
        expect(modelB.learnedApiFingerprints()[keyA], entryA);
      },
    );
  });
}
