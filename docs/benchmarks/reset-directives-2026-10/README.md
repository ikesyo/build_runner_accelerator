# Reset directive comparison measurements

Measurements use baseline main `1d536c4` and candidate `d34324e`, Dart 3.13.3,
locked analyzer 14.3.0, Rust 1.98.1 release, Linux x86_64, two-CPU quota,
8 GiB limit and warm overlay filesystem page cache. These are fixture results;
application sources/latest-main traces are unavailable. They do not measure
the later dependency changes.

## Decision and contract

Couple the updated immutable decoded String with its directive set. On an old
per-asset record miss, read/decode the pre-build file normally and reuse the
set **only if its entire decoded String equals the updated String**. Otherwise
use the same full-content regex. No content cache, hash or deferred work is added.
AssetId, mtime, mutable buffer identity and inherited digests cannot prove reuse.

- Preserve the legacy import/export/library/part/part-of set, including conditional,
  multiline, malformed/late matches and comment/string false positives. PR #84's
  URI cache has different semantics and cannot substitute for this comparison.
- Equal directive sets retain the graph; unequal sets clear it. Without old content,
  preserve the permanent empty-dependency check and phase-expiring reload behavior.
- Deletion removes the old per-asset record; recreation checks disk/missing state.
  Next-build reset clears existing records. New String/result pairs are temporary.
- Blob validation/lifetime, reader invalidation, visibility, dependency recording,
  optional demand and atomic commit are unchanged, as are scheduling/AOT policies.

A bounded full-String LRU was rejected: seven-sample extraction medians for equal
large outputs were 49.657→26.585 ms, but unique-content misses were
51.196→63.948 ms (+24.9%). Alternative whole-scan prefilters were also slower.
The measured benefit below is available identical old content, **not regen**.

## Workload and reproduction

Six phases: 64 Riverpod/Freezed/JSON inputs, 144 shared conditional/transitive
sources, a large Dart probe reading generated/shared content, then post-process.
Unique filename prefixes produce 64 large outputs (~8.19 MB). All 72 final speed
samples match all 384 stock source/cache artifacts byte-for-byte; edits change bytes.

Jobs=2/4, three repetitions, AB/BA/AB, same frontend and corresponding prepared
AOT workers/SDK/package config/cache conditions. Speed disables metrics and traces;
wall-only and detailed diagnostics are separate. Prepared cold clears graph,
outputs, byte store and dependency parse cache, retaining SDK summaries/workers.
Regen removes workspace state/outputs but retains shared caches; both lanes prime
that route outside timing. Warm-clean deletes graph/post outputs while retaining
old Dart/part files. Prepared workers exclude compile/restore/validation; manifest
regeneration is included. CPU is process-tree user+system; RSS is maximum single
process, **not** simultaneous tree peak. SDK/tool caches are not universally cold.

[samples.csv](samples.csv) retains every final speed/wall/detail sample;
[micro.csv](micro.csv) retains all seven alternating extraction samples.
[metadata.json](metadata.json) records common tool/worker/input hashes and run modes;
[directive-stats.csv](directive-stats.csv) sums every reset/worker counter by build.
No final sample or counter is dropped; rejected experiment rows are excluded.

