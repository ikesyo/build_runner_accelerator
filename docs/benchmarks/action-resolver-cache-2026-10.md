# Action-local resolver cache (2026-10-02)

## Implementation boundary

The baseline is `ab079eced1ad22d18d747290b167e65c368cb2d8`.
`WorkerResolversImpl.get` now creates `ActionBuildStepResolver`, a narrow fork
of the resolved build_runner 2.16.1 `BuildStepResolver`. The upstream resolver
memoizes transitive entrypoints but does not memoize `isLibrary`,
`compilationUnitFor`, `libraryFor`, or non-transitive synchronization Futures.
Its shared `BuildResolver` separately caches SDK library enumeration and uses
an analysis-driver pool; those caches and locks remain in place.

The reference was inspected at fast_build_runner commit
`c908a218cb9a663bc4366499e9b2fbfcb895df6b`, in
`packages/fast_build_runner_internal/lib/src/fast_build_step_resolver.dart`.
That implementation also caches readability and shares synchronization/library
lists across actions. This change adopts only action-local API and sync caches.

API keys contain the AssetId and, for units/libraries, `allowSyntaxErrors`.
Only non-transitive synchronization Futures are memoized, keyed by AssetId.
Transitive synchronization uses the successful-entrypoint set and the serial
pool. Pending and successful API/shallow-sync Futures are retained, while
failures are removed before delivery to callers. Successful transitive synchronization satisfies a later shallow sync;
a shallow sync does not satisfy a transitive request. Only successful
transitive entrypoints enter the set used by library enumeration.

`canRead` still runs for every public asset lookup, including cache hits.
Unreadable assets are not memoized. Dependency tracking stays with the action's
BuildStep and the existing driver model. The per-action pool still serializes
synchronization of different entrypoints and upgrades, and the shared driver
pool remains upstream's. Library streams, name lookup, fragment lookup,
asset-ID lookup and release retain upstream behavior. Each get creates fresh
maps, with no cross-action or watch-build resolver retention. Rust scheduling,
optional-output demand, phase resets, overlay visibility and transactional
commit/failure recovery are unchanged. Nested optional actions increment an
invalidation generation before and after execution, including failures. On the
next lookup a suspended action discards its result/sync caches and restores its
phase through normal driver synchronization. Its logical entrypoint set is
retained, so subsequent library streams still enumerate all action entrypoints.
No action objects or cached results are shared by the generation counter.

Thirteen focused tests cover upstream/candidate call counts, pending work,
syntax keys, synchronization upgrades and serialization, retry after sync/API
errors, visibility/missing-asset retries, separate actions and no-op release.
They also cover invalidation on nested work, preservation of library stream
entrypoints, an old failed Future not evicting newer pending work, and an
invalidated pending sync not marking a newer generation as synchronized, and a
queued transitive query retrying after a different syntax policy fails. The
optional-builder fixture adds a resolver-demand case that performs repeated
queries before/after a nested resolver action and then edits a resolver-only
dependency, comparing all output bytes with stock.
For the same sequence of two calls to each of the three asset APIs, upstream
makes six analysis API calls and five syncs; the candidate makes three API
calls and two syncs.

## Measurement method

Dart SDK 3.13.3, rustc 1.98.1, Linux x64 with a 2-CPU quota and 8 GiB
memory limit, release Rust frontend, one worker, AOT worker,
`BUILD_RUNNER_ACCELERATOR_METRICS=1`. Both variants use the same SDK, pub-cache,
builder dependencies, native executable and shared content-addressed tool and
analyzer cache. Worker compilation and cache population happen outside samples.
The baseline package comes from a git archive, so the existing branch is not
moved. The script records actual source hashes for the uncommitted candidate.

