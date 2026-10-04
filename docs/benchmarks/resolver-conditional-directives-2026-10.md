# Resolver read collection: content-keyed conditional directives

## Scope and investigation

Latest `origin/main` fetched at the start: `b73dfbe052fedbd4af34956a01d25743607e47d1`.
There are no changes from the supplied main baseline, and its source tree is
identical to diagnostic revision `86a14e91ca461767162c1faa8d283c9231bee569`.
PR #83's glob/readability improvements are already present and unchanged.

The supplied anonymous archive contains nine real-application runs, all with
metrics enabled, one sample per condition. In `j1_B`, the initial Riverpod
`app|lib/d0001/f00001.dart` action is 31.047s: Builder 25.201s and
`collectResolverReads` 5.822s. The cycle-graph dependency parser reports
6,415 cache hits / zero misses. The archive has no collector parse/read/hash
breakdown. It does **not** establish that all 5.822s is parsing, and worker
sums must not be interpreted as build wall time. The application source is
unavailable; no application speedup has been measured here.

`collectResolverReads` revalidates observed Dart assets, hashes their bytes,
decodes source, filters import/export candidates, parses an AST on a phase
cache miss, and resolves all conditional import/export URI alternatives.
The existing resolved-dependency cache is worker-local and cleared on build
and source-phase resets. The cycle-graph `AssetDepsCache` persists only
ordinary import/export/part AssetIds; its entries cannot reconstruct the
conditional alternatives. Sharing those entries directly would lose reads;
expanding their format would couple this change to cycle-graph behavior and
cache migration. A separate content-keyed extraction cache is the smaller
change.

## Implementation and invalidation

- Store raw conditional URI strings (including the default alternative) in
  `dep_parse/conditional-v1-<SDK version>/store.bin`, using the existing
  checksummed `IndexedBlobStore` and SHA-256 of the exact source bytes.
  Empty results are cached too. SDK changes select another namespace; an
  extraction-semantics change must bump `conditional-v1`.
- On a miss, sources without the necessary literal `if` keyword skip AST
  parsing. Other candidates use Analyzer's `Parser.parseDirectives` with the
  same scanner/features/language-version handling as `parseString`, avoiding
  declaration/body ASTs. Prefix diagnostics, bad remaining tokens or possible
  late import/export keywords select full-unit parsing for recovery parity.
  The helper is verified against Analyzer 13.3.0 and 14.3.0. Builders continue
  to use the original Analyzer-backed resolver.
- URI extraction is independent of the importing asset and package mapping.
  Relative/file/package URIs are resolved for the current asset/configuration
  after extraction. Resolved in-memory lists are cleared when the immutable
  `PackageConfig` instance changes, and retain the existing phase/build resets.
- Every asset is still read through the active action **before** cache lookup.
  Visibility checks and per-action observed reads remain in the reader.
  Missing/hidden generated candidates are not memoized as absent and remain
  recorded dependencies. Appearance is checked again on the next action;
  rewriting changes the content key. All branches remain conservatively
  tracked; SDK URIs remain excluded from AssetIds.
- Corrupt/unavailable entries are misses; cache write failures use the existing
  best-effort store behavior. `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` disables
  persistent extraction as well as the cycle-graph cache.
- Add opt-in collector read, digest, cache I/O, decode/prefilter, parse/extract
  and URI-resolution timers plus memory/persistent hit/miss/parse counters.
  Stage sums omit traversal/control overhead; they are not wall-time estimates.

No scheduler, worker cap, single-flight default, protocol or existing
`AssetDepsCache` format changes are included.

## Paired timing conditions

Linux x64, Dart 3.13.3, Rust 1.98.1, two-CPU cgroup quota (`200000 100000`),
8 GiB memory limit. The tracked two-input `fixtures/riverpod_app` uses
Riverpod generator 4.0.9, Freezed 4.0.1 and JSON serializable 6.14.1.