The one-off harness, builder, microbenchmark, baseline diagnostic patch and rejected
experiment sources are available in the immutable [measurement archive](https://github.com/ikesyo/build_runner_accelerator/tree/09708bf40ee078a51fc7cafd570da62f0fa487b9/docs/benchmarks/reset-directives-2026-10).
Its README contains the complete fixture/worker setup. For reproduction, use that
checkout's `benchmark.py` with corresponding baseline/candidate workers and
`--unique --cases cold no-op one-file broad regen warm-clean --repeats 3`.
Run separately with `--wall` (regen), `--wall --prepared-wall` (warm-clean), and
`--wall --metrics --repeats 1` for counters, supplying the speed stock reference.
Microbenchmark decode/read/setup/oracle checks are outside timed extraction.

## Results

All tables show median [min,max]; build/wall-only comparisons have three samples
per lane/jobs. Worker elapsed sums are neither frontend wall nor CPU.

### Trace-disabled whole build (seconds)

| Jobs | Case | Baseline wall s | Candidate wall s |
| --- | --- | ---: | ---: |
| 2 | cold | 7.272 [5.265,8.312] | 6.323 [5.997,6.547] |
| 2 | no-op | 0.172 [0.169,0.206] | 0.178 [0.176,0.186] |
| 2 | one-file | 0.800 [0.709,1.499] | 0.748 [0.742,0.843] |
| 2 | broad | 4.308 [3.698,5.817] | 3.970 [3.563,4.591] |
| 2 | regen | 22.033 [16.391,27.311] | 19.994 [18.148,21.209] |
| 2 | warm-clean | 3.984 [3.191,4.984] | 3.726 [3.509,5.318] |
| 4 | cold | 6.236 [5.513,6.404] | 6.282 [6.125,6.664] |
| 4 | no-op | 0.178 [0.152,0.186] | 0.171 [0.168,0.174] |
| 4 | one-file | 0.774 [0.718,0.815] | 0.845 [0.768,0.952] |
| 4 | broad | 4.397 [4.106,4.499] | 4.121 [4.064,4.388] |
| 4 | regen | 22.544 [21.854,22.808] | 20.485 [20.021,21.680] |
| 4 | warm-clean | 3.792 [3.722,6.118] | 3.703 [3.613,4.125] |

Regen has **zero reuse hits**, so its lower candidate whole-build median is not
attributable to this shortcut. Wall-only manifest-selection medians are
18.180→17.319 s (jobs=2) and 17.826→17.812 s (jobs=4), dwarfing reset work.
No stable whole-build win is established: jobs=4 one-file median rises 71 ms,
and jobs=2 cold max-process RSS rises 255.7→276.0 MiB with overlapping ranges.
All CPU/RSS samples, including cold/no-op/incremental, remain in the CSV.

| Jobs | Case | Baseline tree CPU s | Candidate tree CPU s | Baseline max-process RSS MiB | Candidate max-process RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | regen | 35.755 [27.234,43.555] | 32.343 [30.333,33.811] | 613.027 [607.555,614.641] | 633.098 [605.828,649.969] |
| 2 | warm-clean | 7.391 [5.919,9.010] | 6.922 [6.613,8.843] | 177.492 [173.668,187.637] | 173.223 [168.676,189.477] |
| 4 | regen | 37.387 [34.991,37.718] | 33.178 [32.780,35.160] | 610.316 [586.320,632.504] | 607.402 [604.234,614.359] |
| 4 | warm-clean | 7.085 [7.052,10.723] | 7.036 [6.827,7.646] | 172.055 [167.746,178.098] | 168.684 [160.879,169.129] |

### Isolated extraction (milliseconds)

401 files / 10,154,220 code units, fresh decoded Strings per lane, seven samples.

| Old version | Baseline ms | Candidate ms |
| --- | ---: | ---: |
| Missing (one updated scan) | 43.619 [40.302,125.638] | 44.181 [42.335,62.410] |
| Same full content (two scans vs scan plus equality) | 86.442 [78.501,105.496] | 46.861 [38.195,57.018] |
| Changed body (still two scans) | 84.439 [78.732,94.746] | 85.599 [79.966,248.463] |

Same-version extraction improves 45.8%; missing/changed medians increase
1.3%/1.4%. This supports the equality shortcut, not a persistent cache.

### Separate wall-only reset/dispatch (milliseconds)

Cleanup is the final large-Dart/post-process reset. All graph-clear counts are zero.

| Workload | Jobs | Lane | All reset frontend wall ms | Cleanup frontend wall ms | Cleanup directives worker sum ms | All dispatch exclusive wall ms |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| regen | 2 | baseline | 200.9 [148.7,209.0] | 134.5 [115.9,154.9] | 94.2 [66.2,103.3] | 3585.6 [3296.7,3616.5] |
| regen | 2 | candidate | 190.6 [167.5,195.1] | 125.4 [120.9,143.4] | 93.3 [88.6,108.2] | 3434.6 [3360.3,3553.1] |
| regen | 4 | baseline | 350.1 [325.2,362.1] | 249.7 [241.2,271.4] | 405.8 [370.3,414.7] | 3388.0 [3252.0,3390.6] |
| regen | 4 | candidate | 355.4 [337.0,360.6] | 241.9 [235.4,265.0] | 326.8 [296.4,353.6] | 3426.4 [3174.8,3506.1] |
| warm-clean | 2 | baseline | 245.3 [176.5,497.6] | 160.8 [133.3,370.2] | 155.8 [138.3,390.9] | 4266.6 [2354.1,4479.8] |
| warm-clean | 2 | candidate | 269.9 [153.5,459.6] | 210.3 [112.6,384.2] | 168.1 [87.8,237.0] | 4900.8 [2602.2,5924.4] |
| warm-clean | 4 | baseline | 367.0 [337.1,422.4] | 275.8 [271.9,308.6] | 583.8 [551.1,715.9] | 2680.0 [2452.5,3115.8] |
| warm-clean | 4 | candidate | 321.6 [301.2,327.1] | 223.9 [219.0,232.1] | 336.3 [277.3,367.7] | 2959.9 [2943.1,3361.9] |

Available-old jobs=4 cleanup improves, but jobs=2 is noisy. Dispatch ranges
overlap and some candidate medians rise, so downstream timing is not established
as unchanged. Extraction/comparison stays inside the same reset; no scans are
queued for dispatch or the next build, whose no-op/incremental bytes remain correct.

### Separate detailed counters

One build per lane/jobs/workload; times are worker sums in milliseconds. Timers
include scheduling stalls. Detailed probes require METRICS and WALL_TRACE;
the observed-content set hashes/retains text outside decode/scan subtimers, so
these identify work rather than independently establish speed.

| Workload | Jobs | Lane | Updated decode/scan ms | Old decode/scan ms | Old full comparison ms | Package lookup/existence/read ms | Set comparison/deps lookup/graph end ms |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| regen | 2 | baseline | 6.770/99.143 | 0.000/0.000 | 0.000 | 0.645/4.307/0.000 | 0.000/0.259/0.017 |
| regen | 2 | candidate | 11.035/78.714 | 0.000/0.000 | 0.000 | 0.435/6.939/0.000 | 0.000/0.471/0.019 |
| regen | 4 | baseline | 63.792/482.918 | 0.000/0.000 | 0.000 | 5.661/24.659/0.000 | 0.000/2.526/0.045 |
| regen | 4 | candidate | 80.121/414.704 | 0.000/0.000 | 0.000 | 1.587/58.353/0.000 | 0.000/0.676/0.046 |
| warm-clean | 2 | baseline | 12.546/87.321 | 6.211/109.029 | 0.000 | 0.439/5.113/27.511 | 0.219/0.000/0.020 |
| warm-clean | 2 | candidate | 8.189/94.753 | 14.833/0.000 | 1.719 | 1.652/3.829/15.542 | 0.332/0.000/0.017 |
| warm-clean | 4 | baseline | 30.632/364.460 | 23.217/408.636 | 0.000 | 2.998/18.635/68.961 | 1.356/0.000/0.062 |
| warm-clean | 4 | candidate | 36.976/385.319 | 68.647/0.000 | 6.659 | 1.113/13.270/61.601 | 0.506/0.000/0.037 |

| Workload | Jobs | Updated Dart/part requests/scans | Updated bytes | Old record hit/miss | Old exists/read | Old bytes | Old scans baseline→candidate | Full-equality reuses | Actual repeated scans baseline→candidate | Dependency lookups | Graph clears |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| regen | 2 | 640/640 | 17,709,876 | 0/640 | 640/0 | 0 | 0→0 | 0 | 0→0 | 384 | 0 |
| regen | 4 | 1280/1280 | 35,419,752 | 0/1280 | 1280/0 | 0 | 0→0 | 0 | 0→0 | 768 | 0 |
| warm-clean | 2 | 640/640 | 17,709,876 | 0/640 | 640/384 | 17,504,844 | 384→0 | 384 | 384→0 | 0 | 0 |
| warm-clean | 4 | 1280/1280 | 35,419,752 | 0/1280 | 1280/768 | 35,009,688 | 768→0 | 768 | 768→0 | 0 | 0 |

Counts are worker-broadcast totals: 320 updated Dart/part assets per worker,
not 640/1280 distinct files. Each is updated once, explaining zero old-record hits;
the protocol test separately verifies later hits and deletion/next-build eviction.
`repeated_content_extracts` counts duplicate requests; subtract
`old_same_content_reuses` to obtain actual repeated scans.

The removed old scans cost 109/409 ms; full equality costs 1.7/6.7 ms. Reads/decode
remain. Package lookup, set comparison, dependency lookup and graph termination
are smaller. Regen remains dominated by updated scanning and has no duplicate
complete texts in this fixture; a prefix-only parser could miss late legacy matches.
Production retains no additional text/cache. Diagnostic-only observation retains
~17.7/35.4 MB of text across workers until next build reset, plus object overhead.
Shared cache end-state was ~34 MiB, not a per-lane peak; no new cache files are added.

## Validation and limits

Related 40 tests and targeted analysis pass, including analysis-options tests.
Extraction tests compare the legacy oracle on directive edge cases and 300 seeded
combinations; mutable bytes/stale digests cannot authorize reuse. The framed worker
test covers old/current records, body/directive changes, delete/recreate and next
build. Existing phased-dependency/overlay/resolver tests cover expiration,
visibility, conditional reads and nested demand; the permanent missing-entry
branch is unchanged and is not newly manufactured by this protocol test.
Riverpod stock/native no-op, source invalidation, generated/cache-output recovery
and failure rollback pass. Local watch event-count failure also reproduces on
baseline (extra notification is a no-op, stable starts=2, edited bytes agree).
[CI](https://github.com/ikesyo/build_runner_accelerator/actions/runs/37544309090)
passes all 23 jobs, including watch and cross-SDK checks. No application, default
startup, Windows performance or simultaneous tree-RSS improvement is established.
