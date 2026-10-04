# Resolver collector content digest reuse (2026-10-04)

## Scope and decision

Baseline is unchanged PR #84 head `838f4604255a77094c98bb342ebe0c5ec3456116`
(`perf/resolver-conditional-directive-cache`), open and unmerged at the start.
The native frontend is identical in both lanes. The candidate changes the Dart
worker read cache and collector; scheduler, worker cap, single-flight defaults,
cache compaction and the Rust protocol are unchanged.

Use the existing read-cache lifetime for an owned immutable typed-byte snapshot
with a lazy content-only SHA-256. Cached collector reads avoid a mutable copy
and reuse that snapshot's digest after the usual action visibility and observed
read checks. Public builder reads still receive mutable copies. Insertion copies
caller buffers; replacement always creates a new snapshot; eviction and clear
remove bytes and digest together. Updated/deleted source/cache deltas evict IDs
before phase/incremental resolver resets; unchanged entries survive those
resets. Build start and failure recovery clear the caches. Mutable action-local
outputs receive fresh snapshots on each read, including same-action/post-process
rewrites. Missing/blocked assets remain retried. Relative/conditional URI mapping
and read dependency recording are unchanged.

This is shared byte ownership between ReaderWriter and collector, not an
algorithm substitution. `AssetContent.digest` is MD5 and `withBytes` can preserve
an old digest; ReaderWriter's MD5 includes AssetId; Rust snapshots use FNV-1a.
None proves the collector's exact-byte SHA-256 key. No validity inference uses
AssetId, mtime, or caller object identity. Broader MD5/Rust digest consolidation
would require its own measured benefit and exact input/lifetime contract.

## Method

Linux managed container, 2 CPU quota, 8 GiB memory; Dart 3.13.3 and Rust 1.98.1.
Pinned shared pub cache: build 4.0.10, build_runner 2.16.1, analyzer 14.3.0,
riverpod_generator 4.0.9, freezed 4.0.1, json_serializable 6.14.1.
AOT baseline/candidate workers are compiled outside timing with identical
resolved package configurations except the accelerator package root. Identical
native release executable; explicit worker paths exclude launcher, manifest/AOT
compilation and AOT validation. SDK summaries are primed outside timing. OS page
cache is not flushed. Results describe native execution in these fixtures.

Five paired samples per jobs=1/2/4 and cache policy, alternating AB/BA order.
Timing runs set metrics=0 and trace=0. Each lane starts with the same empty byte
store and graph, builds cold, removes graph/generated outputs for warm-clean,
then performs no-op, a real provider-name edit in one input, and real provider-name
edits in all inputs. Fresh policy clears directive caches; retained policy keeps
them across pairs while clearing analyzer byte storage. Thus "cold" under
retained policy does not mean an empty directive cache. Both lanes publish and
read their caches normally. Each build's generated source and `.g.part` bytes
are checked against untimed stock build_runner references for the same edits.

Fixtures:

- `two`: tracked two-input Riverpod/Freezed/JSON fixture; six generated files.
- `shared`: 24 Riverpod inputs share eight ordinary libraries, each containing
  256 classes (~32 KiB). 32 source files and 48 generated files.
- `conditional`: 24 inputs share eight conditional API pairs, with distinct
  bytes in default/io implementations (16 shared sources). 40 source files and
  48 generated files. This deliberately exercises per-action candidate reads.

No real application source was available. These measurements do not establish
application speedups or improvements on every workload. No-op does not run the
worker; its small percentage differences cannot be attributed to this change.