The main and candidate AOT workers were compiled separately with the same
SDK, dependency package configuration and generated worker catalog. Main's
worker is built from an exact Git archive of `b73dfbe`. The frontend is the
same release binary for both lanes (there are no Rust changes). All lanes
use the same disposable fixture, package configuration and shared cache
paths under `/workspace/resolver-investigation`. Explicit worker executables
are under the fixture's `aot-sdk/bin`, with `lib`/`version` linked to that SDK.

Each condition has five repeats per lane at jobs=1 and jobs=4, with AB/BA
order alternated between repeats. Metrics and trace are disabled; no
compilation, verification or diagnostic runs overlap timing. The launcher,
worker compilation and AOT artifact validation are excluded. SDK summaries,
SDK/pub dependencies and OS page caches are warm; OS caches are not flushed.
Single-flight is disabled. Jobs=4 retains the existing two-worker resolver
batch cap (also confirmed by diagnostics).

The first experiment removes `byte_store` and all `dep_parse` namespaces
before each lane. The second retains the directive caches populated by the
first experiment and removes only `byte_store` before each lane. Within each
lane: cold removes outputs/graph; warm clean removes outputs/graph with all
shared caches retained; no-op follows warm clean; one-file renames `answer`
to `answerEdited`; broad renames both provider functions with `Broad` suffixes.
These edits change generated bytes. Every build records command lines,
wall time, child CPU/RSS and output SHA-256 values in local JSON artifacts.

All **200** timed builds match both each other and stock build_runner's six
outputs for their input state (including three cache parts). Stock was run
separately for clean/no-op/one-file/broad. Warm-clean matches stock clean.

## Build wall times

Seconds, median [min–max], five samples per cell. Negative change is faster.
No-op is only approximately 9ms; its percentages are dominated by fixed
startup noise.

### Both analyzer and directive caches initially empty

| Jobs | Case | Main | Candidate | Median change |
| ---: | --- | ---: | ---: | ---: |
| 1 | cold | 0.7776 [0.7608–0.9353] | 0.7207 [0.7111–0.9056] | -7.3% |
| 1 | warm-clean | 0.3133 [0.3102–0.3213] | 0.2607 [0.2431–0.3580] | -16.8% |
| 1 | no-op | 0.0092 [0.0084–0.0101] | 0.0088 [0.0083–0.0116] | -3.7% |
| 1 | one-file | 0.3206 [0.3152–0.3777] | 0.2869 [0.2521–0.3372] | -10.5% |
| 1 | broad | 0.3197 [0.3173–0.3799] | 0.2961 [0.2495–0.3641] | -7.4% |
| 4 | cold | 1.2559 [0.8942–2.0673] | 0.8415 [0.8165–1.0100] | -33.0% |
| 4 | warm-clean | 0.4124 [0.3443–0.7010] | 0.3505 [0.2915–0.5751] | -15.0% |
| 4 | no-op | 0.0091 [0.0084–0.0129] | 0.0093 [0.0086–0.0188] | +1.5% |
| 4 | one-file | 0.3187 [0.3114–0.3809] | 0.2958 [0.2504–0.5229] | -7.2% |
| 4 | broad | 0.5060 [0.3990–0.5556] | 0.3801 [0.2992–0.8834] | -24.9% |

### Directive caches retained; analyzer byte store initially empty

