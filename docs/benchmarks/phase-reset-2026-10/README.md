# Phase reset synchronization: diagnosis, no optimization adoption

Work started from freshly fetched main `f57b5faaf75173d049ba3a2a79c350e08b074172`.
The directory-deduplication experiment does not establish a useful whole-build
improvement, and is **not applied** to the production code. This draft retains
narrow reset diagnostics, reproducible fixtures, measurements and the negative
adoption decision. No deferred synchronization mechanism is introduced.

## Application evidence and scope

The supplied PR #89 report and anonymized archive were read and the wall-only
regen log was replayed through the wall summarizer. Native wall is 16.605995 s;
exclusive reset wall is 1.202049 s. Resets before Riverpod, Freezed, JSON,
combining, Mockito and cleanup are approximately 0, 396, 87, 89, 284 and 346 ms.
Cleanup dispatch itself takes 164 ms. The supplied cumulative counters establish
**two driver creations and zero resolver replacements**, not repeated driver
construction. Each application diagnostic condition ran once.

These existing logs have worker reset round trips but no worker reset stage
breakdown. They cannot attribute the application's 346 ms cleanup reset to
Analyzer CPU, cache updates or spool I/O. The private application sources are
unavailable. No fixture number below is an application saving. Even the full
1.202 s reset envelope is only 7.24% of this application's wall; it contains
required work and is not a removable budget.

