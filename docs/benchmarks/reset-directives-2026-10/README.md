# Reset directive extraction and old-content comparison

Started from freshly fetched main `1d536c4a19a8cd6c1d4d0f4c96ae4e3b7692b4c0`
(PR #92). It equals the previously reviewed main, so there is no intervening
optimization to duplicate. Read AGENTS, architecture/lifecycle/transaction and
performance ADRs, ADR 0019 and 0027, protocol v1, and the PR #91/#92 measurement
reports and PR discussions. The application sources and latest-main application
traces are unavailable here; these results concern fixtures only.

## Contract and scope

The compared information is the legacy set of trimmed regex matches for
import/export/part/part-of/library, including conditional clauses. It is not
PR #84's conditional URI set: that omits library/part-of invalidation information
and serves a different read/dependency-recording contract. Its directive-only
parser still tokenizes the whole input and is not a drop-in replacement.

| Transition | Existing reset decision, retained by this change |
| --- | --- |
| First generated asset | Consult pre-build disk content if there is no committed directive record. Nonempty new directives alone do not clear a graph with no prior entry. |
| Body-only change | Equal directive sets keep the graph; different complete content still requires a new extraction. |
| Directive change | Unequal sets clear the graph, including when old/current full contents were checked for equality. |
| Dependency-loaded while missing | Without previous content, nonempty directives clear a permanent empty-deps entry. Phase-expiring entries reload under the existing loader; keep the phased-deps check. |
| Delete/recreate | Delete removes the per-asset previous directive record and produced value. Recreate checks disk or the missing-dependency case again. Pure content reuse cannot supply an old per-asset comparison record. |
| Next watch build/failure recovery | Existing resolver replacement and per-build clears discard per-asset comparison records; the new reuse is local to one reset. |

Do not skip overlay validation/reads, old-file existence/reads, cache eviction,
phase-visible content notification, read recording, optional demand, or atomic
output/graph commit. No queue or deferred work is added. Scheduler, assignment,
worker caps, single-flight, AOT policy and cache compaction are unchanged.

## Final change and adoption boundary

Extract the updated version with the unchanged whole-content regex, coupling
its immutable decoded String with an immutable directive set in a temporary
`ResetDirectiveContent`. When the per-asset old directive record misses, retain
the existing package search, existence check, synchronous disk read and UTF-8
conversion. Compare that **entire old String** with the updated String. Only an
exact equality permits reusing the already extracted set for the old side;
otherwise run the unchanged regex on the old content too.

This is a content-version proof: `oldText == updatedText` implies that the pure
legacy extraction gives exactly the same set. AssetId, mtime, mutable bytes,
object identity and AssetContent's optionally inherited digest cannot authorize
reuse. A reused temporary result binds to the supplied String. The per-asset
committed directive map still holds only sets and is invalidated exactly as
before; the new String/result pairs are not retained across resets/builds.
There is no additional content cache, hash, disk cache or publication contract.
Existing AssetContent conversions are still materialized normally.

The unchanged full-content extractor preserves multiline clauses, conditional
import/export text, library/part/part-of, language-version comments, malformed
and late matches, and legacy comment/string false positives and parser limits.
A body-only or language-comment edit cannot take the equality shortcut even
when its eventual directive set is unchanged. No prefix parser or changed
fallback is introduced. Graph invalidation still compares the same old/new
sets and checks the same missing permanent empty-deps case.

Regen with removed old files cannot benefit from this shortcut. The benefit is
specifically identical available pre-build content, not a general reset or
application regen speedup. The old I/O/decode remains; only its redundant
extraction is removed. There is no deferred work to dispatch or the next build.

## Rejected content-cache experiment

A process-local LRU keyed by complete immutable Strings, bounded to 128 entries
and 1,048,576 key code units, was implemented and tested, then **not adopted**.
It correctly binds content and sets but adds whole-content hash/equality work
and retained text. AOT extraction-only comparisons with fresh decoded Strings
per lane, seven alternating samples, milliseconds median [min,max]:

| Workload | Legacy extraction | Content cache |
| --- | ---: | ---: |
| Equal large outputs, 401 files / 7,794,924 code units | 49.657 [33.797,65.214] | 26.585 [24.362,44.586] |
| Unique large outputs, 401 files / 10,154,220 code units | 51.196 [38.137,68.429] | 63.948 [60.092,96.446] |

The miss-heavy median worsens 24.9%. Whole-build distributions do not establish
stable benefits; the application's hit rate is unknown. Retaining this cache
by default would not be justified. The [unapplied patch](rejected-content-cache.patch)
contains its implementation, tests and microbenchmark. Apply it to main after
[the baseline diagnostic patch](baseline-diagnostic.patch), not to this PR's
final implementation. Cache-experiment speed samples and metadata are separate
from the final comparison. Alternative whole-scan regex/literal-keyword
prefilters were also screened and slower, so none are adopted.

## Diagnostics

WALL_TRACE retains the original cumulative BRA_RESET_TRACE stages. Detailed
`directive_stats` require METRICS **and** WALL_TRACE. They separate updated/old
string conversion, extraction requests versus actual scans, full old/current text equality, old per-asset cache hit/miss, package lookup, existence checks,
reads/bytes, set comparison, phased dependency lookup and graph end/unlock.
Repeated complete-text requests are counted across resets (the raw
field is named `repeated_content_extracts`). For the final candidate subtract
`old_same_content_reuses` from that field to obtain actual repeated scans;
all successful reuses were observed as a duplicate immediately after extracting
the updated version. This diagnostic
counter retains observed Strings until build reset and precomputes their hashes;
its memory/CPU overhead is diagnostic-only, and its whole-content hashing is outside the scan/decode sub-timers and
inside the detailed directive stage. Ordinary wall-only runs exclude it. Use the separate
trace-disabled microbenchmark and build CPU/RSS for miss cost/production retention.
Worker elapsed sums are not frontend wall or CPU. Frontend phase reset and
exclusive dispatch are measured on Rust's clock by the existing wall summarizer.

## Conditions and reproduction

Dart 3.13.3, Rust 1.98.1 release, Linux x86_64, two-CPU quota, 8 GiB memory limit,
overlay filesystem, warm OS page cache. One release frontend is used in both
lanes because only Dart changes. Corresponding AOT workers use the same SDK,
package config and builder implementation, with common diagnostic probes disabled
in speed runs. Baseline preserves main's extraction/old-content algorithm.
The instrumentation-only baseline patch and worker/source hashes are retained.

The six-phase fixture derives from PR #91's mixed cycle fixture: 64
Riverpod/Freezed/JSON inputs, 144 shared conditional/transitive sources, a large
Dart-output probe reading generated and shared content, then post-process.
It produces 384 source/cache artifacts. `--unique` salts every large generated
class with its input filename, producing a miss-heavy control. The default intentionally generates equal bodies for equal input lengths,
a favorable workload for the rejected global cache. The final comparison uses
`--unique`; unchanged old/new content within each asset still permits the final
shortcut without relying on equality between unrelated outputs.

Prepared cold clears graph, outputs, analyzer byte store and dependency parse
cache while retaining SDK summaries and prepared workers. Regen removes all
workspace accelerator state/source outputs and retains shared caches. Explicit
corresponding workers exclude compilation and AOT artifact restore/validation;
manifest regeneration is included. Both lanes additionally prime the actual missing-state regen route outside
measurement, so its factory/kernel first publications are not charged only to
the first timed lane. An earlier regen group lacking that priming is excluded
in full rather than selectively dropping its slowest sample.
`warm-clean` deletes the graph and post-process outputs but retains pre-build
Dart/part outputs and shared caches, isolating available identical old content.
Stock references are untimed for cold,
one-file and broad edits. Every measured source/cache output must match them
byte-for-byte, and edits must change bytes. Speed runs alternate AB/BA/AB and
disable metrics, wall and analysis trace. Diagnostics are separate executions.
CPU is process-tree user+system; RSS is wait4's maximum individual process RSS,
not simultaneous process-tree peak.

Prepare a disposable fixture using `scripts/prepare_cycle_read_fixture.py`,
copy `probe_builder.dart`, and append the probe/post-process configuration shown
in `benchmark.py`. Resolve packages and generate its dynamic worker outside
timing. Compile each lane with explicit `--packages=<fixture config>` and the
same SDK. Put each binary in its own `bin/` under an SDK layout with `lib` and
`version`, plus a discoverable `.dart_tool/package_config.json` whose package
root URIs are absolute and refer to the same fixture/dependencies. Keep workers
outside workspace state so regen cannot remove them. An executable relocated
without that config fails `Isolate.packageConfig`; failed setup runs are excluded.

```bash
python3 docs/benchmarks/reset-directives-2026-10/benchmark.py \
  --baseline "$native" --candidate "$native" --dart "$dart" \
  --baseline-worker "$baseline_worker" --candidate-worker "$candidate_worker" \
  --root "$fixture" --cache "$cache" --results "$speed" --repeats 3
# Repeat with --unique, and separate result paths.
# Then use --wall --stock-reference <matching speed/stock-outputs.json>.
# --prepared-wall adds an available-old-content diagnostic, also with --wall.
# Detailed counters use --wall --metrics; never compare these as speed samples.
dart compile exe --packages=.dart_tool/package_config.json \
  tool/benchmark_reset_directives.dart -o "$micro"
"$micro" "$fixture/lib"
```

SDK/tool/build caches are not universally cold. These prepared native timings
exclude the Dart launcher and automatic worker validation. They do not establish
application regen savings, unprepared cold startup, Windows behavior, or a
particular concurrent peak RSS.

## Final performance results

All times below are median [minimum,maximum]. Three repetitions per lane/jobs,
alternating AB/BA/AB. Raw samples, CPU/RSS and byte-match flags are in
[samples.csv](samples.csv); corresponding prepared workers, inputs and frontend
hashes are in [metadata.json](metadata.json). `version-*` denotes the final
implementation; other names identify the rejected cache experiment. All 72
final speed samples matched all 384 stock source/cache artifacts byte-for-byte.

### Trace-disabled whole build

Seconds; these include setup/manifest work, not just phase reset.

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

Regenerated outputs have no old files, so the shortcut has **zero hits** there.
The lower candidate regen median cannot be attributed to removed extraction;
manifest/kernel/source-helper work and host variation dominate (see the broad
ranges). Cold/no-op/one-file/broad differences also do not establish a stable
whole-build improvement. In particular jobs=4 one-file median rises 71 ms;
its baseline/candidate ranges overlap. Jobs=2 cold maximum-process RSS rises
from 255.7 to 276.0 MiB median, with overlapping ranges. No added persistent
String cache exists, and these process maxima are not concurrent tree peaks.
These observations are limitations, not an application acceleration claim.

| Jobs | Case | Baseline tree CPU s | Candidate tree CPU s | Baseline max-process RSS MiB | Candidate max-process RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| 2 | regen | 35.755 [27.234,43.555] | 32.343 [30.333,33.811] | 613.027 [607.555,614.641] | 633.098 [605.828,649.969] |
| 2 | warm-clean | 7.391 [5.919,9.010] | 6.922 [6.613,8.843] | 177.492 [173.668,187.637] | 173.223 [168.676,189.477] |
| 4 | regen | 37.387 [34.991,37.718] | 33.178 [32.780,35.160] | 610.316 [586.320,632.504] | 607.402 [604.234,614.359] |
| 4 | warm-clean | 7.085 [7.052,10.723] | 7.036 [6.827,7.646] | 172.055 [167.746,178.098] | 168.684 [160.879,169.129] |

### Isolated extraction, no diagnostics

401 files / 10,154,220 code units, fresh immutable decoded Strings per lane;
seven alternating AOT samples. Decode/read/setup and checking against the legacy
oracle are outside timing. These are elapsed times, not whole-build CPU.
[micro.csv](micro.csv) includes every sample, including outliers.

| Old version | Baseline ms | Candidate ms |
| --- | ---: | ---: |
| Missing (one updated scan) | 43.619 [40.302,125.638] | 44.181 [42.335,62.410] |
| Same full content (two scans vs scan plus equality) | 86.442 [78.501,105.496] | 46.861 [38.195,57.018] |
| Changed body (still two scans) | 84.439 [78.732,94.746] | 85.599 [79.966,248.463] |

The targeted same-version operation improves 45.8%; the miss/changed medians
are 1.3%/1.4% slower. Retain the minimal equality shortcut on this evidence;
reject the global content cache because its unique-content miss penalty is much
larger. No scanning work moves to a later request, dispatch or next build.

### Separate wall-only reset/dispatch diagnostics

No detailed counters/hashing in these runs. Milliseconds, three samples per
lane/jobs. Worker values sum elapsed durations over workers; they are neither
frontend wall nor CPU. Cleanup is the final large-Dart/post-process reset.
All graph-clear counts are zero in both lanes.

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

The available-old jobs=4 cleanup removes redundant old scans and lowers its
worker-sum/cleanup-wall medians. Jobs=2 is noisier and does not show a consistent
wall reduction. Dispatch wall has overlapping distributions and some candidate
medians rise (warm-clean jobs=4 2.680→2.960 s); this measurement cannot establish
an end-to-end win. The implementation performs extraction and comparison within
the same reset, introduces no queue, and trace-disabled subsequent no-op and
incremental builds remain byte-correct. There is no algorithmic transfer of
skipped scans to dispatch or the next build, but CPU scheduling noise prevents
claiming unchanged downstream timing from three wall-only samples.

### Detailed counters, separate from speed/wall-only runs

One diagnostic build per lane/jobs/workload; summed over every incremental
reset and worker. Missing fields in [directive-stats.csv](directive-stats.csv)
mean zero. Timers are elapsed worker sums, include scheduling stalls, and the
content-observation set adds hashing/retention outside these sub-timers. They
identify work, not an independent speed comparison.

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

Counts are identical between lanes except for old scanning/reuse:

| Workload | Jobs | Updated Dart/part requests/scans | Updated bytes | Old record hit/miss | Old exists/read | Old bytes | Old scans baseline→candidate | Full-equality reuses | Actual repeated scans baseline→candidate | Dependency lookups | Graph clears |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| regen | 2 | 640/640 | 17,709,876 | 0/640 | 640/0 | 0 | 0→0 | 0 | 0→0 | 384 | 0 |
| regen | 4 | 1280/1280 | 35,419,752 | 0/1280 | 1280/0 | 0 | 0→0 | 0 | 0→0 | 768 | 0 |
| warm-clean | 2 | 640/640 | 17,709,876 | 0/640 | 640/384 | 17,504,844 | 384→0 | 384 | 384→0 | 0 | 0 |
| warm-clean | 4 | 1280/1280 | 35,419,752 | 0/1280 | 1280/768 | 35,009,688 | 768→0 | 768 | 768→0 | 0 | 0 |

These are worker-broadcast totals: 320 updated Dart/part assets per worker,
including 64 large probe outputs (~8.19 MB). The six-phase stock inventory is
384 artifacts, not 640/1280 distinct files. Every asset is updated only once
per worker in this fixture; committed old-set hits are therefore zero here.
The protocol test separately verifies a hit on a later reset for the same
asset, and eviction on delete/recreate and next build.

The dominant saved operation is old whole-content scanning: warm-clean old
scan sums 109/409 ms become zero, replaced by 1.7/6.7 ms of full equality.
Package lookup is much smaller than scanning; old reads and conversion remain.
Regen remains dominated by updated scanning and has no duplicated complete
contents in this unique-output fixture, so a global cache cannot remove its
work. This is why no package index, parser/prefix fast path or default content
cache is adopted. A prefix-only extractor could miss late legacy matches;
changing that behavior is not justified by these measurements.

There is no new production cache or persistent content retention. Existing
per-asset directive sets have the same lifetime/count as main. In detailed
runs only, the observation set holds 640/1280 distinct ASCII Strings across
workers (~17.7/35.4 MB content bytes plus String/set overhead) until the next
build reset; this is intentionally excluded from speed/RSS comparisons.
The shared fixture SDK/analysis/factory cache was ~34 MiB after the final
sequence, an end-state size rather than a per-lane peak; the shortcut adds no
cache files and leaves shared cache key/compaction policies unchanged.

Wall-only regen manifest-selection medians are 18.180→17.319 s (jobs=2)
and 17.826→17.812 s (jobs=4), whereas all frontend reset medians are
0.201→0.191 s and 0.350→0.355 s. This directly separates the large setup cost
from the operation under investigation. The main's application PR #91/#92
figures are background only; none are substituted for these fresh measurements.

## Related validation and CI boundary

Local verification used the same Dart wrapper/SDK and offline resolved packages:

```bash
PUB_CACHE="$repo/.pub-cache" "$dart" test \
  test/reset_directives_test.dart test/reset_directives_worker_test.dart \
  test/phased_dependency_content_test.dart test/resolver_directives_test.dart \
  test/overlay_blob_test.dart test/worker_step_resolver_test.dart \
  test/resolver_reads_test.dart
"$dart" analyze lib/src/worker.dart lib/src/reset_directives.dart \
  test/reset_directives_test.dart test/reset_directives_worker.dart \
  test/reset_directives_worker_test.dart tool/benchmark_reset_directives.dart
"$dart" format --output=none --set-exit-if-changed \
  lib/src/worker.dart lib/src/reset_directives.dart \
  test/reset_directives_test.dart test/reset_directives_worker.dart \
  test/reset_directives_worker_test.dart tool/benchmark_reset_directives.dart \
  docs/benchmarks/reset-directives-2026-10/probe_builder.dart
# Set DART_BIN, PUB_CACHE, CARGO_BIN, RUSTUP_HOME, CARGO_HOME,
# BUILD_RUNNER_ACCELERATOR_BIN to the toolchain described above:
PUB_GET_OFFLINE=1 bash scripts/correctness_riverpod.sh
PUB_GET_OFFLINE=1 bash scripts/watch_smoke_riverpod.sh
```

All 38 related unit/protocol tests pass, targeted analysis reports no issues,
and formatting reports zero changes. The extraction test compares the exact
legacy regex with multiline/conditional clauses, library/part/part-of,
comments/strings, language version, malformed/late directives and 300 seeded
combinations. It verifies immutable results and rejection of a mutated byte
buffer with an inherited unchanged digest. The framed worker test verifies
same/changed bodies and directives, disk/committed comparison, deletion,
recreation and full next-build reset; the existing phased-dependency, overlay
and resolver-read tests cover phase expiration, visibility, conditional reads,
nested optional demand and publication contracts. The permanent missing-entry
branch is unchanged; this new protocol test does not manufacture that graph
state, and is not evidence of new coverage for it.

Riverpod stock/native correctness passes no-op, source edit/invalidation,
generated Dart and cache-output deletion/recovery, and failure rollback with
unchanged graph/output bytes. The intentional malformed-source build fails in
both lanes as expected. Watch fails the source-edit event-count assertion in **both** candidate and
fresh main `1d536c4` under the same SDK/native frontend/default worker policy.
Both have three change notifications (the third is a no-op), three completed
builds including the initial build, and stable worker starts=2. Generated-output
delete/recovery passes; edited generated bytes change and match each other
between main/candidate. Failure log tails are excluded from counts. See
[watch-comparison.json](watch-comparison.json). This is a baseline-reproduced
local watch/event issue, left outside this directive-only change; watch CI
coverage remains necessary.
The sandbox cannot publish the manifest snapshot to its default cache path;
the existing Dart-source fallback succeeds. This also explains why prepared
perf workers isolate startup policy from directive measurements.

The benchmark Python file compiles, both documented experiment patches apply
in sequence to an isolated main worker copy, and final diff whitespace is
checked. No full local `verify.sh`, arbitrary-builder suite or matrix was made
a PR prerequisite, following the explicit task instruction over AGENTS' broad
recommendation. Full Dart 3.11 downgrade/3.13 upgrade package tests, Rust tests
and the repository's baseline/optional/phase/post-process/watch integration
matrix are delegated to PR CI. No merge is performed.