Worker isolation follows the [PR #84 reproduction procedure](resolver-conditional-directives-2026-10.md#reproduction),
but bind the baseline accelerator package to `838f460` rather than pre-PR main.
Generate the fixture's catalog first, then compile the same worker entrypoint
with package configs differing only in that root. Keep executables under the
fixture's `aot-sdk/bin` with SDK `lib`/`version` links; use the actual Dart SDK
binary for `--frontend-dart`/`--dart`, not a shell wrapper. Set an explicit cache
outside the watched workspace for verification.

Reproduction (disposable fixture/cache only):

```bash
python3 scripts/prepare_resolver_digest_fixture.py --root /absolute/new/fixture
# Add --ordinary-imports for the ordinary-sharing fixture.
# Resolve pub, prime native/SDK summaries, compile both isolated workers first.
python3 scripts/benchmark_cold_build.py \
  --baseline "$native" --candidate "$native" --frontend-dart "$dart" \
  --root "$fixture" --cache "$cache" \
  --worker "$baseline_worker" --candidate-worker "$candidate_worker" \
  --fixture-kind riverpod-shared --stock-check --jobs 1 2 4 --repeats 5 \
  --results "$results"
# Repeat with --retain-dep-parse. Use --fixture-kind riverpod for two inputs.
# Diagnostics are a separate --metrics --retain-dep-parse --repeats 3 run.
```

`metadata.json` records SDK/cache policy, executable/worker/config/lock/input
hashes; `builds.json` records exact commands and output hashes; `summary.json`
contains individual samples and distributions. Diagnostics are whole-build
sums across workers, then medians across three repeats; they are not wall-time
savings. Baseline digest call count is inferred from collector cache hit/miss
counts (one digest per successful collected read); baseline reuses are zero.
Candidate has explicit computation/reuse counters. All warm diagnostic parses
are zero.

## Measurements

All entries are milliseconds: median [minimum, maximum], five samples per
lane. Delta is candidate/baseline minus one; negative means faster.

### Two inputs, fresh directive cache

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 880.2 [834.7, 984.1] | 843.9 [743.1, 963.5] | -4.1% |
| 1 | warm-clean | 316.1 [263.8, 389.5] | 284.5 [234.4, 389.1] | -10.0% |
| 1 | no-op | 11.4 [8.9, 12.5] | 10.2 [8.6, 16.1] | -10.9% |
| 1 | one-file | 298.2 [247.1, 302.2] | 262.0 [232.3, 291.4] | -12.1% |
| 1 | broad | 302.6 [290.6, 327.9] | 289.1 [232.4, 347.0] | -4.4% |
| 2 | cold | 872.3 [827.3, 1024.6] | 846.5 [805.9, 868.9] | -3.0% |
| 2 | warm-clean | 317.2 [277.3, 402.2] | 271.8 [258.5, 433.8] | -14.3% |
| 2 | no-op | 10.0 [8.3, 10.4] | 9.4 [7.8, 13.3] | -5.5% |
| 2 | one-file | 288.6 [256.7, 353.8] | 220.4 [206.6, 269.0] | -23.6% |
| 2 | broad | 321.5 [271.7, 390.8] | 309.4 [259.9, 476.1] | -3.8% |
| 4 | cold | 862.4 [809.7, 1000.1] | 777.3 [730.6, 848.9] | -9.9% |
| 4 | warm-clean | 324.2 [308.8, 532.1] | 269.8 [226.7, 313.3] | -16.8% |
| 4 | no-op | 9.6 [8.7, 12.4] | 9.7 [8.2, 15.4] | +1.1% |
| 4 | one-file | 249.6 [235.9, 315.2] | 212.5 [202.2, 223.3] | -14.9% |
| 4 | broad | 332.7 [310.7, 432.2] | 271.6 [260.4, 284.6] | -18.4% |

### Two inputs, retained directive cache

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 596.6 [572.1, 694.9] | 569.1 [539.4, 598.2] | -4.6% |
| 1 | warm-clean | 259.3 [234.6, 308.2] | 203.4 [198.2, 304.0] | -21.6% |
| 1 | no-op | 9.3 [8.1, 10.8] | 8.3 [7.8, 8.7] | -11.2% |
| 1 | one-file | 255.5 [234.1, 261.0] | 218.2 [212.8, 227.8] | -14.6% |
| 1 | broad | 257.0 [237.7, 318.9] | 226.6 [219.0, 245.7] | -11.9% |
| 2 | cold | 796.5 [705.2, 835.7] | 772.2 [690.8, 787.9] | -3.0% |
| 2 | warm-clean | 315.7 [288.4, 352.4] | 287.9 [252.9, 344.5] | -8.8% |
| 2 | no-op | 9.3 [7.6, 13.1] | 10.4 [8.3, 16.3] | +11.9% |
| 2 | one-file | 256.2 [228.8, 297.6] | 229.5 [208.8, 248.1] | -10.4% |
| 2 | broad | 322.8 [293.3, 364.3] | 296.0 [253.9, 298.9] | -8.3% |
| 4 | cold | 712.2 [709.6, 779.7] | 692.5 [649.7, 784.5] | -2.8% |
| 4 | warm-clean | 300.2 [280.7, 320.1] | 287.6 [250.0, 394.4] | -4.2% |
| 4 | no-op | 8.8 [8.3, 9.4] | 9.0 [8.5, 11.7] | +2.9% |
| 4 | one-file | 249.4 [230.6, 261.6] | 224.8 [216.9, 252.8] | -9.9% |
| 4 | broad | 309.1 [274.4, 373.5] | 280.9 [236.5, 290.0] | -9.1% |

### Ordinary shared sources, fresh directive cache

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 945.8 [923.9, 998.8] | 950.8 [853.0, 1022.7] | +0.5% |
| 1 | warm-clean | 318.6 [315.8, 334.9] | 316.8 [303.0, 359.1] | -0.6% |
| 1 | no-op | 12.5 [10.7, 60.7] | 12.2 [10.8, 12.8] | -2.9% |
| 1 | one-file | 260.6 [248.1, 302.6] | 209.0 [201.4, 296.2] | -19.8% |
| 1 | broad | 365.4 [322.8, 380.2] | 337.3 [327.9, 382.3] | -7.7% |
| 2 | cold | 1176.9 [977.5, 1346.1] | 1118.6 [1055.1, 1306.7] | -4.9% |
| 2 | warm-clean | 369.5 [343.3, 456.9] | 355.4 [326.4, 364.9] | -3.8% |
| 2 | no-op | 11.0 [10.7, 14.4] | 12.2 [10.5, 13.4] | +10.2% |
| 2 | one-file | 262.2 [229.8, 358.5] | 216.2 [200.3, 220.6] | -17.5% |
| 2 | broad | 394.3 [364.3, 422.7] | 349.2 [340.3, 397.4] | -11.4% |
| 4 | cold | 1144.0 [1113.6, 1266.4] | 1081.0 [1052.3, 1337.4] | -5.5% |
| 4 | warm-clean | 366.2 [338.8, 428.6] | 337.7 [324.2, 388.6] | -7.8% |
| 4 | no-op | 12.6 [11.7, 21.1] | 11.2 [11.0, 13.3] | -10.5% |
| 4 | one-file | 259.3 [257.7, 339.1] | 213.7 [209.1, 241.8] | -17.6% |
| 4 | broad | 389.6 [345.6, 531.9] | 349.7 [315.4, 416.3] | -10.2% |

### Ordinary shared sources, retained directive cache

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 826.0 [784.5, 924.4] | 841.4 [794.3, 905.0] | +1.9% |
| 1 | warm-clean | 323.2 [313.1, 361.0] | 313.8 [296.7, 387.3] | -2.9% |
| 1 | no-op | 11.3 [10.6, 13.6] | 11.8 [10.6, 23.4] | +3.6% |
| 1 | one-file | 313.1 [244.7, 345.8] | 226.0 [221.8, 258.3] | -27.8% |
| 1 | broad | 360.0 [334.8, 389.9] | 355.4 [315.3, 378.2] | -1.3% |
| 2 | cold | 1186.1 [1057.6, 1228.3] | 1184.2 [1110.7, 1321.3] | -0.2% |
| 2 | warm-clean | 394.0 [358.5, 439.4] | 414.3 [342.0, 459.9] | +5.2% |
| 2 | no-op | 11.9 [10.9, 15.5] | 14.2 [13.2, 20.2] | +19.8% |
| 2 | one-file | 298.3 [268.7, 356.6] | 233.7 [215.4, 277.4] | -21.7% |
| 2 | broad | 449.2 [416.0, 513.7] | 392.7 [381.1, 432.4] | -12.6% |
| 4 | cold | 1132.9 [970.8, 1403.9] | 1193.0 [953.3, 1247.9] | +5.3% |
| 4 | warm-clean | 408.0 [370.7, 485.1] | 396.5 [345.1, 496.2] | -2.8% |
| 4 | no-op | 12.2 [10.8, 14.5] | 12.6 [10.8, 31.7] | +2.5% |
| 4 | one-file | 278.7 [243.7, 296.1] | 252.1 [220.2, 254.9] | -9.5% |
| 4 | broad | 401.4 [390.0, 441.7] | 430.6 [387.5, 505.6] | +7.3% |

### Conditional shared sources, fresh directive cache

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 1553.9 [1482.9, 1631.5] | 950.9 [890.1, 984.1] | -38.8% |
| 1 | warm-clean | 960.7 [886.5, 991.0] | 348.0 [346.1, 392.1] | -63.8% |
| 1 | no-op | 12.9 [12.4, 15.2] | 14.0 [12.0, 15.5] | +8.2% |
| 1 | one-file | 295.9 [272.4, 306.5] | 248.3 [225.0, 251.3] | -16.1% |
| 1 | broad | 953.1 [922.6, 1122.8] | 426.4 [366.1, 463.3] | -55.3% |
| 2 | cold | 1591.7 [1475.4, 1655.9] | 1191.0 [1051.7, 1350.4] | -25.2% |
| 2 | warm-clean | 718.8 [683.6, 786.6] | 394.4 [381.0, 463.6] | -45.1% |
| 2 | no-op | 13.0 [12.4, 13.9] | 13.9 [13.1, 15.2] | +6.8% |
| 2 | one-file | 285.3 [273.3, 357.1] | 249.8 [213.6, 341.8] | -12.5% |
| 2 | broad | 806.3 [759.0, 897.2] | 407.4 [368.5, 462.3] | -49.5% |
| 4 | cold | 1493.9 [1422.9, 1574.9] | 1198.0 [1101.6, 1312.8] | -19.8% |
| 4 | warm-clean | 778.0 [667.5, 866.5] | 382.6 [367.1, 490.0] | -50.8% |
| 4 | no-op | 14.4 [11.7, 15.0] | 13.1 [12.1, 13.8] | -9.1% |
| 4 | one-file | 282.8 [263.7, 325.5] | 223.9 [215.1, 238.5] | -20.8% |
| 4 | broad | 825.7 [677.7, 852.3] | 377.9 [359.8, 423.0] | -54.2% |

### Conditional shared sources, retained directive cache

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 1481.6 [1470.7, 1559.5] | 868.2 [761.8, 924.3] | -41.4% |
| 1 | warm-clean | 1040.3 [868.3, 1116.5] | 378.0 [318.1, 407.2] | -63.7% |
| 1 | no-op | 14.0 [12.6, 15.9] | 12.3 [11.8, 13.2] | -12.2% |
| 1 | one-file | 300.8 [269.5, 313.3] | 221.8 [212.7, 243.1] | -26.3% |
| 1 | broad | 1019.0 [995.3, 1083.5] | 419.5 [353.9, 483.3] | -58.8% |
| 2 | cold | 1449.8 [1381.5, 1527.4] | 1091.9 [1056.1, 1135.2] | -24.7% |
| 2 | warm-clean | 861.0 [672.4, 906.1] | 386.5 [384.9, 448.8] | -55.1% |
| 2 | no-op | 13.9 [12.7, 18.5] | 13.4 [12.6, 16.6] | -3.8% |
| 2 | one-file | 281.5 [273.7, 297.3] | 241.0 [220.3, 244.8] | -14.4% |
| 2 | broad | 810.2 [751.8, 817.2] | 424.9 [382.9, 449.4] | -47.6% |
| 4 | cold | 1433.0 [1354.0, 1462.0] | 1080.1 [1015.4, 1121.3] | -24.6% |
| 4 | warm-clean | 804.1 [709.9, 849.6] | 402.5 [358.3, 455.2] | -49.9% |
| 4 | no-op | 13.0 [12.1, 13.5] | 12.9 [12.4, 14.0] | -0.4% |
| 4 | one-file | 274.5 [252.0, 282.4] | 235.2 [198.7, 239.8] | -14.3% |
| 4 | broad | 765.8 [673.8, 842.9] | 392.9 [340.2, 488.0] | -48.7% |

### Collector diagnostics (separate runs)

Warm-clean; medians of three whole-build worker sums. Time columns are
milliseconds. They do not represent wall savings. SHA count in the baseline
lane is inferred; candidate counters are explicit. Parse count is zero in
every row.

| Fixture | Jobs | Lane | SHA computations | Reuses | Digest ms | Read ms |
| --- | --- | --- | --- | --- | --- | --- |
| two | 1 | baseline | 293 | 0 | 24.256 | 19.150 |
| two | 1 | candidate | 289 | 4 | 17.082 | 0.630 |
| two | 2 | baseline | 566 | 0 | 51.212 | 37.300 |
| two | 2 | candidate | 562 | 4 | 50.821 | 1.545 |
| two | 4 | baseline | 566 | 0 | 53.689 | 39.068 |
| two | 4 | candidate | 562 | 4 | 35.925 | 1.427 |
| shared | 1 | baseline | 329 | 0 | 31.392 | 35.318 |
| shared | 1 | candidate | 305 | 24 | 20.453 | 1.195 |
| shared | 2 | baseline | 610 | 0 | 93.489 | 51.602 |
| shared | 2 | candidate | 586 | 24 | 55.387 | 4.176 |
| shared | 4 | baseline | 610 | 0 | 68.210 | 49.132 |
| shared | 4 | candidate | 586 | 24 | 49.348 | 1.720 |
| conditional | 1 | baseline | 1089 | 0 | 357.564 | 226.571 |
| conditional | 1 | candidate | 313 | 776 | 25.121 | 4.537 |
| conditional | 2 | baseline | 1362 | 0 | 541.410 | 375.651 |
| conditional | 2 | candidate | 602 | 760 | 73.723 | 8.288 |
| conditional | 4 | baseline | 1362 | 0 | 499.617 | 357.755 |
| conditional | 4 | candidate | 602 | 760 | 46.765 | 10.850 |

Ordinary imports benefit from Analyzer graph reuse already: only 24 of 329
collector hashes are reused at jobs=1, versus 776 of 1089 with shared conditional
alternatives. The two-input fixture reuses just four hashes. Reduced copying and
hashing typed bytes also contribute; attributing the entire measured wall
change to SHA memoization would be incorrect.

### SHA memoization isolation

Same candidate source and immutable-byte path, but an experimental worker
recomputes SHA-256 on each getter call. The only source change is replacing
`_digest ??= sha256.convert(bytes).toString()` with
`sha256.convert(bytes).toString()` in `AssetReadContent.contentDigest`. There
is no production option for this ablation. Separate five alternating pairs;
retained directive cache, metrics/trace off. All 150 output maps match stock.

| Jobs | Case | No memoization | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 1 | cold | 1098.4 [949.6, 1243.6] | 844.3 [785.7, 922.6] | -23.1% |
| 1 | warm-clean | 623.8 [558.2, 694.4] | 378.5 [342.9, 391.0] | -39.3% |
| 1 | no-op | 13.7 [12.3, 16.3] | 13.2 [11.4, 14.4] | -3.6% |
| 1 | one-file | 248.0 [242.9, 331.4] | 245.2 [215.2, 305.7] | -1.1% |
| 1 | broad | 656.1 [632.0, 696.4] | 373.6 [338.9, 394.2] | -43.1% |
| 2 | cold | 1239.6 [1203.3, 1330.8] | 1149.3 [1080.8, 1230.8] | -7.3% |
| 2 | warm-clean | 563.8 [532.0, 649.3] | 431.4 [377.5, 491.8] | -23.5% |
| 2 | no-op | 14.1 [12.8, 16.6] | 17.1 [12.2, 18.6] | +21.7% |
| 2 | one-file | 263.4 [242.0, 329.2] | 248.8 [243.6, 318.9] | -5.5% |
| 2 | broad | 592.0 [459.9, 608.6] | 439.1 [418.1, 494.5] | -25.8% |
| 4 | cold | 1180.4 [1157.9, 1289.0] | 1108.5 [1017.0, 1188.9] | -6.1% |
| 4 | warm-clean | 531.6 [499.3, 587.8] | 420.2 [369.6, 443.7] | -21.0% |
| 4 | no-op | 14.8 [13.2, 16.0] | 13.3 [12.0, 14.0] | -10.2% |
| 4 | one-file | 265.4 [225.2, 323.4] | 231.4 [219.8, 264.4] | -12.8% |
| 4 | broad | 580.1 [541.7, 716.9] | 412.2 [373.9, 515.6] | -28.9% |

### Ordinary-sharing repeatability check

Five additional alternating pairs with retained directive caches. The first
run had jobs=2 warm-clean +5.2%, jobs=4 cold +5.3% and broad +7.3%, all
with overlapping ranges. This second run does not repeat those regressions,
but jobs=4 one-file is +14.9%. Keep both sets: the ordinary-sharing workload
does not establish uniform improvement. All 100 output maps match stock.

| Jobs | Case | PR #84 | Candidate | Delta |
| --- | --- | --- | --- | --- |
| 2 | cold | 1087.6 [1020.3, 1236.1] | 1085.0 [958.6, 1157.6] | -0.2% |
| 2 | warm-clean | 424.8 [377.7, 485.4] | 365.7 [310.4, 407.1] | -13.9% |
| 2 | no-op | 11.9 [11.6, 14.5] | 10.6 [10.3, 54.2] | -11.2% |
| 2 | one-file | 273.8 [262.9, 291.1] | 227.2 [208.1, 260.2] | -17.0% |
| 2 | broad | 385.3 [349.3, 451.2] | 385.6 [322.2, 395.2] | +0.1% |
| 4 | cold | 1087.3 [943.6, 1124.3] | 978.5 [904.5, 1216.6] | -10.0% |
| 4 | warm-clean | 393.1 [358.0, 482.6] | 342.5 [307.1, 396.5] | -12.9% |
| 4 | no-op | 12.1 [11.7, 12.6] | 12.3 [10.7, 15.9] | +1.6% |
| 4 | one-file | 252.7 [235.0, 298.2] | 290.3 [212.5, 322.6] | +14.9% |
| 4 | broad | 382.3 [358.3, 405.3] | 364.2 [342.5, 453.7] | -4.7% |

### PR #84 jobs=4 supplemental comparison

Unchanged pre-PR #84 main `b73dfbe052fedbd4af34956a01d25743607e47d1`
versus unchanged PR #84, two-input fixture, retained directive cache.
Five alternating pairs, same native frontend/configuration. This checks the
earlier warm-clean +25.5% and broad +15.0% finding; it is not the primary
baseline for this change. Those regressions were not reproduced here
(warm-clean -20.9%, broad -16.6%), with overlapping ranges in both cases.
This does not invalidate the earlier samples or prove absence of regressions.
All 50 output maps match stock.

| Jobs | Case | Pre-PR #84 main | PR #84 | Delta |
| --- | --- | --- | --- | --- |
| 4 | cold | 945.9 [905.1, 979.7] | 761.6 [730.9, 842.9] | -19.5% |
| 4 | warm-clean | 420.6 [348.2, 425.8] | 332.7 [284.0, 360.5] | -20.9% |
| 4 | no-op | 9.9 [9.3, 12.4] | 9.6 [8.0, 16.5] | -3.0% |
| 4 | one-file | 351.7 [307.8, 352.8] | 308.6 [250.1, 389.3] | -12.3% |
| 4 | broad | 474.9 [340.2, 522.9] | 396.2 [352.8, 433.3] | -16.6% |

## Interpretation and limits

Adopt the small shared immutable-byte cache: there is measured benefit in the
intended repeated conditional-read workload, including against the same byte
path without memoization. The SHA-only ablation improves warm-clean by
39.3%/23.5%/21.0% at jobs=1/2/4, with disjoint measured ranges in all three.
Primary comparisons against PR #84 improve conditional retained warm-clean
by 63.7%/55.1%/49.9%. This is a fixture result, not an application forecast.

Ordinary-sharing and two-input results mix copy/typed-hash effects with small
reuse counts. Cold cases sometimes regress; ordinary-sharing followups vary;
no-op never executes the affected code. The 2 CPU quota limits interpretation
of jobs=4, and worker sums cannot be subtracted directly from wall time.
The first read of each immutable entry still hashes, separately in each
worker; digests are cleared with the existing per-build byte cache. Most
ordinary-import closure reads are already avoided by Analyzer, leaving little
memoization opportunity. Owning cached bytes adds an insertion copy; large
binary-asset workloads were not measured. Broader reuse would need a digest
tied to the exact
bytes delivered by the Rust protocol, including its path-read lifetime; that
is a separate hypothesis requiring measurement. No mtime shortcuts,
cross-process SHA cache, Rust transport changes, MD5 redesign, cache
compaction or scheduler tuning were added.

There are 900 primary timed builds, 300 supplemental timed builds, and 270
separate diagnostic builds. All 1470 recorded output maps match stock reference
hashes for the corresponding edits. The standard correctness fixtures additionally
perform direct byte comparisons.

## Correctness verification

The candidate's 151 Dart tests, 98 locked Rust tests, four Python unit tests,
Python syntax checks, scoped analysis and formatting pass. Added tests bind
SHA-256 to owned bytes even when input buffers or public builder read results
are mutated. Replacement of the same caller buffer, same-action output rewrite,
delete/recreate, phase eviction, clear/reset and failure recovery are covered.
Existing tests keep generated-appearance, action visibility, primary-input
restrictions, package/relative/file URI resolution and conditional read tracking.

Full verification passes all five suites: `core`, `current-codegen`,
`compatibility-lifecycle`, `compatibility-graph`, `compatibility-mapping`. This
includes quick/arbitrary-builder verification, JSON/Freezed/Riverpod all cases,
built_value, generic watch (four expected events), generated assets, optional
outputs, post-process writes, reset/incremental/failure recovery, target graphs,
mappings and Drift/Drift Analyzer correctness/watch. Freezed/Riverpod and Drift
Analyzer watch runs each observe the expected two events.
Initial environment attempts using a shell wrapper as the native `--dart`
failed SDK-root inference; final checks use the actual SDK executable. Initial
watch attempts used a workspace-local cache after unsetting HOME and observed
extra no-op events, including on unchanged PR #84. Final checks use an explicit
cache outside the watched workspace; generic watch passes without production
watch/scheduler changes.

The standard JSON/Freezed/Riverpod benchmark matrix passes output byte
equality and no-op checks with metrics/trace disabled (jobs=1, JSON count=10).
These launcher/compilation-inclusive runs are correctness validation, separate
from the paired native-only timings above.

Commands (real SDK executable, shared pub cache, explicit external verification
cache, native release binary; HOME unset for this managed environment):

```bash
dart format --output=none --set-exit-if-changed lib bin test tool
dart analyze lib bin test tool
dart test --concurrency=1
cargo test --locked --manifest-path rust/Cargo.toml
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 -m py_compile scripts/benchmark_cold_build.py scripts/prepare_resolver_digest_fixture.py
VERIFY_LEVEL=full VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
BUILD_RUNNER_ACCELERATOR_METRICS=0 JOBS=1 bash scripts/benchmark_matrix.sh
```