Closed, unmerged [PR #90](https://github.com/ikesyo/build_runner_accelerator/pull/90)
was reviewed. Its tail allocation reduced a deliberately skewed final-worker
gap, but whole regen medians moved little, balanced cold worsened, and repeated
IPC/cross-worker work grew. None of its scheduler, assignment or ADR changes
are included here.

## Responsibilities and timing boundaries

| Boundary | Existing responsibility | Diagnostic meaning |
| --- | --- | --- |
| `build/results.rs`, `build/transaction.rs` | Register overlay updates/deletions and cancel the opposing delta entry for the same asset. Keep pending output/graph commit atomic. | Result recording is outside reset. The final mutation since the last barrier determines each delta; no new queue or coalescing rule is added. |
| `build/execution.rs` | At the next runnable configured phase, take accumulated source/cache deltas and retain the phase barrier. | `phase_reset` includes package initialization when needed; an empty span is not a worker RPC. |
| `worker/pool.rs` | Spool current overlay bytes for all workers, remove stale/deleted spool files, serialize the four delta sets, reset initialized workers concurrently and join. | New `reset_overlay_spool` and `reset_delta_encode` are frontend intervals. The worker union, not the sum of their round trips, contributes to wall. |
| `worker/client.rs` | Encode/send the reset and receive/validate its reply. | New `reset_encode_send` and `reset_receive`; send can include pipe blocking, receive includes wait/read/JSON decode, not pure worker CPU. |
| `worker.dart:resetResolver` | Evict changed positive/readability entries and resolver dependency cache, remove deleted produced outputs, read current spool bytes, check update availability. | `cache_invalidation` and `overlay_read` are cumulative worker stopwatch marks. Missing incremental bytes still fall back to a clean refresh. |
| Worker directive comparison | Compare `.dart`/`.part` directive sets with committed or pre-build content; clear the cycle graph only when required. | `directives_and_graph` also includes update availability checking, disk fallback, directive decoding and resolver unlock. |
| `_startBuild` | Rebuild the reader/filesystem adapter and immutable committed-output snapshots; retain the existing resolver and start its Analyzer **filesystem** with updated/deleted inputs. | `analyzer_start` is the remaining adapter/lock/filesystem interval. It does not mean a new AnalysisDriver. |
| `WorkerAnalysisDriverModel.updateDriver` | Set phase, call `driver.changeFile` for changed paths and `applyPendingFileChanges` before resolver work. | These notifications are **already deferred to resolver use**, outside reset. Existing action metrics measure them. |
| Batch dependency graph | Drain pending phased dep loads before actions, export reachable changed dep values, merge into the Rust graph. | Graph draining can run even before an action that never obtains a resolver. Atomic graph/output commit is unchanged. |

`BRA_RESET_TRACE` is enabled by `WALL_TRACE=1`, independently of action metrics.
Its `elapsed_us` fields are cumulative durations on a worker-local stopwatch;
subtract adjacent marks for stage durations. They are **not timestamps on the
frontend clock**, CPU counters, or numbers to add to frontend wall. Records
cover successfully completed incremental resets; clean/fallback paths retain
frontend envelopes but do not emit this worker breakdown. Per-worker stdout
remains exclusively framed IPC.

The summarizer adds `phase_resets` with an exclusive spool/delta/worker-union/gap
partition and separate per-worker encode/receive partitions. Older traces
retain their unclassified reset gaps. Existing native and batch partitions are
preserved. Tests cover overlapping workers, legacy traces, independent watch
origins and malformed worker identifiers.

## Deferred synchronization assessment

Reader caches and `producedOutputs` must be current for every phase, including
post-process primary-input reads. A new filesystem adapter snapshots those
contents and keeps single-listener registration and same-phase visibility.
Skipping reset wholesale or merely retaining an old adapter would violate that
contract. Skipping an owned output's spool read by asset ID is also unsafe:
another worker may have rewritten that asset after this worker produced it.

Driver notifications already wait for actual resolver use. Deferring the
remaining Analyzer filesystem/directive work would need to coordinate the
existing dep-load drain, batch graph export, filesystem snapshots and nested
optional action contexts. The pool's `(builder, instance)` resolver usage is
observed history, not proof that a later input cannot use a resolver; unknown
instances must remain conservative, and an unexpected resolver get would need
to flush correctly. Builder names are not a state contract.

An implementation would require ordered handling of update/delete/recreate,
intermediate directive changes, the next resolver and watch build, nested lazy
calls, and failure recovery. This draft does not introduce that mechanism or
claim to have proved those new transitions. The measured non-resolver reset
budget and unavailable application breakdown do not justify its complexity.
The eager deltas, cache invalidation, visibility, read dependency recording,
phase barriers and all-success commit remain exactly the existing mechanism.

## Conditions and fixtures

All comparisons use Dart **3.13.3**, Rust **1.98.1**, the same resolved package
configuration/lockfiles and pub cache, AOT worker implementation and shared cache
paths within each fixture. Both lanes use the same generated worker bytes;
worker hashes are recorded and checked across regen. A common worker contains
the opt-in reset probes, disabled in speed runs: the comparison isolates the
Rust experiment/diagnostic spans, not the isolated overhead of adding Dart
probes to an untouched worker. No AOT strategy was varied.

This container has a two-CPU quota and 8 GiB RAM. Jobs=4 does not provide four
physical CPUs. OS page cache is not flushed. All final comparison groups ran
serially, after the experiment compilation and initial unit-test activity; lanes alternate baseline/candidate then
candidate/baseline, three repeats per jobs/case. A preliminary control group
that overlapped compilation/tests is excluded, as are failed setup attempts.

- **Cycle**: 64 Riverpod/Freezed/JSON inputs, 144 shared conditional/transitive
  sources, four resolver-using phases, 256 generated source/cache artifacts.
  Metrics confirmed that combining also gets a resolver; it is not used as a
  supposed non-resolver control.
- **Mixed**: the cycle fixture plus a generic normal builder reading generated
  `.g.dart` and a shared source, emitting 64 `.probe` files, followed by a generic
  post-process producing 64 `.probe.post` files. Six dispatched phases and **384**
  artifacts. Neither added builder exposes/gets a resolver in the capture.
  This fixture models state contracts, not the application's Mockito/cleanup
  workload or generated byte volume.

Prepared `cold` clears graph/outputs and byte-store/directive caches, retaining
worker/manifest and SDK summaries. Prepared `warm-clean` retains shared caches.
`regen` removes all workspace accelerator state and all generated source
outputs, retaining shared caches, including manifest generation and AOT
restore/validation. It is cache-cold build work versus a prepared worker, **not**
a fresh SDK or empty machine-wide AOT cache. No-op reuses the committed graph.
One-file and broad edits rename provider functions and must change generated
bytes. Stock references are untimed and cover every source/cache artifact.

Speed runs explicitly disable wall trace, metrics and analysis trace. Wall-only
and combined metrics captures are separate. CPU is process-tree user+system
time; RSS is `wait4` maximum-process RSS, not a sum or simultaneous tree peak.
The [204 speed samples](speed-samples.csv) remain in this review. Bulky raw JSON
(metadata, inputs/output manifests, 44 wall/metrics samples, 492 worker reset
records and selected metrics) is excluded from the final PR diff. It remains
available in the [original measurement snapshot](https://github.com/ikesyo/build_runner_accelerator/tree/2a673a97264be9a3bf99bb14b073ed21fa65d094/docs/benchmarks/phase-reset-2026-10)
and a separate `phase-reset-2026-10-raw-measurements.tar.gz` archive (SHA-256
`551f4c5d82763f533ea60fda81a44741358df256d15216340b5c4ec798e9bcfd`).
The tables below retain the conclusions needed for review. All **248 measured builds** matched
stock bytes: 172 cycle builds with 256 artifacts and 76 mixed builds with 384.
Full logs and per-output hash maps are retained locally under `/tmp/phase-reset`.

## Rejected small experiment

[The unapplied patch](rejected-spool.patch) deduplicates `create_dir_all` calls
for the same parent within one reset. It has no persistent state: writes,
deletions, four delta lists, send order, worker count and join are unchanged.
This is the smallest attempted reduction; it cannot defer work into dispatch
or the next build. It reduces repeated directory checks but not overlay bytes,
RPC count, Analyzer updates or generated contents.

### Directory experiment: speed comparison

Milliseconds, median [minimum, maximum], three alternating repeats.

| Jobs | Case | Baseline | Candidate |
| --- | --- | --- | --- |
| 2 | cold | 3709.0 [3681.6, 4251.6] | 4031.7 [3846.2, 4413.9] |
| 2 | warm-clean | 1879.3 [1680.7, 2022.2] | 1795.3 [1683.6, 1941.0] |
| 2 | no-op | 45.8 [38.1, 50.7] | 34.5 [33.5, 40.7] |
| 2 | one-file | 584.0 [528.6, 593.5] | 402.1 [398.3, 447.5] |
| 2 | broad | 2075.8 [1865.5, 2600.2] | 2032.6 [1950.3, 2040.6] |
| 4 | cold | 3991.8 [3797.1, 4023.3] | 3941.3 [3469.5, 4270.4] |
| 4 | warm-clean | 1679.1 [1676.6, 1818.2] | 1987.3 [1573.9, 2123.1] |
| 4 | no-op | 51.7 [40.0, 55.0] | 45.9 [37.4, 51.8] |
| 4 | one-file | 441.2 [414.2, 635.3] | 503.1 [450.2, 546.4] |
| 4 | broad | 1893.4 [1867.6, 2048.8] | 1988.7 [1818.1, 2257.2] |

Milliseconds, median [minimum, maximum], three alternating repeats.

| Jobs | Case | Baseline | Candidate |
| --- | --- | --- | --- |
| 2 | regen | 2167.2 [2084.1, 2358.6] | 2261.1 [2191.2, 2308.2] |
| 4 | regen | 2309.9 [2291.7, 2349.7] | 2292.9 [2283.9, 2331.2] |

Regen jobs=2 changes 2.167 -> 2.261 s (+4.3%); jobs=4 changes 2.310 ->
2.293 s (-0.7%). Ranges overlap. Prepared jobs=4 warm-clean and broad medians
worsen. The one-file/no-op changes are disproportionate to the tiny directory
check budget and change direction across jobs; they are not a causal speedup.
These observations do not support adoption.

### Final diagnostic-only control: representative mixed fixture

Baseline is unchanged main Rust; candidate contains the retained Rust spans.
The worker and state transitions are common, and tracing is disabled. These
are controls, **not synchronization speedup claims**. Observed differences
between functionally unchanged lanes warn against interpreting a small effect.

Milliseconds, median [minimum, maximum], three alternating repeats.

| Jobs | Case | Baseline | Candidate |
| --- | --- | --- | --- |
| 2 | cold | 4083.5 [4076.1, 4466.5] | 3968.0 [3682.2, 4228.0] |
| 2 | no-op | 53.6 [49.9, 54.6] | 50.2 [49.8, 73.1] |
| 2 | one-file | 601.8 [598.8, 635.9] | 538.0 [530.0, 541.8] |
| 2 | broad | 2236.3 [2233.7, 2288.3] | 2112.4 [2009.7, 2218.4] |
| 2 | regen | 2795.4 [2662.6, 2821.0] | 2554.7 [2412.5, 2713.3] |
| 4 | cold | 4289.9 [3824.9, 4958.2] | 4103.9 [3973.0, 4235.2] |
| 4 | no-op | 57.7 [46.5, 64.6] | 52.4 [47.4, 54.6] |
| 4 | one-file | 611.6 [511.8, 620.4] | 504.8 [502.4, 610.2] |
| 4 | broad | 2214.9 [2075.9, 2374.8] | 2212.9 [2109.7, 2625.1] |
| 4 | regen | 2938.9 [2323.6, 3162.4] | 2628.3 [2580.6, 3327.9] |

The separate cycle controls also cover cold, warm-clean, no-op, one-file, broad
and full regen. Full regen main/diagnostic medians are 2.241/2.376 s at jobs=2
and 2.309/2.248 s at jobs=4. All samples, CPU and RSS remain in the CSV rather
than selecting favorable controls. Small regressions cannot be excluded by
three repeats in this constrained runner.

### Separate wall-only directory experiment

The following is the mixed fixture, baseline with diagnostics versus the
unapplied directory patch. Medians are independent per category; they are not
a single additive representative trace. Per-run partitions in the JSON sum
to that run's native wall.

| Jobs | Interval (ms) | Baseline | Directory experiment |
| --- | --- | --- | --- |
| 2 | Native wall | 2582.3 [2511.9, 2879.5] | 2504.0 [2377.3, 2842.1] |
| 2 | Exclusive phase reset | 54.5 [50.0, 61.4] | 57.3 [47.9, 62.4] |
| 2 | Exclusive dispatch | 1757.7 [1661.3, 1927.7] | 1640.8 [1626.2, 1766.7] |
| 4 | Native wall | 2742.9 [2555.0, 2956.7] | 2945.3 [2758.7, 3008.9] |
| 4 | Exclusive phase reset | 90.6 [76.1, 100.6] | 123.2 [85.8, 134.6] |
| 4 | Exclusive dispatch | 1709.3 [1696.2, 1818.2] | 1809.8 [1759.5, 1950.5] |

Jobs=2 reset does not decrease (54.509 -> 57.298 ms). Jobs=4 reset and dispatch
both worsen (90.610 -> 123.166 ms; 1709.329 -> 1809.840 ms). This does not show
work being saved and then successfully amortized elsewhere. No work is delayed
by this patch, so there is no new queue to charge to the next build. No-op,
one-file and broad controls, including the mixed read/post-process chain, check
that later builds remain correct. A three-run diagnostic cannot establish a
small timing equivalence or explain every scheduling variation.

Per-phase reset medians from the same captures (ms):

| Jobs | Before phase | Baseline | Directory experiment |
| --- | --- | --- | --- |
| 2 | riverpod_generator:riverpod_generator | 0.001 | 0.001 |
| 2 | freezed:freezed | 7.157 | 9.678 |
| 2 | json_serializable:json_serializable | 10.129 | 13.343 |
| 2 | source_gen:combining_builder | 19.163 | 14.523 |
| 2 | riverpod_app:overlay_probe | 8.498 | 8.911 |
| 2 | riverpod_app:probe_post | 4.005 | 3.666 |
| 4 | riverpod_generator:riverpod_generator | 0.001 | 0.001 |
| 4 | freezed:freezed | 15.842 | 15.451 |
| 4 | json_serializable:json_serializable | 17.527 | 22.373 |
| 4 | source_gen:combining_builder | 20.378 | 31.768 |
| 4 | riverpod_app:overlay_probe | 23.217 | 36.170 |
| 4 | riverpod_app:probe_post | 10.203 | 6.592 |

In the cycle baseline wall captures, all-reset spool medians are 6.427 ms at
jobs=2 and 2.383 ms at jobs=4. Worker reset envelopes dominate the frontend reset
partition. Across individual worker resets, directive/graph work medians are
1.670/2.335 ms and adapter/Analyzer filesystem start medians 1.897/4.189 ms
(jobs=2/4); their ranges reach 16.263/25.613 and 25.658/18.621 ms respectively.
These are elapsed worker durations with scheduling effects, not CPU or a
frontend sum. The application may have a much larger byte volume.

Separate combined-metrics mixed captures confirm two driver creations, zero
replacements, zero resolver gets for the probe and post-process, and 10/20
worker reset RPCs at jobs=2/4 (five barriers across two/four initialized workers).
Main and diagnostic lanes send identical total IPC bytes: 1,191,632 at jobs=2,
1,424,020 at jobs=4. These include all build/asset traffic, not just resets.
The directory experiment's cycle captures also preserve RPC counts and bytes.
No resolver cap, scheduler, assignment, single-flight default, AOT strategy or
cache compaction was changed.

## Verification and limits

Local checks passed:

- 101 Rust unit tests (`cargo test --locked --manifest-path rust/Cargo.toml`).
- 28 related Dart tests: phased dependency content, worker step resolver,
  resolver directives and resolver reads. These cover immutable snapshots,
  same-phase/post-process visibility, missing -> present, replacement,
  deletion/rename, nested reader contexts and cache clear/failure recovery.
- 16 wall-summary tests, including the new reset overlap/legacy/watch checks;
  supplied application traces also replay successfully.
- Targeted `dart analyze lib/src/worker.dart`, Dart format for the worker and
  fixture builder, and `git diff --check`.
- Wall-enabled optional correctness: primary/secondary/glob demand, no demand,
  incremental, atomic failure recovery, delete and rename.
- Wall-enabled post-process correctness: no-op, output deletion, input change,
  rename, input deletion and stale-output removal.
- Riverpod native watch: generated-output deletion and source edit with two
  subsequent build events.

Targeted Rust file formatting still reports pre-existing main style changes.
Unchanged main reproduces them; formatting both versions leaves the added
hunk text identical. No unrelated reformat is included. Rustfmt was initially
absent and was installed for the same pinned toolchain. An initial pub-get
attempt lacked sandbox network access; rerunning with authorized network
access passed. Failed setup/control attempts are excluded from the samples.

The full local suite was not run, as requested. Remaining core, current-codegen,
compatibility, platform and dependency-window coverage is delegated to PR CI.
There is no new delayed state machine requiring speculative transition tests;
the new tests verify the diagnostic accounting, while existing relevant
state-transition tests and stock comparisons verify the retained behavior.
The isolated Dart-probe overhead and real application's detailed reset stages
remain unmeasured; application sources and repeated application captures are
needed before an application optimization claim.

## Reproduction

Build unchanged main, this diagnostic candidate, and (only for comparison) a
candidate with `rejected-spool.patch` applied. Use the same SDK, package config,
pub cache, worker and shared cache directory for both lanes. Prime the generated
worker/SDK summaries before timing. If a local Dart wrapper is needed, place it
in the selected SDK's `bin` directory so native manifest-kernel selection finds
that SDK; do not pass CLI-only analytics flags to VM invocations.

```bash
python3 scripts/prepare_cycle_read_fixture.py --root "$cycle"
# Resolve pub and prime its default native worker, outside timings.
python3 scripts/benchmark_cold_build.py   --baseline "$diagnostic_native" --candidate "$experiment_native"   --frontend-dart "$dart" --root "$cycle" --cache "$cache"   --results "$prepared_results" --fixture-kind riverpod-cycle   --worker "$cycle/.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker"   --jobs 2 4 --repeats 3 --stock-check
python3 scripts/benchmark_frontend_regen.py   --baseline "$diagnostic_native" --candidate "$experiment_native"   --dart "$dart" --root "$cycle" --cache "$cache" --results "$regen_results"   --stock-reference "$prepared_results/stock-outputs.json" --jobs 2 4 --repeats 3
python3 docs/benchmarks/phase-reset-2026-10/capture_resets.py   --baseline "$diagnostic_native" --candidate "$experiment_native"   --dart "$dart" --root "$cycle" --cache "$cache" --results "$wall_results"   --stock-reference "$prepared_results/stock-outputs.json" --repeats 3
python3 docs/benchmarks/phase-reset-2026-10/benchmark_mixed.py   --baseline "$main_native" --candidate "$diagnostic_native" --dart "$dart"   --root "$mixed" --cache "$mixed_cache" --results "$mixed_speed" --repeats 3
python3 docs/benchmarks/phase-reset-2026-10/benchmark_mixed.py   --baseline "$diagnostic_native" --candidate "$experiment_native" --dart "$dart"   --root "$mixed" --cache "$mixed_cache" --results "$mixed_wall" --wall   --stock-reference "$mixed_speed/stock-outputs.json" --repeats 3
# For separate driver/resolver/traffic diagnostics, use --wall --metrics --repeats 1.
```

Repeat the cycle speed/capture routes with main/diagnostic binaries for the
instrumentation controls. The mixed helper prepares 384-artifact stock
references itself; wall/metrics runs reuse that checked reference. All roots,
caches and results are disposable and disjoint. For the actual application,
run its unchanged regen procedure with `WALL_TRACE=1`, action metrics disabled,
and collect both frontend `phase_resets` and `BRA_RESET_TRACE` records. Compare
repeated trace-disabled baseline/candidate builds separately; do not subtract
worker durations from the application's native wall.