The native frontend is measured directly; the Dart launcher is excluded.
Five repetitions alternate baseline/candidate order. Clean removes the action
graph and generated output state while retaining warm tool caches. No-op runs
immediately afterwards. One-file appends a comment to one tracked input; broad
appends a comment to every tracked input. Every case compares all generated
source and `.g.part` bytes against stock build_runner output, including no-op.
The comment edits exercise invalidation without changing expected generated
bytes. These small fixtures do not establish a cold-machine or large-workspace
speedup. No-op dispatches no resolver actions.

Reproduction (paths shown for this workspace):

```bash
repo=/workspace/build_runner_accelerator
base=/workspace/resolver-baseline
mkdir -p "$base"
git -C "$repo" archive ab079eced1ad22d18d747290b167e65c368cb2d8 | tar -x -C "$base"
python3 "$repo/scripts/benchmark_resolver_comparison.py" \
  --baseline-root "$base" \
  --baseline-commit ab079eced1ad22d18d747290b167e65c368cb2d8 \
  --baseline-bin "$repo/rust/target/release/build_runner_accelerator" \
  --candidate-root "$repo" \
  --candidate-bin "$repo/rust/target/release/build_runner_accelerator" \
  --dart "$repo/.toolchains/dart/dart-sdk/bin/dart-task" \
  --results /workspace/resolver-benchmark-final \
  --jobs 1 --repeats 5 --shared-cache
```

The environment's `dart-task` wrapper suppresses analytics and invokes the
selected SDK; it lives in the SDK's bin directory so native SDK discovery is
correct. A writable `BUILD_RUNNER_ACCELERATOR_CACHE` and
`ANALYZER_STATE_LOCATION_OVERRIDE` are supplied to verification because the
managed environment's default home is read-only. The benchmark sets these
paths itself. Fixtures must be resolved first with the same pub cache.

## Initial verification

- `dart test --timeout 2m`: 117 tests passed, including the initial 12 focused resolver
  tests. `dart analyze lib bin test tool` reported no issues; `dart format
  --output=none --set-exit-if-changed lib bin test tool` changed no files.
- Locked Rust tests: 97 passed.
- `JOBS=1 COUNT=10 BUILD_RUNNER_ACCELERATOR_METRICS=1 bash
  scripts/benchmark_matrix.sh`: JSON, Freezed and Riverpod passed, including
  the stock/native generated-output comparisons.
- Full verification passed across all five suite selectors: core and
  current-codegen, then compatibility-lifecycle, compatibility-graph and
  compatibility-mapping. Core includes quick verification and arbitrary-builder
  verification (`VERIFY_ARBITRARY_BUILDER=1`). The suites cover JSON,
  built_value, Freezed, Riverpod, optional/post-process/resource lifetime,
  dependency/glob/phase visibility, source/cache mappings and Drift, including
  watch, output deletion, failure recovery and stock byte comparisons.
- The new `CASE_FILTER=resolver-demand` optional fixture was rerun after the
  final pending-sync generation guard; initial, no-op and dependency-only edit
  all passed with byte-identical stock output.

The full-suite selectors were run with `VERIFY_LEVEL=full` and
`VERIFY_ARBITRARY_BUILDER=1`, covering the union of:

```bash
VERIFY_FULL_SUITES=core,current-codegen bash scripts/verify.sh
VERIFY_FULL_SUITES=compatibility-lifecycle,compatibility-graph,compatibility-mapping \
  bash scripts/verify.sh
```

All validation used the SDK/cache environment described above. An earlier
parallel validation attempt hit the existing short timeouts under the 2-CPU
quota; the final Dart test run and the full verification groups ran separately.
The first lifecycle attempt exposed a missing initial build in the new fixture
setup; that setup was corrected and lifecycle was rerun successfully. The
comparison below uses only final, sequential samples.

## Initial results (before narrowing the sync cache)

Median native wall time in milliseconds, five samples per cell. Negative change
means faster. Every one of the 120 measured builds matched stock output bytes.

