# Riverpod first resolver analysis and driver synchronization (2026-10-03)

## Findings

In this fixture, expensive work was concentrated in **initialization per worker
and the first dependency-closure load**, rather than repeated driver
synchronization in every action. Upstream analyzer already shares library
elements and loaded bundles. The investigation did not establish a reason to
add a result cache across actions.

Byte-store fingerprint generation during initialization unnecessarily expanded
the SDK summary into a `List<int>`. The implemented change feeds the same bytes
to SHA-256 in chunks, preserving the exact cache namespace. Warm Riverpod
fixture builds became about 100 ms faster. These are local results with two
samples per variant and cannot be extrapolated to the real application's
improvement rate. No improvement in overall cold-build time was established.

## Starting state and sources

- Initial HEAD: `a722a77db7d8ccc92d0089112a45009871176672`, on branch `work`,
  with a clean working tree. During the investigation, the original branch and
  remote were left unchanged; no push, PR creation, or commit was performed.
- A detached worktree at the same commit was created at
  `/workspace/resolver-fingerprint-baseline` for comparison.
- AGENTS.md, README, development, roadmap, the ADR index, and protocol/v1 were
  read. In particular, ADRs 0009 and 0019 were checked against the current
  implementation. Historical closure counts and synchronization descriptions
  in the ADRs were not reused as current measurements.
- The user's attachment, `build_runner_accelerator-pr78-report.md`, was read
  first and used as the source of real-application measurements. The specified
  PR #78 document was not present locally. It was retrieved read-only from
  `https://raw.githubusercontent.com/ikesyo/build_runner_accelerator/e71ceab/docs/benchmarks/action-resolver-cache-2026-10.md`
  and saved as `/workspace/pr78-action-resolver-cache.md`. PR #78 was not
  revived or continued.
- The real application itself was not available in this environment. The
  breakdown below cannot be retroactively applied to the attachment's 662
  Riverpod actions and 14.5 seconds of aggregate resolver API time. That total
  is neither wall time nor an estimate of removable work.

## Conditions and diagnostic scope

Dart 3.13.3, analyzer 14.3.0, build_runner 2.16.1, riverpod_generator 4.0.9,
and freezed 4.0.1. Linux x64, AMD EPYC 9V74, a two-CPU quota, and an 8 GiB
memory limit. These differ from the real application's Dart 3.13.4 / Flutter
3.47.5 / 4 vCPU / 15 GB environment.

1. The existing `benchmark_riverpod.sh` was run once and confirmed
   byte-identical outputs against stock. That run used debug Rust and was not
   combined with the release comparison.
2. `diagnose_riverpod_resolver.py` added 24 independent Riverpod inputs to the
   existing two-input fixture. The resulting 26 actions share the same
   annotation dependency. Cold, warm clean, no-op, one-file, and broad cases
   were each diagnosed once.
3. An AOT microbenchmark isolated the fingerprint copy's contribution.
4. After the change, only the original two-input fixture was compared using
   release Rust, AOT workers, and `--jobs 1`, in
   baseline/candidate/candidate/baseline order. Each variant's cache was
   primed before measurement. Clean, no-op, one-file, and broad each had two
   samples per variant: 16 measured builds.

The SDK, dependency package roots, Rust binary, and worker count matched
between variants. Rust SHA-256:
`de9555e1084d5106f84c99ead8361c416757e1dfffdce9a107ef92a2d935df4d`.
The change was uncommitted when measured, so comparison metadata also records
hashes of the actual source files. Wall time covers the native frontend only,
excluding the Dart launcher. Cold runs started with empty tool/analyzer caches
and warm pub and OS caches. Warm clean removes generated outputs, the action
graph, and overlay, while retaining manifest, AOT, and analyzer caches.

The original wall timer in the 26-input diagnostic had up to approximately
50 ms of wait-polling error. Those wall measurements were not used for the
performance comparison; the worker's Stopwatch breakdown was used instead.
The added diagnostic script now uses a blocking wait with a watchdog. The A/B
comparison below used a blocking wait from the start.

## First action versus subsequent actions

The 26-input fixture, warm clean. Times are in milliseconds; the first input
was `lib/model.dart`.

| Operation | First Riverpod action | Total for subsequent 25 actions |
| --- | ---: | ---: |
| `libraryFor` | 83.304 | 4.557 |
| Library cycle graph | 52.447 | 1.100 |
| Dependency loads | 289 | 50 (two per action) |
| Directive cache hits | 287 | 25 |
| Directive parse misses | 0 | 0 |
| `applyPendingFileChanges` | 0.338 | 0.240 |
| Filesystem phase setter | Recorded as zero; see below | Recorded as zero; see below |
| Byte-store get | 8.889 | 0.349 |
| Byte-store hits/gets | 450/450 | 50/50 |
| Byte-store put | 0.049 | 0.629 |
| File-content get | 0.019 | Below measurement resolution |