| Jobs | Case | Main | Candidate | Median change |
| ---: | --- | ---: | ---: | ---: |
| 1 | cold | 0.6798 [0.6447–0.7616] | 0.6139 [0.5866–0.7701] | -9.7% |
| 1 | warm-clean | 0.3168 [0.3125–0.3372] | 0.2583 [0.2444–0.2719] | -18.5% |
| 1 | no-op | 0.0088 [0.0087–0.0093] | 0.0090 [0.0085–0.0097] | +1.3% |
| 1 | one-file | 0.3203 [0.3124–0.3261] | 0.2555 [0.2508–0.2836] | -20.2% |
| 1 | broad | 0.3217 [0.3215–0.3396] | 0.2534 [0.2503–0.2605] | -21.2% |
| 4 | cold | 0.9921 [0.8272–1.1240] | 0.7499 [0.7032–0.9999] | -24.4% |
| 4 | warm-clean | 0.3729 [0.3562–0.5703] | 0.4682 [0.2921–0.4974] | +25.5% |
| 4 | no-op | 0.0090 [0.0084–0.0093] | 0.0092 [0.0089–0.0105] | +1.8% |
| 4 | one-file | 0.3213 [0.3139–0.3244] | 0.2539 [0.2514–0.2805] | -21.0% |
| 4 | broad | 0.3608 [0.3587–0.5845] | 0.4150 [0.2973–0.4858] | +15.0% |

The first cache-only prototype had a 1.3% jobs=1 cold regression and no
consistent jobs=4 cold benefit. A keyword-only prefilter reduced parsed files
(235 to 159) but did not establish a cold wall-time improvement. The final
candidate also limits miss parsing to directives, keeping full-unit recovery
for malformed/late directives. These final measurements compare against the
same unmodified main worker, with newly alternated samples.

With jobs=1, completely empty-cache clean improves from 0.7776s to 0.7207s
(7.3%); directive-warm/analyzer-cold improves from 0.6798s to 0.6139s (9.7%).
All-warm clean and incremental medians improve by 7.4–21.2% across the two
experiments. No-op remains approximately 9ms.

Jobs=4 is noisy under the two-CPU quota. Both cold medians are faster, but
in the directive-warm experiment warm clean is 0.3729s to 0.4682s (25.5%
slower), and broad is 0.3608s to 0.4150s (15.0% slower). Ranges overlap.
These results do not establish a uniformly faster jobs=4 build. Cache
publication still adds work; the miss parser reduction offsets that cost
in this fixture's jobs=1 cold samples, not necessarily in every application.

## Separate diagnostics

Three AB/BA repeats per lane/jobs/condition use metrics, with trace disabled.
The diagnostic main worker adds only collector stage instrumentation to the
archived main source; it is separate from the unmodified main timing worker.
The following are medians of **whole-build sums across worker actions**,
not build wall times. Times in milliseconds; the ordinary parser and the
collector parser have independent counters.

| Initial cache state | Jobs | Lane | Collection total | Read | Digest | Cache I/O | Decode/filter | Parse/extract | URI resolution | Parses | Persistent hits / misses |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Empty | 1 | baseline | 119.436 | 17.577 | 29.808 | 0.000 | 7.427 | 63.251 | 0.029 | 235 | 0 / 0 |
| Empty | 1 | candidate | 78.865 | 21.992 | 28.204 | 5.529 | 7.717 | 12.895 | 0.126 | 159 | 4 / 289 |
| Empty | 4 | baseline | 344.549 | 42.828 | 107.948 | 0.000 | 34.769 | 170.588 | 0.051 | 455 | 0 / 0 |
| Empty | 4 | candidate | 314.178 | 74.491 | 150.798 | 14.116 | 25.008 | 39.119 | 0.536 | 235 | 162 / 404 |
| All warm | 1 | baseline | 111.571 | 17.387 | 28.209 | 0.000 | 6.959 | 57.555 | 0.052 | 235 | 0 / 0 |
| All warm | 1 | candidate | 45.830 | 15.379 | 28.118 | 1.269 | 0.000 | 0.000 | 0.094 | 0 | 293 / 0 |
| All warm | 4 | baseline | 231.874 | 36.394 | 63.517 | 0.000 | 15.010 | 117.535 | 0.068 | 455 | 0 / 0 |
| All warm | 4 | candidate | 200.753 | 64.100 | 128.210 | 4.360 | 0.000 | 0.000 | 0.365 | 0 | 566 / 0 |
| Directive warm | 1 | baseline | 127.051 | 21.196 | 32.708 | 0.000 | 8.489 | 65.614 | 0.027 | 235 | 0 / 0 |
| Directive warm | 1 | candidate | 70.704 | 32.991 | 35.088 | 1.663 | 0.000 | 0.000 | 0.165 | 0 | 293 / 0 |
| Directive warm | 4 | baseline | 395.350 | 74.478 | 121.661 | 0.000 | 21.837 | 202.846 | 0.071 | 455 | 0 / 0 |
| Directive warm | 4 | candidate | 144.977 | 61.671 | 82.839 | 3.619 | 0.000 | 0.000 | 0.253 | 0 | 566 / 0 |