| Fixture | Case | Before (ms) | After (ms) | Change |
| --- | --- | ---: | ---: | ---: |
| JSON (10 inputs) | clean | 315.644 | 359.616 | +13.93% |
| JSON (10 inputs) | noop | 4.329 | 4.451 | +2.81% |
| JSON (10 inputs) | one-file | 294.736 | 294.452 | -0.10% |
| JSON (10 inputs) | broad | 328.791 | 332.265 | +1.06% |
| Freezed | clean | 363.605 | 368.712 | +1.40% |
| Freezed | noop | 4.892 | 5.099 | +4.23% |
| Freezed | one-file | 353.535 | 336.992 | -4.68% |
| Freezed | broad | 373.188 | 365.442 | -2.08% |
| Riverpod | clean | 679.020 | 656.015 | -3.39% |
| Riverpod | noop | 11.137 | 10.667 | -4.22% |
| Riverpod | one-file | 711.680 | 596.251 | -16.22% |
| Riverpod | broad | 671.784 | 608.622 | -9.40% |

Riverpod one-file and broad incremental medians decreased by 16.22% and 9.40%;
Freezed incremental medians decreased by 4.68% and 2.08%. JSON clean increased
by 13.93%, while its incremental cases were almost unchanged. This run does
not establish a universal speedup or explain the JSON clean regression.
Subsecond builds on a shared, CPU-limited machine include scheduling variation;
five repetitions are not a significance test. No-op has no resolver actions
and its millisecond changes cannot be attributed to the cache.

The deterministic call-count tests establish the reduction in duplicate work;
these timings give its observed end-to-end impact for these fixtures. Large
workspaces, cold-machine builds and other dependency/SDK versions are untested.
The fork follows build_runner 2.16.1 private APIs and needs review when that
upstream implementation changes. Failed results are deliberately retried;
library streams remain uncached, and nested optional work invalidates cached
results to preserve visibility. Caches end with the action and are not reused
across actions or watch builds.

Raw artifacts for this workspace are in `/workspace/resolver-benchmark-final`:
`summary.json`, `measurements.json` (all samples, commands and action metrics),
`metadata.json` (SDK, dependency roots/lock hashes and implementation hashes),
and per-build logs. Verification logs are `/workspace/resolver-dart-test-solo.log`,
`/workspace/resolver-rust-test.log`, `/workspace/resolver-analyze-final.log`,
`/workspace/resolver-format-final.log`, `/workspace/resolver-full-isolated.log`,
`/workspace/resolver-full-remaining.log`, `/workspace/resolver-optional-final.log`
and `/workspace/resolver-benchmark-matrix.log`.

Implementation SHA-256 identities (actual file contents):

- baseline Dart sources: `e775ecbcd90e6dba06f8fb2ab3abaa562ccd59f36e54173ebea3fbfdfd155943`.
- candidate Dart sources: `f8ee709df7d02e536c34ac4b117324e021dcff9969f906756170d633f5ad4500`.
- Shared native binary: `de9555e1084d5106f84c99ead8361c416757e1dfffdce9a107ef92a2d935df4d`.

## Regression investigation and cache narrowing

The initial JSON clean +13.93% result was investigated without changing the
implementation first. The original prepared workspaces, SDK, native executable,
dependencies and shared caches were reused; each new run wrote separate logs
and metadata rather than overwriting the initial samples. Thirty repetitions
alternated variant order, with all four cases and all stock byte comparisons.

Median native wall time in milliseconds; each before/after cell has 30 samples.

| Metrics | Case | Upstream (ms) | Initial cache (ms) | Change |
| --- | --- | ---: | ---: | ---: |
| on | clean | 329.874 | 328.517 | -0.41% |
| on | noop | 4.837 | 4.892 | +1.14% |
| on | one-file | 291.751 | 299.417 | +2.63% |
| on | broad | 331.707 | 343.120 | +3.44% |
| off | clean | 319.997 | 316.667 | -1.04% |
| off | noop | 4.678 | 4.739 | +1.31% |
| off | one-file | 285.976 | 290.282 | +1.51% |
| off | broad | 318.299 | 321.677 | +1.06% |