The phase setter's zero is the result of truncating individual calls to integer
microseconds; it does not mean synchronization was skipped. The rows above
contain nested timings and must not be added together. Byte-store and IPC
counters cover the whole action, not exclusive time within `libraryFor`.

The first graph's 52.447 ms includes `readPhased` at 32.984 ms, directive-cache
lookup at 1.975 ms, and dependency prefetch at 14.833 ms, among other work.
There were 64 batch-resolve RPCs taking 9.322 ms. Read and can_read RPCs took
0.516 ms together, with 579 and 292 cache hits respectively. Do not double-count
`readPhased`, prefetch, and RPC timings as independent costs. File-content get
is very small because it returns content already in memory.

For the first action, `libraryFor - cycle_graph_walk` is 30.857 ms. This
residual includes driver change application, FileState work, validation of
analyzed bundles and element-model loading, parsed-unit and syntax checks,
and async/lock overhead. **It is not an element-model-only measurement.**
Exclusive upstream linking, deserialization, and lazy element-accessor times
were not measured. The separate `isLibrary` API also took 11.857 ms, so all
initial analysis cannot be attributed to `libraryFor` either.

In the cold run, the first `libraryFor` took 727.108 ms, graph processing
216.038 ms, directive parsing 76.097 ms, byte-store hits were 0/450, and puts
took 177.180 ms. Subsequent `libraryFor` calls totaled 25.002 ms. Warm runs
could use existing summaries and bundles instead of relinking. Pending-change
application across all builders remained small: 0.708 ms for warm clean and
0.784 ms for broad.

Initialization is separate from the resolver APIs: the warm first get took
121.008 ms, including SDK-summary checks at 0.944 ms, summary reading at
2.126 ms, and `driver_create` at 117.866 ms. Subsequent action records repeat
the initialization profile's values; do not sum those values across actions.
Cold SDK-summary generation took about 1.215 seconds, with only 0.276 ms of
lock wait, so lock contention was not the cause.

## Work already shared upstream

The inspected code came from the current dependencies under
`.pub-cache/hosted/pub.dev/`.

- build_runner's `build/resolver/build_step_resolver.dart` records an action's
  transitive entrypoints and serializes updates through a per-action pool.
  Non-transitive APIs can repeat updates, but that does not imply repeating
  expensive work each time.
- `build/resolver/build_resolver.dart` uses a shared driver pool, SDK library
  enumeration, and the current session. `libraryFor` includes parsed-unit
  checks, library-element retrieval, and syntax checks.
- `build/library_cycle_graph/library_cycle_graph_loader.dart` retains
  `_assetDeps`, `_cycles`, and `_graphs` with phase expiry, loading only unseen
  or expired assets. It also avoids recomputing edges into known cycles.
- analyzer's `dart/analysis/driver.dart:getLibraryByUri` immediately returns a
  library already in the element factory when there are no pending changes.
  `applyPendingFileChanges` verifies changed files and invalidates affected
  libraries.
- `dart/analysis/library_context.dart` excludes existing cycles through
  `loadedBundles`, reads only unloaded cycles from the linked store, and links
  only on bundle misses. Removal and session updates during invalidation are
  necessary work.
- The accelerator retains the driver/model in each worker and already uses a
  content-keyed directive cache, a 128 MiB memory byte store, a packed disk
  store, and batched dependency reads. Workers share the disk cache, but do
  not share element-model objects.

Subsequent actions therefore did not reload the common 289-file closure every
time. They handled additional files such as a new library and its generated
part, which is not visible in the same phase. A new worker in another build or
a full resolver replacement pays initialization and closure-loading costs
again. An incremental phase reset can retain the driver, but graph clearing
after directive changes and full replacement when overlay retrieval fails
must remain intact.

## Implemented change and measured effect

The fingerprint in `sharedAnalysisByteStore` is the first 16 hexadecimal
characters of SHA-256 over the concatenated SDK summary, experiment string,
and analyzer root. The previous spread copied 3,392,521 bytes into a boxed
integer list. The new `analysisByteStoreFingerprint` feeds the same bytes in
the same order to chunked SHA-256. The namespace, byte-store lifetime,
release, dependency tracking, pools, phases, optional/nested outputs, overlay,
commit after all actions succeed, and failure recovery are unchanged.

Median of three AOT microbenchmark samples: spread 117.324 ms → chunked
30.690 ms. All six digests matched. This is a local reduction of about
86.6 ms per initialization, not a reduction multiplied by 662 actions. The
microbenchmark used the SDK bytes and a representative suffix; the effect in
actual builders was checked by the comparison below.

| Warm case | Baseline ms (two samples) | Candidate ms (two samples) | Median difference |
| --- | ---: | ---: | ---: |
| Clean | 428.980 / 400.631 | 315.051 / 313.200 | -100.680 ms (-24.3%) |
| No-op | 7.706 / 7.942 | 7.207 / 7.238 | -0.601 ms |
| One-file | 426.467 / 420.731 | 315.268 / 322.879 | -104.525 ms (-24.7%) |
| Broad | 428.304 / 410.603 | 321.822 / 317.946 | -99.569 ms (-23.7%) |

