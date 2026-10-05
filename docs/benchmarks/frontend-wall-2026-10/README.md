# Frontend regen wall attribution after PR #87

Work started from freshly fetched main `b852ba75798837e248a394199e2e279c88837c82`
(PR #87 merged). It is identical to the user's last inspected main; there are
no intervening changes to duplicate. Read AGENTS.md, development/roadmap,
protocol v1, ADRs 0002/0003/0005 and the prior manifest, resolver digest,
conditional-directive and cycle-read investigations.

This is a **diagnostic change**, not a production performance optimization.
The fixture identifies expensive envelopes, but does not identify a removable
frontend operation on the application's critical path. It does not justify a
new cache, scheduling policy, resolver cap, single-flight default, driver
recreation, or AOT strategy. All existing phase/visibility/read/optional-builder
and all-success commit behavior is retained.

## Supplied application evidence and its limits

The supplied report and anonymized archive describe a Flutter application with
827 source outputs and 3,133 worker actions. Its PR #87 regen is 17.3 seconds;
the sum across builders of each builder's maximum worker action total is about
10.652 seconds. Their difference, **6.648 seconds, remains unallocated for the
application**. No frontend interval timeline exists in those old logs, and the
private application sources are unavailable. Fixture percentages cannot be
applied to this difference.

The supplied regen means deleting **all** workspace accelerator state and
source outputs, retaining machine-wide caches. It includes manifest regeneration
and worker artifact restoration/validation. The older prepared-worker
`warm-clean` harness only clears graph/output state, retaining manifest and
worker artifacts; it is a different condition.

The supplied native log reports 26,103 planned specs (18,006 normal and 8,097
post-process), `part_filtered=8829`, and 3,133 executed worker actions. Its
initial scan is 207,097 us over 7,015 assets/108,452,046 bytes. This motivates
measuring planning, phase input selection and missing-input/empty-result
recording, rather than treating the build-action banner as worker execution.
It does not establish that these frontend stages dominate elapsed time.

Existing counters have these boundaries:

| Counter | Boundary and relationship |
| --- | --- |
| Dart `total_us` | Per-action builder work, resolver-read collection and result construction; nested builder/resolver/cycle stages are already inside it. Excludes the complete frontend batch envelope. |
| Rust `build_us` | Client-call envelope: blocked assets/request construction, encode/send, worker execution, asset handling, receive/decode, validation, client dep-graph integration and metrics-only hypothetical JSON sizing. Pool reports cumulative worker sums, including retired workers. Parallel durations overlap; lazy nested build timers also overlap within a worker. |
| `asset_rpc_us` | Rust asset handler through response send, inside `build_us`; excludes request receipt/context lookup and the worker's later filesystem read of a path response. |
| `worker_start_us` | Spawn/pipe setup, not worker readiness or artifact preparation. |
| Initialize/reset timers | Successful client round trips. Resolver pool reset additionally spools overlay data and joins concurrently resetting workers. 2.312 worker-seconds of resets is not 2.312 wall-seconds. |
| Existing dirty/scan/graph timers | Individual operations, not complete frontend stages. Dirty timer excludes persisted-output hashing and subsequent propagation/deletion work. |
| Resolver cycle/dep stages | Nested worker work. `dep_prefetch_us` is outside phased reads but inside cycle walking. Decode/hash is inside phased reads. Summing these with action or Rust envelopes double-counts. |

The new attachment confirms zero same-worker positive asset/content reloads,
0.246 worker-seconds of Rust asset handling, 2.535 cycle-walk worker-seconds,
1.191 phased-read worker-seconds (about 0.989 decode/hash). Driver creations
are **two**, summing per-PID maxima of cumulative counters; replacements are
zero. These facts do not justify new conversion/digest retention.

## New frontend timeline

`BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1` is independent of worker metrics and
analysis trace. A session has one Rust `Instant` origin. All threads' start/end
values are relative to it; child worker PIDs identify batches, **not a different
clock domain**. No Dart timestamps are compared with Rust timestamps.

The trace covers workspace loading, manifest selection/generation, graph load,
config identity, initial scan/generated/dependency/glob discovery, full planning
and dirty analysis, transaction setup, worker artifact preparation and lifecycle,
phase selection/request assembly/reset/dispatch, request encode/send,
receive frames, asset handlers, decode/validation, dependency integration,
result validation/digests/overlay registration, output commit, post-scan,
asset graph updates and save. Phase and worker batches retain intervals so
parallel dispatch and initialization are distinguishable.

`receive_frame` includes blocking, binary-frame reading and control-JSON
parsing. It is **not pure worker CPU or pure idle wait**. Decode/validate covers
binary result decoding and client checks/graph insertion. Metrics-only
`diagnostic_json_size` is nested and partitioned separately; the real protocol
continues to use binary results. Optional demand records a parent lazy batch,
nested build and handler spans; overlapping intervals are unioned.

The analyzer partitions the native interval using named leaf envelopes. It
never adds worker counters to produce wall time. It reports batch unions and
envelopes, the batch with the latest frontend finish per dispatch, and explicit
unattributed gaps. A parent's interval and its children are not additive.
Worker-envelope gaps can contain pool initialization and joins; they are not
assumed to be Rust CPU. Native unattributed time includes uninstrumented
bookkeeping, diagnostics and cleanup. The analyzer rejects truncated traces,
out-of-root intervals and nonzero dropped-event counts.

Events are buffered, capped at 100,000 per session, then emitted through a
buffered stderr writer. Write failures are ignored without panic; a partial
trace has no terminal root and is rejected. Auto-mode Dart fallback is recorded
as `dart_fallback`, outside manifest selection; it is not a Rust-only sample.
Disabled tracing reads its flag once and creates no timestamps, event strings,
locks or buffers. The native root starts after CLI parsing and ends **before
trace serialization/flush**. External process timing includes executable/CLI
startup, flush and process exit; launcher runs additionally include Dart
startup and binary resolution. Their elapsed-duration difference is an outside
trace envelope, not synchronized cross-process timestamps or a stage-specific
attribution. Watch sessions cover `run_with_config`; earlier watch manifest/pool
setup and polling are outside that iteration's root. Error returns still close
spans and flush a session; forced process termination cannot do so.

## Fixture and conditions

`scripts/prepare_cycle_read_fixture.py` prepares 64 mixed Riverpod/Freezed/JSON
inputs and 144 conditional/transitive shared sources, with four dispatched
normal phases. There are 128 source outputs plus 128 cache parts. One-file and
broad cases rename provider functions and must change generated bytes.
Untimed stock references cover source and cache outputs in every case.

Same Dart 3.13.3, Rust 1.98.1, package configuration, lockfile, worker code/AOT
bytes, pub cache, machine-wide cache paths and SDK summaries are used per
comparison. Worker hashes are checked after every full regen. OS page cache is
warm and not flushed. Jobs 2/4 are explicit; the Linux container has a two-CPU
quota and 8 GiB memory, so jobs=4 is not four physical CPUs. Metrics, analysis
trace and wall trace are disabled in speed comparisons. Orders alternate per
repeat; diagnostic orders rotate/reverse. Preparation and correctness checks
are outside timings, and performance groups run serially.

The initial `.toolchains/dart-wrapper` lived outside the SDK's `bin`, causing
manifest snapshot preparation to infer an invalid SDK and fall back to source.
Those full-regen samples are retained locally as a separate fallback condition,
excluded from the default-route comparison. A wrapper in the same SDK's `bin`
keeps the identical underlying SDK and confirms a warm manifest snapshot hit
before final measurements. No launcher/AOT strategy was changed. Initial
prepared-worker measurements remain valid under their recorded wrapper because
their manifest is retained; a final confirmation uses the repaired wrapper.

## Results

All times below are milliseconds, median [minimum, maximum]. Speed rows have
all diagnostics disabled. A negative change is faster; no runtime optimization
was made, and all final ranges overlap. The first three-repeat prepared run had
a jobs=4 broad increase of 4.2% with disjoint ranges. An earlier five-repeat
confirmation reversed that direction; the final five-repeat group below has
+4.7% with overlapping ranges. Small regressions cannot be excluded, and these
variable samples do not establish a stable trace-disabled effect.
The final conditions contain **142 stock-identical builds** (124 speed samples
and 18 instrumentation samples), each checking all 256 output files. Earlier speed/diagnostic groups also matched stock and are retained locally;
the tables below use the final hardened trace implementation.

| Jobs | Prepared case | Main | Candidate | Median change |
| --- | --- | --- | --- | --- |
| 2 | cold | 2616.6 [2204.1, 2722.4] | 2535.3 [2394.6, 2687.5] | -3.1% |
| 2 | warm-clean | 1242.0 [1180.8, 1302.0] | 1207.7 [1140.8, 1247.1] | -2.8% |
| 2 | no-op | 29.3 [28.6, 31.1] | 28.4 [27.7, 30.6] | -2.9% |
| 2 | one-file | 327.3 [307.8, 336.0] | 305.4 [292.1, 315.7] | -6.7% |
| 2 | broad | 1396.9 [1291.0, 1412.3] | 1293.9 [1262.5, 1338.0] | -7.4% |
| 4 | cold | 2570.8 [2435.3, 2753.3] | 2595.2 [2488.1, 2610.0] | +0.9% |
| 4 | warm-clean | 1267.3 [1202.9, 1380.2] | 1207.0 [1156.2, 1276.5] | -4.8% |
| 4 | no-op | 29.6 [28.7, 31.8] | 28.7 [28.3, 30.2] | -3.0% |
| 4 | one-file | 315.4 [298.6, 331.3] | 318.7 [300.1, 345.5] | +1.1% |
| 4 | broad | 1295.4 [1256.8, 1431.6] | 1356.8 [1317.8, 1372.7] | +4.7% |

Five repeats per lane/case/jobs, alternating lane order. Prepared cold clears
byte-store/directive caches and graph/outputs, retaining manifest/worker/SDK
summaries; warm-clean retains analyzer caches and also clears graph/outputs.
Neither includes AOT preparation or the launcher.

| Route | Jobs | Full regen main | Candidate | Median change |
| --- | --- | --- | --- | --- |
| native | 2 | 1852.6 [1793.8, 1855.9] | 1815.6 [1799.6, 1840.8] | -2.0% |
| native | 4 | 1828.4 [1791.0, 1849.2] | 1889.9 [1812.4, 2027.5] | +3.4% |
| launcher | 2 | 1816.9 [1779.1, 1942.9] | 1880.0 [1786.6, 1982.9] | +3.5% |
| launcher | 4 | 1861.3 [1801.7, 1894.8] | 1767.1 [1752.0, 1880.5] | -5.1% |

Three alternating repeats per lane/jobs. These remove the entire accelerator
workspace directory and all source outputs, retaining shared caches. Worker
restore/validation and manifest generation are included. Launcher pub-executable
snapshot is primed outside timing. These distributions do not establish speedup.

### Complete native wall partition

These are **individual representative wall-only runs**, selected as the median
native root of three per jobs. They are not independent category medians; each
column's exact microsecond components sum to its own native wall. Worker metrics
and analysis trace are off. Parent/child envelopes are partitioned, not added.

| Exclusive interval group | Jobs 2 | Jobs 4 |
| --- | --- | --- |
| Manifest selection/generation | 521.144 | 473.144 |
| Initial snapshot + planning + dirty analysis | 10.236 | 11.096 |
| Worker artifact preparation + initial readiness | 73.750 | 71.473 |
| Phase selection + request assembly | 6.503 | 6.596 |
| Phase reset (including spool and concurrent worker resets) | 46.236 | 50.840 |
| Phase dispatch through all worker responses | 1120.452 | 1181.824 |
| Dependency graph merge + result/overlay recording | 1.965 | 2.345 |
| Output commit + post-scan + graph save | 22.329 | 21.722 |
| Other measured bookkeeping | 0.416 | 0.435 |
| Unattributed gaps | 9.659 | 15.216 |
| **Native wall** | **1812.690** | **1834.691** |
| External process elapsed | 1815.367 | 1837.854 |
| Outside native trace envelope | 2.677 | 3.163 |

The manifest envelope accounts for 26–29% of the representative native walls;
phase dispatch accounts for 62–64%. Manifest generation is a required
configuration/probe envelope, not proof of redundant AOT work. Frontend scan,
planning, result recording and commit are small in this fixture. A narrow, safe
production reduction is not established by these envelopes.

| Jobs | Phase/builder | Dispatch start–end | Dispatch wall | Latest-finishing batch | Its receive envelope |
| --- | --- | --- | --- | --- | --- |
| 2 | 0 / riverpod_generator:riverpod_generator | 607.882–1322.252 | 714.370 | 702.980 | 690.563 |
| 2 | 1 / freezed:freezed | 1332.078–1640.080 | 308.002 | 307.803 | 307.253 |
| 2 | 2 / json_serializable:json_serializable | 1671.071–1734.809 | 63.738 | 59.662 | 58.617 |
| 2 | 3 / source_gen:combining_builder | 1746.044–1780.386 | 34.342 | 34.124 | 30.668 |
| 4 | 0 / riverpod_generator:riverpod_generator | 558.468–1226.129 | 667.661 | 650.652 | 641.891 |
| 4 | 1 / freezed:freezed | 1240.796–1605.552 | 364.756 | 364.522 | 363.801 |
| 4 | 2 / json_serializable:json_serializable | 1632.363–1748.126 | 115.763 | 111.358 | 110.433 |
| 4 | 3 / source_gen:combining_builder | 1763.791–1797.435 | 33.644 | 33.275 | 31.467 |

All four phases dispatch to two resolver-cap-limited workers at both jobs
settings; jobs=4 still starts four resident workers. Riverpod and Freezed
responses gate the next phase. The latest finish, rather than a sum of parallel
worker durations, defines each batch gate. Request send, Rust asset handling,
result decode and unclassified worker time are included in the batch. The receive
envelope cannot separate builder/Analyzer CPU, worker-side serialization,
filesystem reads, IPC and descheduling. No new runtime cache follows from it.

### Instrumentation cost, separate runs

| Jobs | Candidate condition | External regen wall |
| --- | --- | --- |
| 2 | disabled | 1754.0 [1744.7, 1755.7] |
| 2 | wall-only | 1815.4 [1712.5, 1847.9] |
| 2 | wall+metrics | 1780.0 [1580.9, 1907.7] |
| 4 | disabled | 1855.7 [1751.9, 1873.6] |
| 4 | wall-only | 1837.9 [1752.7, 1944.7] |
| 4 | wall+metrics | 1847.3 [1813.5, 2153.7] |

Three repeats with rotated/reversed condition order. All ranges overlap, with
large run-to-run variation. This confirms no clear burden at this fixture's
resolution, **not zero overhead or a proven overhead bound**. Native interval
bookkeeping is inside wall; buffered serialization/flush is in external time.
Metrics-only hypothetical JSON sizing contributes about 12–17 ms along the
latest-finishing batches in these captures; ordinary wall-only result decoding
is roughly 0.06–0.23 ms per critical batch. This is diagnostic work, not binary
protocol overhead to optimize. Worker metrics additionally time/log Dart work.

The committed artifacts are the [raw samples](prepared-samples.csv), [full regen native samples](regen-native-samples.csv),
[launcher samples](regen-launcher-samples.csv), [overhead samples](overhead-samples.csv),
[SDK/toolchain and compact binary/input identities](toolchain.json), and [output validation fingerprints](outputs.json).
This report includes the medians/ranges and representative frontend/batch timelines.
Full event streams, per-input hash maps, expanded command/environment dumps, computed
summary JSON, raw stderr logs, and complete per-file output manifests remain local;
the benchmark and summarizer scripts reproduce them.

## Correctness and checks

All **142 timed or diagnostic fixture builds** matched stock output hashes for
all 256 generated source/cache artifacts. The candidate source snapshot used
for final verification matched the working tree for all 11 changed Rust files.

The final verification run passed Dart tests (161), Rust tests (101), the
wall-summary tests (14), Dart analyze/format/publish dry-run, CI and changed
Rust formatting checks, and a locked candidate build. Both quick verification
and arbitrary-builder verification with wall tracing enabled passed. All five
full verification suites passed: core, current-codegen,
compatibility-lifecycle, compatibility-graph and compatibility-mapping.
Optional-builder and post-process correctness with wall tracing enabled passed,
as did the watch smoke, Freezed/Riverpod correctness, watch and benchmark
scripts, benchmark matrix, and signing/benchmark helper tests. There were no
failed checks.

## Reproduction and unresolved work

Resolve the disposable cycle fixture and perform an untimed default AOT prime
with the same SDK/package configuration. Build an unchanged main binary and the
candidate release binary. `benchmark_cold_build.py --stock-check` prepares stock
references; source and cache hashes are both required.

```bash
python3 scripts/benchmark_cold_build.py \
  --baseline "$main_native" --candidate "$candidate_native" \
  --frontend-dart "$dart" --root "$fixture" --cache "$cache" \
  --results "$prepared_results" --fixture-kind riverpod-cycle \
  --worker "$prepared_worker" --jobs 2 4 --repeats 5 --stock-check
python3 scripts/benchmark_frontend_regen.py \
  --baseline "$main_native" --candidate "$candidate_native" --dart "$dart" \
  --root "$fixture" --cache "$cache" --results "$regen_results" \
  --stock-reference "$prepared_results/stock-outputs.json" --jobs 2 4 --repeats 3
# Repeat in fresh results directories with --launcher, and separately --diagnostic.
python3 scripts/summarize_frontend_wall.py "$diagnostic_log"
```

For the actual application, build this PR's native frontend and use it through
`BUILD_RUNNER_ACCELERATOR_BIN`, then capture a separate diagnostic regen:

```bash
BUILD_RUNNER_ACCELERATOR_BIN="$candidate_native" \
BUILD_RUNNER_ACCELERATOR_METRICS=0 \
BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=0 \
BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1 \
  dart run build_runner_accelerator build --mode rust --jobs 2 2>frontend-wall.log
python3 scripts/summarize_frontend_wall.py frontend-wall.log >frontend-wall.json
```

Repeat jobs=4 under the same application's regen deletion/cache conditions.
The current fixture cannot explain the private application's 6.648-second
remainder. Manifest internals' official configuration/probe work and worker
CPU versus IPC/file-I/O inside receive envelopes still need a further probe
if they become the measured application bottleneck. Native gaps and external
startup/flush/exit remain explicitly reported. No general cold/regen speedup,
application shortening, or measurement-overhead upper bound is established.
