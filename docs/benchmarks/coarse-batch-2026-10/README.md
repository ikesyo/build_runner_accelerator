# Coarse batch allocation: smaller tails, no default adoption

Work started from freshly fetched main `f57b5faaf75173d049ba3a2a79c350e08b074172`
(PR #89 merged). GitHub comparison confirmed that this was still latest main;
there were no intervening changes to overlap. Existing fixed count allocation
remains the default. This draft implements **opt-in experiments**, not a claimed
application speedup or a recommendation to change the default scheduler.

The three-quarter prefix/tail variant is the smallest tested implementation
with a substantial reduction in the deliberately skewed phase's finish gap.
Whole-build changes are small, ranges overlap, balanced cold jobs=2 worsens,
and jobs=1 controls also vary even though allocation is unchanged. Extra
cross-worker analysis and repeated IPC offset some of the phase benefit.

## Supplied application diagnosis

The supplied PR #89 report and anonymized `wall_{cold,regen}.log` /
`wmt_{cold,regen}.log` archive were read as diagnostic evidence. In the wall-only
regen, native wall is 16.605995 s and exclusive phase dispatch is 12.739363 s
(76.7%). The mockito phase dispatch is 5.794160 s. Its two batches start
153 microseconds apart and take 3.479397 / 5.792562 s, ending 2.313318 s apart.
The report also records 7.274 / 9.602 s cold batches and 227/226 requests but
60/85 generated outputs in the metrics capture. Rust request count is therefore
a weak predictor of work; frontend result recording/commit is not the main tail.

Equalizing unchanged work would suggest about 1.16 s from
`max(T1,T2) - (T1+T2)/2`, not all 2.315 s of wait. This assumes unchanged analysis,
IPC and CPU work; it is neither a guarantee nor a strict bound. Each supplied
condition ran once. The private application's sources were unavailable, and
none of the fixture results below are measurements of that application.

## Allocation and lifecycle analysis

`WorkerPool::build_parallel` retains resolver classification, shared-byte-store
policy, the existing resolver cap and resident pool. At jobs=2/4 this fixture
still executes each resolver phase on **two analysis workers**; jobs=4 starts
four resident workers, two of which do not execute these phases. Jobs=1 and
serialized resolver paths are unchanged.

`BUILD_RUNNER_ACCELERATOR_BATCH_SCHEDULER` selects an experimental ordinary-path
scheduler only for at least 32 requests per participant:

| Value | Initial assignment | Remaining work | Protocol batches per original range |
| --- | --- | --- | --- |
| unset, `static`, unknown | Original balanced contiguous count range | Original worker completes it | 1 |
| `tail` | Reserve the first half on its original worker | Two quarters; own queue first, then steal an unstarted donor tail | 3 |
| `tail2` | Reserve the first three quarters on its original worker | One final quarter; own queue first, then steal an unstarted donor tail | 2 |
| `queue` | Common ordered queue of half/quarter/quarter pieces | Next idle worker claims a piece | 3 |

Prefixes are reserved before threads start, so a fast worker cannot steal another
worker's initial group. An in-flight piece never moves. The mutex protects only
range claims; one thread holds each worker through the whole dispatch. No extra
worker, action-level RPC, cost history or persistent scheduler cache is added.

Each piece calls the existing `WorkerClient::build_batch` with unchanged phase,
visibility and immutable overlays. Its blocked list covers the whole phase,
not only the piece. Wire count/batch ID/item ID validation happens before
mapping results back to original request order and original count-partition
local IDs. All participants join before result integration. Builder failures
keep their request position; protocol failures return no partial result vector.
Outputs and graph still commit only after all dirty actions succeed.

Dart's `_handleBuildBatch` clears only its batch entrypoint collection. Resolver,
read cache, builder instances, ResourceManager, produced-output state and
sent dependency-graph identity map remain resident across pieces. Phase resets,
source/cache overlay visibility and dependency graph integration keep their
existing boundaries. No Dart runtime or protocol frame changes were needed.

Optional/lazy dispatch retains its original serial path, including nested
builders, mutable overlays and demand stack. Post-process requests retain
their existing fixed allocation; large rewrite/deletion batches were not
performance-validated by this fixture. Single-worker and small
batches conservatively use the original path. Stateful builders retain their
per-worker lifetimes, but changed membership/order can change counter-emitting
outputs: this does not establish arbitrary stateful stock-byte compatibility at
jobs>1. Mode changes do not invalidate the graph; regenerate when studying
assignment changes. See [proposed ADR 0027](../../adr/0027-experimental-coarse-batch-scheduling.md).

## Fixture and comparison conditions

The cycle fixture has 64 inputs using Riverpod, Freezed and JSON generation,
four normal phases and 144 shared conditional/transitive sources. It produces
128 source outputs and 128 cache parts. The skewed condition adds 23 extra
annotated provider functions to each of the last 32 inputs: **request and output
file counts stay the same**, but those actions generate more bytes/work.
The balanced condition removes those extra declarations. Both conditions use
the same workspace paths and prepared worker; source fingerprints identify them.

All groups ran serially, before correctness checks. Main and candidate use Dart
3.13.3, Rust 1.98.1, the same lock/package config, pub cache, worker AOT bytes,
SDK-summary/analyzer state, and cache paths. This Linux container has a two-CPU
quota and 8 GiB memory: jobs=4 is not four physical CPUs. OS page cache is not
flushed. [Toolchain identities](toolchain.json), [metadata](metadata.json) and
[deduplicated input manifests](inputs.json) record the exact inputs.

- `cold`: prepared AOT/manifest and SDK summaries retained; graph/outputs and
  byte-store/directive caches cleared before each lane.
- `warm-clean`: graph/outputs cleared; shared caches and prepared worker retained.
- `regen`: whole workspace accelerator directory and source outputs removed;
  shared caches retained; manifest generation and AOT restore/validation included.
- `no-op`: unchanged committed graph; must report no work.
- `one-file` / `broad`: real provider-function renames must change generated bytes.

Native binaries are measured directly, excluding the launcher. Lanes alternate
by repeat (main/candidate, candidate/main). Stock references are untimed and use
the same SDK/dependencies. Every measured build checks all 256 output hashes
against its stock reference. Final review restricts the prototype to normal builders; the measured normal
algorithms are unchanged. Measured binary identities are retained separately
from the final correctness build. Baseline is compiled before source edits; worker
code is unchanged and byte-identical between lanes. Trace-disabled speed runs
explicitly disable wall trace, metrics and analysis trace. Wall-only and combined
metrics/analysis captures below are separate conditions, not speed comparisons.

## Trace-disabled wall comparison

Milliseconds, median [minimum, maximum], three alternating repeats per lane,
case and jobs for `tail2`. All raw samples, including the pilots, are in
[samples.csv](samples.csv); CPU/RSS distributions are in [summary.json](summary.json).

### Skewed inputs

| Jobs | Case | Fixed ranges | 3/4-prefix + 1/4-tail |
| --- | --- | --- | --- |
| 1 | cold | 3602.1 [3563.5, 3627.5] | 3358.8 [3314.4, 3681.3] |
| 1 | warm-clean | 2075.1 [2037.4, 2164.9] | 1960.7 [1950.2, 2134.4] |
| 1 | regen | 2671.2 [2625.1, 2706.0] | 2727.9 [2706.5, 2825.7] |
| 1 | no-op | 38.6 [38.4, 42.2] | 37.4 [35.5, 37.7] |
| 1 | one-file | 386.1 [377.2, 394.8] | 361.4 [358.6, 381.6] |
| 1 | broad | 2396.1 [2308.2, 2439.1] | 2452.7 [2396.0, 2499.9] |
| 2 | cold | 3352.3 [3129.9, 3494.0] | 3274.8 [3009.8, 3540.6] |
| 2 | warm-clean | 1765.3 [1724.5, 1866.6] | 1701.3 [1530.4, 1781.1] |
| 2 | regen | 2459.2 [2310.2, 2523.4] | 2426.3 [2318.5, 2432.3] |
| 2 | no-op | 38.3 [36.5, 38.8] | 37.7 [37.2, 38.5] |
| 2 | one-file | 385.5 [379.2, 406.6] | 370.2 [358.9, 382.3] |
| 2 | broad | 2039.1 [1978.4, 2081.1] | 1917.0 [1841.4, 1937.6] |
| 4 | cold | 3487.0 [3288.1, 3506.4] | 3456.5 [3355.4, 3551.9] |
| 4 | warm-clean | 1785.3 [1782.6, 1856.1] | 1750.6 [1712.5, 1801.3] |
| 4 | regen | 2383.7 [2380.6, 2480.0] | 2330.3 [2307.5, 2423.4] |
| 4 | no-op | 39.8 [39.2, 39.9] | 38.5 [36.7, 39.7] |
| 4 | one-file | 375.4 [366.6, 384.3] | 388.5 [356.2, 401.2] |
| 4 | broad | 2022.4 [1871.6, 2056.9] | 1992.2 [1813.0, 2015.3] |

At jobs=2, prepared warm-clean changes 1.765 -> 1.701 s (-3.6%), broad changes
2.039 -> 1.917 s (-6.0%), but full regen changes only 2.459 -> 2.426 s (-1.3%).
These distributions overlap. The unchanged jobs=1 route also moves in either
direction; its differences are a noise/control warning, not a scheduler benefit.

### Balanced inputs

| Jobs | Case | Fixed ranges | 3/4-prefix + 1/4-tail |
| --- | --- | --- | --- |
| 1 | cold | 3258.1 [2969.7, 3383.7] | 3098.4 [2998.6, 3239.5] |
| 1 | warm-clean | 1637.2 [1611.3, 1641.2] | 1628.6 [1592.4, 1673.3] |
| 1 | regen | 2271.5 [2254.0, 2396.0] | 2223.8 [2199.0, 2342.4] |
| 1 | no-op | 31.6 [31.5, 31.9] | 32.0 [31.0, 33.5] |
| 1 | one-file | 376.0 [372.9, 380.4] | 375.3 [350.7, 380.6] |
| 1 | broad | 1948.2 [1872.7, 2068.4] | 1964.4 [1890.8, 1974.4] |
| 2 | cold | 2753.4 [2753.1, 2930.2] | 2881.8 [2813.1, 2988.9] |
| 2 | warm-clean | 1342.6 [1325.9, 1409.0] | 1344.6 [1330.7, 1365.0] |
| 2 | regen | 2017.0 [1975.7, 2127.9] | 2043.7 [2000.3, 2111.5] |
| 2 | no-op | 32.5 [31.3, 33.1] | 32.3 [31.6, 33.0] |
| 2 | one-file | 386.1 [351.7, 421.2] | 380.5 [376.1, 386.2] |
| 2 | broad | 1459.0 [1445.6, 1592.4] | 1489.7 [1449.8, 1595.7] |
| 4 | cold | 3070.7 [3030.7, 3143.8] | 2954.6 [2590.7, 3006.2] |
| 4 | warm-clean | 1405.6 [1388.8, 1412.5] | 1416.3 [1408.1, 1418.5] |
| 4 | regen | 2022.5 [1993.0, 2056.1] | 2002.6 [1982.8, 2128.0] |
| 4 | no-op | 31.9 [30.9, 32.5] | 32.7 [32.0, 33.1] |
| 4 | one-file | 382.7 [377.5, 405.4] | 376.5 [372.4, 378.3] |
| 4 | broad | 1564.5 [1546.2, 1576.9] | 1550.0 [1432.9, 1554.6] |

Balanced jobs=2 cold changes 2.753 -> 2.882 s (+4.7%); warm-clean is essentially
flat and broad is slightly worse. Jobs=4 varies in the opposite direction on
cold. Full regen ranges overlap at both jobs settings. Generic default adoption
is not supported by these groups.

### Other coarse allocation controls

Independent paired groups; compare each candidate only with its own baseline.
The initial 3-piece pilot inherited `BATCH_SCHEDULER=tail`; untouched main ignored
that unknown variable. The later harness records the explicit candidate option.
The 5-repeat group repeats the same 3-piece algorithm with request-byte counters.

| Experiment | Repeats | Jobs | Case | Fixed | Candidate |
| --- | --- | --- | --- | --- | --- |
| 3-piece tail pilot | 3 | 2 | cold | 3302.2 [3137.6, 3431.3] | 3198.9 [3139.5, 3317.9] |
| 3-piece tail pilot | 3 | 2 | warm-clean | 1767.5 [1612.8, 1770.6] | 1734.5 [1673.4, 1807.9] |
| 3-piece tail pilot | 3 | 2 | broad | 1994.7 [1835.4, 2025.3] | 1943.6 [1922.6, 1947.1] |
| 3-piece tail pilot | 3 | 4 | cold | 3363.9 [2998.8, 3491.7] | 3398.9 [3284.8, 3634.3] |
| 3-piece tail pilot | 3 | 4 | warm-clean | 1773.8 [1768.7, 1852.7] | 1774.1 [1753.9, 1824.0] |
| 3-piece tail pilot | 3 | 4 | broad | 2106.2 [1869.5, 2313.6] | 1985.3 [1968.7, 2028.7] |
| 3-piece tail repeat | 5 | 2 | cold | 3491.3 [3315.5, 3631.0] | 3311.9 [3269.4, 3611.5] |
| 3-piece tail repeat | 5 | 2 | warm-clean | 1781.9 [1661.3, 1819.2] | 1716.6 [1645.0, 1750.6] |
| 3-piece tail repeat | 5 | 2 | broad | 1920.8 [1898.4, 2046.7] | 1899.1 [1839.9, 1919.3] |
| 3-piece tail repeat | 5 | 4 | cold | 3325.1 [3083.7, 3609.2] | 3425.9 [3332.3, 3599.4] |
| 3-piece tail repeat | 5 | 4 | warm-clean | 1803.5 [1685.8, 1828.4] | 1754.1 [1700.9, 1829.7] |
| 3-piece tail repeat | 5 | 4 | broad | 1971.9 [1889.0, 2066.4] | 1895.4 [1864.4, 1959.5] |
| common queue | 3 | 2 | cold | 3436.5 [3348.9, 3546.5] | 3528.4 [2901.2, 3760.5] |
| common queue | 3 | 2 | warm-clean | 1618.9 [1611.0, 1854.0] | 1757.7 [1744.2, 1769.0] |
| common queue | 3 | 2 | broad | 1900.4 [1855.2, 2053.9] | 1859.5 [1839.3, 2003.0] |
| common queue | 3 | 4 | cold | 3221.7 [3212.8, 3413.1] | 3494.6 [3379.0, 3588.8] |
| common queue | 3 | 4 | warm-clean | 1738.2 [1738.0, 1781.9] | 1778.0 [1771.8, 1789.1] |
| common queue | 3 | 4 | broad | 1986.4 [1951.4, 1989.9] | 2015.5 [1992.0, 2112.2] |

The common queue can lose substantial time even with a skewed phase (jobs=2
warm-clean median 1.619 -> 1.758 s). Preserving prefixes and reducing the number
of pieces is preferable here, but does not turn fixture medians into a guarantee.

## Wall-only finish gaps and phase dispatch

Three repeats, milliseconds, median [min, max]. Finish gap is measured between
**each participating worker's final batch end within a phase**, not across every
sub-batch end. All timestamps share the frontend clock. Native root and dispatch
medians are independent summaries and must not be added together.

### Skewed, `tail2`

| Jobs | Lane | Native wall | Total dispatch | Phase 0 dispatch | Phase 0 finish gap |
| --- | --- | --- | --- | --- | --- |
| 2 | baseline | 2345.1 [2331.8, 2358.5] | 1594.1 [1530.0, 1604.2] | 1038.8 [956.1, 1063.2] | 294.9 [281.8, 361.3] |
| 2 | candidate | 2334.9 [2284.2, 2427.6] | 1544.9 [1530.1, 1628.8] | 936.5 [901.4, 955.3] | 73.9 [34.5, 107.3] |
| 4 | baseline | 2432.0 [2250.9, 2458.4] | 1634.4 [1476.8, 1648.2] | 1037.7 [961.2, 1045.1] | 306.3 [269.0, 336.0] |
| 4 | candidate | 2373.6 [2358.5, 2445.2] | 1592.0 [1518.5, 1609.8] | 938.7 [897.1, 1002.8] | 15.0 [11.1, 57.2] |

Phase 0 is Riverpod. At jobs=2 its finish-gap median falls 294.9 -> 73.9 ms,
and its dispatch median falls 1038.8 -> 936.5 ms. Total dispatch improves less
(1594.1 -> 1544.9 ms); native wall is 2345.1 -> 2334.9 ms in these separate
captures. Later phases and other envelopes offset much of the first-phase
benefit. This is not a claim about the private application's mockito phase.

### Balanced, `tail2`

| Jobs | Lane | Native wall | Total dispatch | Phase 0 dispatch | Phase 0 finish gap |
| --- | --- | --- | --- | --- | --- |
| 2 | baseline | 2043.4 [1995.0, 2063.6] | 1240.0 [1228.8, 1246.3] | 737.2 [718.3, 739.8] | 7.2 [3.1, 22.0] |
| 2 | candidate | 1981.7 [1917.1, 2081.2] | 1249.9 [1181.0, 1338.3] | 750.9 [673.4, 815.4] | 14.7 [14.7, 22.5] |
| 4 | baseline | 2017.6 [1995.4, 2021.5] | 1222.3 [1179.6, 1225.6] | 732.2 [685.0, 745.6] | 51.2 [0.0, 53.8] |
| 4 | candidate | 2096.3 [1988.9, 2138.2] | 1305.6 [1237.7, 1319.0] | 761.2 [722.5, 800.9] | 24.9 [0.6, 48.5] |

There is little tail to remove at jobs=2; splitting does not improve total
dispatch. Jobs=4 dispatch becomes worse in this diagnostic group. Full numeric
phase summaries are in [diagnostics.json](diagnostics.json); raw traces stay local.

## CPU, RSS, IPC and additional analysis

Trace-disabled CPU and max-process RSS medians:

| Workload | Jobs | Case | Fixed CPU / candidate CPU (s) | Fixed / candidate max-process RSS (MiB) |
| --- | --- | --- | --- | --- |
| skewed | 1 | cold | 4.947 / 4.494 | 230.2 / 220.8 |
| skewed | 1 | warm-clean | 2.795 / 2.420 | 165.8 / 169.6 |
| skewed | 1 | broad | 2.984 / 3.170 | 177.5 / 176.5 |
| skewed | 2 | cold | 6.292 / 6.229 | 264.1 / 209.1 |
| skewed | 2 | warm-clean | 3.194 / 3.240 | 150.9 / 154.0 |
| skewed | 2 | broad | 3.545 / 3.673 | 152.5 / 156.8 |
| skewed | 4 | cold | 6.564 / 6.679 | 202.8 / 201.3 |
| skewed | 4 | warm-clean | 3.217 / 3.288 | 150.9 / 153.6 |
| skewed | 4 | broad | 3.608 / 3.801 | 151.7 / 155.7 |
| balanced | 1 | cold | 4.632 / 4.340 | 222.1 / 219.8 |
| balanced | 1 | warm-clean | 2.215 / 2.139 | 164.9 / 164.5 |
| balanced | 1 | broad | 2.544 / 2.630 | 163.6 / 164.9 |
| balanced | 2 | cold | 5.406 / 5.616 | 262.6 / 279.2 |
| balanced | 2 | warm-clean | 2.566 / 2.554 | 148.0 / 168.6 |
| balanced | 2 | broad | 2.769 / 2.804 | 149.7 / 151.6 |
| balanced | 4 | cold | 6.038 / 5.743 | 207.0 / 263.3 |
| balanced | 4 | warm-clean | 2.688 / 2.703 | 148.2 / 150.1 |
| balanced | 4 | broad | 2.988 / 2.986 | 150.2 / 157.6 |

At skewed jobs=2, broad CPU changes 3.545 -> 3.673 s (+3.6%) and max-process RSS
152.5 -> 156.8 MiB (+2.8%). Warm-clean CPU changes 3.194 -> 3.240 s. Cold RSS
varies substantially; a durable memory saving is not established. Linux `wait4`
CPU includes the frontend and waited descendants. `ru_maxrss` is a max-process
high-water mark, **not simultaneous total process-tree RSS**. Diagnostics also
record the sum of per-active-worker sampled peak RSS, which is not a concurrent
peak and excludes idle workers without action samples.

Separate jobs=2 warm-clean metrics+analysis+wall captures (one per lane/condition):

| Workload | Mode | Batches | Request bytes | Result bytes | Cycle loads | Drivers | Byte-store hits/gets | Sampled worker RSS sum (MiB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| skewed | fixed | 8 | 415,656 | 2,700,728 | 1226 | 2 | 1432/1436 (99.72%) | 306.3 |
| skewed | tail2 | 16 | 749,989 | 2,707,349 | 1274 | 2 | 1464/1468 (99.73%) | 303.3 |
| balanced | fixed | 8 | 415,656 | 1,271,224 | 1226 | 2 | 1430/1436 (99.58%) | 299.6 |
| balanced | tail2 | 16 | 749,988 | 1,277,844 | 1250 | 2 | 1453/1460 (99.52%) | 335.5 |
| skewed, 3-piece | fixed | 8 | 415,656 | 2,700,728 | 1226 | 2 | 1433/1436 (99.79%) | 300.4 |
| skewed, 3-piece | tail | 24 | 1,084,323 | 2,708,067 | 1274 | 2 | 1460/1468 (99.46%) | 304.3 |
| skewed, queue | fixed | 8 | 415,656 | 2,700,728 | 1226 | 2 | 1432/1436 (99.72%) | 300.2 |
| skewed, queue | queue | 24 | 1,084,323 | 2,747,891 | 1546 | 2 | 1621/1628 (99.57%) | 370.1 |

The `tail2` variant doubles protocol batches (8 -> 16) rather than tripling them.
Skewed request bytes increase 415,656 -> 749,989 (+80.4%); result bytes increase
only slightly. Repeated blocked lists dominate additional request envelopes.
The new request-byte counters count real framed `build`/`build_batch` messages,
including length prefixes; result bytes use the existing framed-result counter.
They avoid hypothetical JSON-size estimation and include nested build requests
on the unchanged optional path when present.

Skewed cycle loads grow 1226 -> 1274 (+3.9%) while driver creations remain two
and resolver replacements remain zero. The new footprint is moved work needing
another worker's phase-local dependencies, not a new driver per piece. Extra
analysis is **not unchanged work**, which invalidates a simple ideal-balance
wall prediction. Byte-store hit rate remains high in warm-clean; all cold,
one-file and broad counters are retained in diagnostics. The warm jobs=2 content-version records distinguish the extra loads: positive
loads grow 842 -> 858, unavailable loads 384 -> 416, and positive content versions
loaded by multiple workers 357 -> 373. Neither lane reloads a positive content
version within the same worker. This supports extra cross-worker dependency
footprint rather than loss of the resident driver's loaded state. Single diagnostic
captures explain costs but do not establish a timing effect.

## Correctness and repository checks

The large stateful fixture sends 64 inputs through two phases. It compares
stock bytes at jobs=1, verifies per-worker Builder/Resource identity and contiguous
use counters across 2/3-piece batches at jobs=2, checks inter-worker upstream
reads and same-phase output hiding, then checks unchanged no-op and atomic
output/graph preservation after a failure in the last coarse piece. Bulk
incremental delete/rename runs with 64 dirty actions and removes stale outputs.
Watch keeps the same two worker PIDs across initial and broad builds and preserves
the committed graph/output set after a later failure. Stateful jobs>1 validates
lifetime contracts, not stock equality of per-process counters.

Local checks passed: 104 Rust tests (including the final normal-only scope),
161 Dart tests, Dart format/analyze, the CI-specified Rust format check, Python
helper tests, release metadata, `bash scripts/verify.sh`,
`VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh`, and the stateful coarse-batch
lifetime/failure/delete/rename/watch fixture. See [validation.json](validation.json)
and [the lifetime results](lifetime-validation.json).

The local full suite was stopped at the user's request after its core suite
passed; it is not reported as a full-suite pass. Remaining repository integration
coverage is delegated to existing PR CI. The expanded same-phase hiding and
no-op assertions in the coarse lifetime script are added to `integration-arbitrary`
CI and are pending there. No additional local full verification is required for
this opt-in investigation draft.

## Reproduction

Prepare the same SDK/pub cache and compile main/candidate with the pinned Rust
toolchain. Main is `f57b5fa`; Dart worker sources are identical. Use only disposable
fixture/cache/result directories and keep correctness outside timing groups.

```bash
python3 scripts/prepare_cycle_read_fixture.py --root "$fixture" --skewed
(cd "$fixture" && PUB_CACHE="$pub_cache" "$dart" pub get)
BUILD_RUNNER_ACCELERATOR_CACHE="$cache" "$main_native" build \
  --root "$fixture" --dart "$dart" --mode rust --jobs 2
worker="$fixture/.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker"
python3 scripts/benchmark_cold_build.py \
  --baseline "$main_native" --candidate "$candidate_native" \
  --candidate-scheduler tail2 --frontend-dart "$dart" \
  --root "$fixture" --cache "$cache" --results "$prepared_results" \
  --fixture-kind riverpod-cycle --worker "$worker" --jobs 1 2 4 \
  --repeats 3 --stock-check
python3 scripts/benchmark_frontend_regen.py \
  --baseline "$main_native" --candidate "$candidate_native" \
  --candidate-scheduler tail2 --dart "$dart" --root "$fixture" \
  --cache "$cache" --results "$regen_results" --jobs 1 2 4 --repeats 3 \
  --stock-reference "$prepared_results/stock-outputs.json"
# Repeat separately with --wall-trace for wall-only diagnostics.
# Prepared diagnostics additionally use --metrics --trace; compare static/tail2
# on the same candidate binary to expose identical request-byte counters.
# Repeat prepared comparisons with --candidate-scheduler tail or queue.
# Prepare a separate balanced fixture without --skewed, with its own references.
python3 scripts/check_coarse_batch_lifetime.py \
  --root "$new_lifetime_fixture" --native "$candidate_native" \
  --dart "$dart" --cache "$external_check_cache"
python3 scripts/summarize_coarse_batch.py \
  --results "$prepared_results" "$regen_results" "$diagnostic_results" \
  --output "$public_summary"
```

The measurements used an SDK-bin wrapper (recorded hashes) that removes HOME,
with explicit PUB_CACHE, analyzer state override, CARGO_HOME/RUSTUP_HOME and
external accelerator caches. The baseline and final prototype binary hashes,
worker hashes, source identities and commands are retained in the artifacts.
[Output fingerprints](outputs.json) cover all 702 measurement builds; repeated
lanes/cases have matching stock-verified fingerprints. Per-file hashes and raw
logs remain in the local result directories.

## Remaining limits and next candidates

Keep fixed count ranges as the default. `tail2` is a lower-overhead way to test
whether a large real phase's tail is removable; it does not justify increasing
the analysis cap or changing worker lifetimes. Further application measurements
should alternate static/tail2 under matching SDK/cache conditions and include
whole wall, final-worker gap, CPU/RSS, IPC and cycle loads.

A next generic candidate is a more conservative, within-run decision to keep
cheap phases on fixed ranges and redistribute only a sufficiently costly tail.
It would need measurements rather than a builder-name rule. Preserving affinity
across phases may reduce the extra dependency footprint. Reusing blocked hints
would need its own protocol/capability design. No persistent cost cache is
currently justified. Any policy must account for a single slow in-flight prefix,
stateful builders and optional/lazy demand; this experiment changes none of those
boundaries by default.