The 14% clean regression did not reproduce, even before narrowing. With metrics
on, the clean interquartile ranges were 317.805–356.541 ms (upstream) and
319.412–348.062 ms (initial cache). Metrics-off CPU time for clean was
333.091→328.830 ms, one-file 292.219→296.378 ms and broad
329.833→334.861 ms. These are per-build user+system child CPU medians; they
include the worker process, not just resolver work. Small incremental median
increases remain in these runs; they should not be claimed to be zero overhead.

To isolate the caches, immutable copies of the initial candidate were compared:
API-only disables `_memo` for `_syncs`; sync-only disables it for the three API
result maps. Both variants retain readability checks, the successful transitive
entrypoint set, pool serialization, failure handling and nested-action epochs.
The disabled paths call `load()` directly; unused empty maps remain in these
experimental copies. There are no runtime ablation switches in the product.
Each comparison used metrics off, the same warm caches and 30 repetitions.

| Ablation baseline | Case | Ablation (ms) | Both caches (ms) | Change |
| --- | --- | ---: | ---: | ---: |
| api-only | clean | 322.397 | 319.375 | -0.94% |
| api-only | noop | 4.895 | 4.884 | -0.24% |
| api-only | one-file | 291.301 | 289.754 | -0.53% |
| api-only | broad | 328.841 | 328.759 | -0.02% |
| sync-only | clean | 315.357 | 318.944 | +1.14% |
| sync-only | noop | 4.454 | 4.595 | +3.16% |
| sync-only | one-file | 284.867 | 287.657 | +0.98% |
| sync-only | broad | 314.594 | 318.652 | +1.29% |

The wall-time differences are around 1% or less for resolver-bearing cases.
These small JSON workloads do not establish which cache improves overall wall
time. They also do not reproduce a large cache-related cost. The API-only
comparison isolates adding sync memoization; the sync-only comparison isolates
adding API memoization. The 13 focused correctness tests demonstrate duplicate
work reduction independently of timing variability.

The final implementation therefore retains action-local API result and shallow
sync caches, but removes transitive-sync Future memoization. Transitive work is
already deduplicated by the successful entrypoint set and serial pool, and
identical library queries share the API Future. Keeping a second Future map for
that path was redundant. The shallow-sync map now uses AssetId directly, rather
than an `(AssetId, transitive)` tuple. Distinct syntax policies still have
distinct API keys. A new test checks that a queued query with a different syntax
policy can retry synchronization after the preceding transitive sync fails.

This reduction is justified by duplicated bookkeeping and the upstream contract,
not by claiming it caused the unreproduced 14% change. Cross-action sharing was
not introduced: these measurements provide no reason to add its visibility and
dependency-tracking complexity.

Commands for the unchanged-candidate regression reruns:

```bash
# Add the baseline/candidate roots, binaries and SDK from the command above.
python3 scripts/benchmark_resolver_comparison.py ... \
  --results /workspace/resolver-recheck-metrics-on \
  --prepared-results /workspace/resolver-benchmark-final \
  --fixtures json_serializable_10_app --jobs 1 --repeats 30 \
  --shared-cache --metrics 1
# Repeat with --metrics 0 and a fresh --results directory.
```

The immutable initial candidate is `/workspace/resolver-ablation-full`; its
source hash equals the initial candidate hash above. API-only and sync-only
packages are `/workspace/resolver-ablation-api` and
`/workspace/resolver-ablation-sync`. Comparisons use `--fixture-root` pointing
to this repository and `--cache-root /workspace/resolver-benchmark-final`,
with those experiment packages as baseline/candidate roots. Artifacts for each
run are under `/workspace/resolver-recheck-metrics-{on,off}` and
`/workspace/resolver-ablation-{api,sync}-vs-full`, including full per-case sample
records, interquartile ranges, paired changes, CPU times where collected,
implementation hashes and build logs. All 960 measured builds across these four
runs were byte-identical to stock.