For all-warm jobs=1, the collector avoids 235 parse calls / approximately
58ms of measured parse time. Candidate still spends approximately 15ms
reading and 28ms hashing, plus cache/control overhead. Directive-warm cold
also has zero collector parses/misses. This supports reuse of extraction;
it does not estimate how much of the application's approximately 6s will be
saved. On empty caches, jobs=1 parse/extract drops from approximately 63ms
to 13ms, while cache lookup/publication costs approximately 5.5ms. Scanning,
read checks, hashing and publication remain; it is not a parse-free cold path.
The parse counter counts source extraction invocations, including the
rare full-unit recovery fallback, rather than individual internal parser calls.

## Reproduction

Prepare a disposable copy of `fixtures/riverpod_app`, point its accelerator
path dependency to this checkout, and resolve with the selected SDK/cache.
Generate a normal native build's worker/catalog and warm its SDK summary.
Compile that same entrypoint twice with `dart compile exe --packages=...`:
once with `build_runner_accelerator` pointing to a main Git archive, once to
the candidate. Keep both executables in the fixture's SDK layout described
above. Then run (paths are the actual experiment paths):

```bash
repo=/workspace/build_runner_accelerator
study=/workspace/resolver-investigation
fixture=$study/fixtures/riverpod
workers=$fixture/.dart_tool/build_runner_accelerator/aot-sdk/bin
env -u HOME PUB_CACHE="$repo/.pub-cache" \
  DART_SDK="$repo/.toolchains/dart/dart-sdk" \
  python3 "$repo/scripts/benchmark_cold_build.py" \
  --fixture-kind riverpod \
  --baseline "$repo/rust/target/release/build_runner_accelerator" \
  --candidate "$repo/rust/target/release/build_runner_accelerator" \
  --frontend-dart "$repo/.toolchains/dart/dart-sdk/bin/dart" \
  --root "$fixture" --cache "$study/cache" \
  --worker "$workers/baseline-worker" \
  --candidate-worker "$workers/candidate-directives-worker" \
  --jobs 1 4 --repeats 5 --results "$study/directive-timings"
# Repeat the command with --retain-dep-parse and another results directory.
# Diagnostics use --metrics --repeats 3 and the instrumented main worker;
# keep those runs separate from timings.
```

Local raw artifacts: `/workspace/resolver-investigation/{directive-timings,dep-warm-directive-timings,directive-diagnostics,dep-warm-directive-diagnostics}`.
The anonymous application logs are not added to the repository.

## Verification and limits

Completed: scoped Dart analysis/formatting, 98 locked Rust tests, locked
debug/release builds, Rust formatting and eight Python workflow/benchmark
checks. The final nine collector/directive-parity tests pass with persistent
reuse enabled and disabled, and with Analyzer 13.3.0 and 14.3.0.
All 146 CI-style Dart source tests also pass. Final full
correctness/watch/arbitrary suites are running; their final status is
recorded before publication.

This is a small fixture and prepared-worker measurement, not an application,
launcher-inclusive, AOT-compilation or machine-cold speedup claim. The cache
is append-only, shares the existing store's recovery/publication behavior,
and has no compaction. First-use candidates still scan directives and publish results.
Per-action visibility/read checks and full-content hashing remain intentional
costs. Conditional alternatives remain conservatively tracked rather than
selecting one platform branch.