`driver_create` fell from 115–128 ms to 30.6–31.6 ms. Changes to the first
`libraryFor` and graph timings were small; the reduction was primarily in
initialization. Observed ranges for the build cases do not overlap, but two
samples do not establish a statistical guarantee. No-op has no resolver
actions, so its 0.6 ms difference is not attributed to this change.

Priming with empty tool caches took 31.870 seconds for the baseline and
32.105 seconds for the candidate. Both were single observations including
SDK-summary generation, manifest generation, and worker AOT compilation;
they do not establish an overall cold-build improvement.

## Remaining opportunities and next candidates

- Even completely removing driver synchronization would save only about
  0.7 ms across all builders in this warm fixture. That does not justify the
  risk to visibility and invalidation, so synchronization skipping was not
  implemented.
- The subsequent 25 `libraryFor` calls totaled only 4.6 ms, with 1.1 ms of
  graph work. Even the unrealistic bound of eliminating those costs is small;
  they are not evidence of repeated analysis of shared elements.
- The first graph took 52.4 ms, but `readPhased` has side effects that populate
  the analyzer filesystem. All 52 ms cannot safely be removed. Next, separate
  batch-frontier RPC counts from file reading and decoding, then consider
  transport improvements that preserve each action's dependency tracking and
  optional-output demand.
- The first analyzer residual was about 31 ms. For an exact element
  deserialization/linking breakdown, use analyzer's OperationPerformance or
  CPU profiling to distinguish byte-store gets, `_loadBundle`, FileState
  refresh, syntax parsing, and lazy element access. A high byte-store hit
  rate does not mean deserialization is free.
- The next real-application measurements should identify the first action by
  worker ID and resolver generation, driver initialization counts, phase-reset
  and full-replacement counts, and newly loaded closure files. Collect these
  in a small number of warm regen runs. With N worker initializations, the
  local saving on this SDK would be roughly N × 0.087 seconds, but parallel
  execution and the critical path determine wall-time savings.
- Worker count and resolver batch affinity are further candidates, but this
  investigation used one worker. Object loading remains per worker even with
  a shared disk cache. Check duplicated initialization against available
  parallelism in a large mixed-builder application before changing scheduling.

## Validation, reproduction, and limitations

All six fingerprint-compatibility and packed-store tests passed. Analysis of
the three relevant Dart files also passed. All five 26-input diagnostic cases
matched stock output bytes for 54/54 files. All 16 measured two-input A/B
builds matched stock source outputs and `.g.part` bytes.
`correctness_riverpod.sh` passed all cases: no-op, source edit, generated-output
deletion, and failure rollback/diagnostics. The expected worker error in the
failure case is not a validation failure. Validation was restricted to the
change's scope; the full verification, watch, and multi-worker suites were
not run.

Example diagnostic command (the results directory must not exist):

```bash
cd /workspace/build_runner_accelerator
python3 scripts/diagnose_riverpod_resolver.py \
  --results /workspace/new-resolver-diagnostics --extra-inputs 24 --jobs 1 \
  --dart .toolchains/dart/dart-sdk/bin/dart \
  --native rust/target/release/build_runner_accelerator
```

Local comparison reproduction command (use a new results path):

```bash
env -u HOME PUB_CACHE=/workspace/build_runner_accelerator/.pub-cache \
  python3 /workspace/resolver-fingerprint-comparison.py \
  --baseline-root /workspace/resolver-fingerprint-baseline \
  --baseline-bin /workspace/build_runner_accelerator/rust/target/release/build_runner_accelerator \
  --candidate-root /workspace/build_runner_accelerator \
  --candidate-bin /workspace/build_runner_accelerator/rust/target/release/build_runner_accelerator \
  --dart /workspace/build_runner_accelerator/.toolchains/dart/dart-sdk/bin/dart \
  --results /workspace/new-fingerprint-comparison --jobs 1 --repeats 2
```

Local artifacts:

- `/workspace/resolver-investigation-26/`: metadata, raw logs for all five
  cases, and action JSON.
- `/workspace/resolver-fingerprint-probe.dart` and `.log`: AOT hash diagnostic.
- `/workspace/resolver-fingerprint-ab/`: metadata, measurements, summary, and
  all raw logs.
- `/workspace/resolver-fingerprint-comparison.py`: a local adaptation of the
  existing comparison harness restricted to Riverpod, recording uncommitted
  source hashes and the identical Rust binary. Its fixture package
  configuration comes from the resolved 26-input diagnostic.
- `/workspace/resolver-fingerprint-correctness.log`: correctness validation log.

The attachment's 827/827 matching real-application outputs were the user's
validation of PR #78, not validation of this change. Stock output comparison,
regen measurements, and cold measurements on the real application have not
been performed for this change.