## Final validation after narrowing

`VERIFY_LEVEL=full VERIFY_ARBITRARY_BUILDER=1
VERIFY_FULL_TIMEOUT_GUARD=1 bash scripts/verify.sh` passed all five suites in
one invocation, with the same SDK and writable verification cache paths shown
above. The per-suite times were core 1281 s, current-codegen 485 s, lifecycle
651 s, graph 163 s and mapping 794 s. This includes quick/arbitrary-builder,
all relevant stock byte comparisons, watch and failure recovery, including the
new optional resolver-demand fixture and Drift analyzer jobs 1/2. The log is
`/workspace/resolver-narrow-full.log`.

The 13 focused resolver tests passed, including the new queued-retry test;
`dart analyze lib bin test tool` reported no issues. Logs are
`/workspace/resolver-narrow-tests.log` and
`/workspace/resolver-narrow-analyze.log`. The call-count reduction remains
six→three analysis API calls and five→two driver synchronizations.

`dart test --timeout 2m` passed all 118 tests on the final implementation,
including the 13 resolver tests. Log: `/workspace/resolver-narrow-dart-all.log`.

## Final performance (narrowed cache, metrics off)

Thirty repetitions per variant/case, alternating order; same SDK, release
native executable, pub/dependencies, shared warm tool/analyzer caches and one
worker. Every one of the 720 measured builds matched stock source and `.g.part`
bytes. Compilation remained outside samples. The environment status briefly
changed to `starting` during Riverpod priming; the existing benchmark process
continued, with the same files, SDK and 2-CPU quota. No Riverpod measured sample
was active at that transition; both prime/warmup runs finished before its
samples. JSON and Freezed samples were already complete.

Wall times in milliseconds; brackets give the 25th–75th percentile range.
Negative change means faster.

| Fixture | Case | Upstream median [IQR] (ms) | Narrowed median [IQR] (ms) | Change |
| --- | --- | ---: | ---: | ---: |
| JSON (10 inputs) | clean | 323.096 [310.174–336.601] | 325.140 [311.581–353.713] | +0.63% |
| JSON (10 inputs) | noop | 4.528 [4.226–4.793] | 4.482 [4.341–5.040] | -1.01% |
| JSON (10 inputs) | one-file | 291.474 [277.537–309.257] | 284.207 [277.623–331.461] | -2.49% |
| JSON (10 inputs) | broad | 327.019 [311.892–378.378] | 321.583 [309.529–350.787] | -1.66% |
| Freezed | clean | 348.370 [342.252–355.379] | 343.514 [338.364–350.341] | -1.39% |
| Freezed | noop | 4.903 [4.677–5.230] | 4.884 [4.646–5.713] | -0.39% |
| Freezed | one-file | 331.230 [326.884–341.340] | 330.602 [324.058–336.401] | -0.19% |
| Freezed | broad | 351.792 [345.608–358.651] | 348.008 [340.567–356.934] | -1.08% |
| Riverpod | clean | 542.231 [536.817–556.940] | 544.831 [535.543–557.056] | +0.48% |
| Riverpod | noop | 9.973 [9.787–10.772] | 10.067 [9.836–10.617] | +0.94% |
| Riverpod | one-file | 541.950 [535.079–547.198] | 542.383 [533.156–558.514] | +0.08% |
| Riverpod | broad | 551.495 [542.496–558.125] | 548.801 [543.513–562.387] | -0.49% |

The final resolver-bearing median changes range from -2.49% to +0.63%. JSON
clean is +0.63%, rather than the initial +13.93%; that earlier large regression
was also absent in the unchanged-candidate reruns. The initial large Riverpod
incremental gains did not reproduce either. These results support keeping the
change as duplicate-work reduction, with nearly flat total build time on these
fixtures, rather than claiming a large end-to-end speedup. Interquartile ranges
overlap, and zero overhead or a universal improvement is not established.
No-op changes are not resolver-cache effects.

Final reproduction (using the SDK/package roots from above):

```bash
repo=/workspace/build_runner_accelerator
python3 "$repo/scripts/benchmark_resolver_comparison.py" \
  --baseline-root /workspace/resolver-baseline \
  --baseline-commit ab079eced1ad22d18d747290b167e65c368cb2d8 \
  --baseline-bin "$repo/rust/target/release/build_runner_accelerator" \
  --candidate-root "$repo" \
  --candidate-bin "$repo/rust/target/release/build_runner_accelerator" \
  --dart "$repo/.toolchains/dart/dart-sdk/bin/dart-task" \
  --results /workspace/resolver-narrow-benchmark-final-reproduction \
  --cache-root /workspace/resolver-benchmark-final \
  --jobs 1 --repeats 30 --shared-cache --metrics 0
```

Artifacts: `/workspace/resolver-narrow-benchmark-final/{metadata,measurements,summary}.json`
and per-build logs, plus `/workspace/resolver-narrow-benchmark-final.log`. The
final source hash below was checked against the actual final Dart sources after
measurement. The baseline remains the original commit; there was no branch
movement or remote push.

- Final candidate Dart source SHA-256: `fff9f347fdb07421574403decfc2065158b79468b9e81014ebf0c46c4263f7fd`.
- Native binary SHA-256: `de9555e1084d5106f84c99ead8361c416757e1dfffdce9a107ef92a2d935df4d`.

## Post-rebase performance (2026-10-03)

Compared main `a722a77db7d8ccc92d0089112a45009871176672` with rebased
candidate `05e9bbfcb4ceb51d52ac9a8c2ca4b4445324a33c` (including #77).
Dart 3.13.3, Linux x64, 2-CPU quota / 8 GiB memory, one worker,
metrics disabled, shared warm tool/analyzer cache, the same release native
binary and dependency roots for both variants. Thirty alternating repetitions
per variant/case; compilation and warmup excluded. All 720 measured builds
matched stock generated source and `.g.part` bytes. This measures the native
frontend and excludes launcher overhead and cold AOT startup.

The current JSON fixture resolves analyzer 14.4.0; Freezed and Riverpod
resolve analyzer 14.3.0. Both variants use the same versions within each
fixture; earlier measurements must not be treated as an identical dependency
environment. Exact dependency roots and source/binary hashes are in metadata.

Wall-time medians and 25th–75th percentile ranges, milliseconds.

| Fixture | Case | Main median [IQR] (ms) | PR median [IQR] (ms) | Change |
| --- | --- | ---: | ---: | ---: |
| JSON (10 inputs) | clean | 301.215 [299.609–307.069] | 298.657 [292.935–305.340] | -0.85% |
| JSON (10 inputs) | noop | 4.396 [4.201–4.645] | 4.358 [4.145–4.521] | -0.85% |
| JSON (10 inputs) | one-file | 272.287 [269.341–277.147] | 269.907 [265.688–274.483] | -0.87% |
| JSON (10 inputs) | broad | 305.145 [299.057–312.001] | 297.758 [293.029–308.671] | -2.42% |
| Freezed | clean | 332.141 [329.452–338.657] | 335.099 [328.836–343.646] | +0.89% |
| Freezed | noop | 4.818 [4.600–5.045] | 4.858 [4.658–5.045] | +0.85% |
| Freezed | one-file | 318.788 [312.024–334.892] | 319.630 [315.398–328.451] | +0.26% |
| Freezed | broad | 335.205 [327.999–338.310] | 333.882 [330.236–337.302] | -0.39% |
| Riverpod | clean | 525.562 [511.500–543.038] | 531.072 [520.035–542.582] | +1.05% |
| Riverpod | noop | 10.226 [9.925–10.620] | 10.021 [9.761–10.437] | -2.00% |
| Riverpod | one-file | 530.546 [516.925–542.132] | 527.696 [517.790–543.070] | -0.54% |
| Riverpod | broad | 542.631 [523.174–553.735] | 540.287 [519.784–558.517] | -0.43% |

Resolver-bearing median changes range from -2.42% to +1.05%; every case
has overlapping interquartile ranges. The result is consistent with nearly
flat total build time, rather than a demonstrated end-to-end speedup or
absence of overhead. No-op does not execute resolver actions. Cold-cache,
large-project and other-SDK performance remain unestablished.

Reproduction:

```bash
python3 /workspace/resolver-rebase/scripts/benchmark_resolver_comparison.py \
  --baseline-root /workspace/resolver-rebase-baseline \
  --baseline-commit a722a77db7d8ccc92d0089112a45009871176672 \
  --baseline-bin /workspace/build_runner_accelerator/rust/target/release/build_runner_accelerator \
  --candidate-root /workspace/resolver-rebase \
  --candidate-bin /workspace/build_runner_accelerator/rust/target/release/build_runner_accelerator \
  --fixture-root /workspace/build_runner_accelerator \
  --dart /workspace/build_runner_accelerator/.toolchains/dart/dart-sdk/bin/dart-task \
  --results /workspace/resolver-rebase-benchmark-reproduction \
  --cache-root /workspace/resolver-benchmark-final \
  --jobs 1 --repeats 30 --shared-cache --metrics 0
```

Artifacts: `/workspace/resolver-rebase-benchmark/{metadata,measurements,summary}.json`
and per-build logs; console log `/workspace/resolver-rebase-benchmark.log`.

## Investigation and performance decision (2026-10-03)

The goal of a significant improvement with no measured regression across all
four cases and three fixtures was **not achieved**. Retain the PR as a draft;
do not treat the synthetic call-count reduction as evidence of a production
end-to-end speedup. No additional runtime optimization is justified by these
fixture results alone. There are small positive wall/CPU medians in some
cases, so zero overhead cannot be asserted.

### Paired analysis of existing samples

No new timing repetitions were added for this analysis. Pair the 30 samples
by iteration; compare CPU user+system medians and separate baseline-first
from candidate-first iterations. The following exploratory bootstrap uses
2,000 resamples of the paired percent differences (seed 42). Intervals are
descriptive, unadjusted for multiple comparisons, and assume independent
pairs despite possible time correlation. They are not a performance guarantee.

| Fixture | Case | Paired median change | Bootstrap 95% interval | CPU median change |
| --- | --- | ---: | ---: | ---: |
| Freezed | clean | -0.29% | [-0.82%, +0.91%] | +0.36% |
| Freezed | noop | +0.42% | [-2.97%, +7.75%] | -0.91% |
| Freezed | one-file | +0.11% | [-0.94%, +2.50%] | +0.71% |
| Freezed | broad | +0.27% | [-1.37%, +1.05%] | +0.15% |
| JSON | clean | -1.21% | [-1.86%, -0.42%] | -0.71% |
| JSON | noop | -0.63% | [-6.00%, +3.94%] | -2.60% |
| JSON | one-file | -1.15% | [-2.07%, -0.04%] | -1.09% |
| JSON | broad | -1.86% | [-2.60%, -0.71%] | -2.47% |
| Riverpod | clean | +0.11% | [-2.31%, +3.27%] | +1.38% |
| Riverpod | noop | -1.16% | [-4.29%, +0.13%] | -1.37% |
| Riverpod | one-file | -0.25% | [-1.68%, +2.22%] | -0.77% |
| Riverpod | broad | +0.04% | [-1.93%, +2.68%] | -0.10% |

JSON has a small favorable signal, but its workload counters below show no
cache reuse, so that signal cannot be attributed to avoided duplicate
resolver work. Freezed and Riverpod paired intervals cross zero. Riverpod
clean order-group medians are +2.47% when baseline runs first and -1.00%
when candidate runs first, illustrating sensitivity to run conditions.
No-op dispatches no resolver actions at all. Possible contributors include
system scheduling/OS cache effects and changed AOT code generation or
allocation; this investigation does not isolate their individual shares.

### Workload counters, not another timing campaign

An isolated archive at `/workspace/resolver-cache-probe` added temporary
per-action counters to `_memo` and the actual driver-sync branch, printing
an aggregate to stderr on release. The production source was unchanged.
The same comparison helper ran **one** repetition of each case with metrics
enabled: 24 measured builds, all byte-identical to stock. Extra diagnostics
affect timings; these runs establish call counts only, not speedups.

Clean/broad counts are the same for each fixture:

| Fixture | Resolver actions | isLibrary hits/misses | Unit hits/misses | Library hits/misses | Shallow sync hits/misses | Actual shallow/transitive syncs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JSON (10 inputs) | 20 | 0/10 | 0/10 | 0/20 | 0/20 | 10/20 |
| Freezed | 4 | 0/3 | 2/3 | 0/4 | 2/4 | 3/4 |
| Riverpod | 6 | 0/4 | 1/5 | 0/6 | 3/6 | 4/6 |

One-file unit/shallow hit counts are JSON 0/0, Freezed 1/1, Riverpod 1/2.
No-op has no actions or cache traffic. Shallow miss counts include calls
after a successful transitive sync; the per-action success set skips the
actual driver sync in that case, as upstream already does.

Thus JSON performs no duplicated-key work that this cache can eliminate.
In Freezed and Riverpod it saves a few shallow synchronizations and parsed
unit lookups; it does not save any repeated `isLibrary` or `libraryFor` calls
in these cases. Upstream analyzer sessions already retain parsed units and
library elements, so repeating a wrapper lookup does not normally repeat
the full analysis. Initial linking/element-model load, driver phase changes,
dependency walks, worker setup, and generation remain. The required
`canRead`/input tracking also remain on cache hits.

In the single diagnostic clean run, total unit-call time was 558→455 µs
for Freezed and 715→560 µs for Riverpod, against roughly 330/530 ms
uninstrumented build medians. These are scope indicators rather than
reliable savings estimates. Cache misses add maps, generation checks,
Future wrappers and eviction callbacks; their cost is not quantified
separately. Synthetic tests exercise six repeated API calls and prove
6→3 API / 5→2 sync counts, which is a different workload.

The diagnostic reproduction uses the existing comparison command with
`--candidate-root /workspace/resolver-cache-probe`,
`--results /workspace/resolver-cache-probe-results`,
`--repeats 1 --metrics 1`, keeping the other arguments unchanged.
Artifacts: `/workspace/resolver-cache-probe-counts.json`,
`/workspace/resolver-cache-paired-analysis.json`,
`/workspace/resolver-cache-probe-results/{metadata,measurements,summary}.json`
and per-build logs. The instrumented archive is intentionally not committed.

### Alternatives and stopping point

- First find a representative real project/builder that repeats the same
  resolver key within an action. Establish its hit rate before investing in
  more timing repetitions or further API-cache variants. Keep this cache
  as an experimental candidate until that workload shows a material gain.
- Profile the first library/element load and worker/SDK initialization. Those
  paths dominate more than the few redundant parsed-unit lookups here;
  use existing warm byte-store and initialization metrics to choose one
  concrete optimization, and compare cold startup separately from warm builds.
- For cross-action sharing, first measure repeated lookup cost and frequency
  across actions. Analyzer sessions already share much of the expensive
  state. Another result cache needs phase/generation invalidation and replay
  of each action’s dependencies, especially around optional/nested outputs.
  These data do not justify that additional implementation scope.

No additional full verification suite was run for this documentation-only
conclusion; the rebase tests and previous full correctness run remain the
runtime validation. The 24 diagnostic builds add relevant stock byte checks.
Further repetitions would refine small differences without creating absent
cache reuse, so this investigation stops rather than extending the campaign.
