# Shared byte-store index benchmarks

Date: 2026-10-04. Supports [ADR 0026](../../adr/0026-byte-store-publication-index.md).

## Measurements

Linux x64, Dart 3.13.3, Rust 1.98.1 release frontend, two-CPU cgroup quota,
`--jobs 4`. Both workers compile against the same fixture package configuration
and dependency lock. Every paired build uses the same absolute fixture directory
and actual cache root `/workspace/byte-store-results/build-cache`, on the
workspace overlay filesystem, never `/tmp`. Each row is a median of five
alternating runs; no correctness/verification jobs ran during measurement.
The OS page cache is not flushed; copying cache templates can warm it.

The benchmark invokes the release frontend directly with an explicit compiled
worker (`BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH`). AOT compilation, AOT artifact
validation, launcher startup and release download are excluded. The SDK summary
is warm. Empty clean removes both analyzer and directive caches; warm cases
restore independently primed equivalent caches for each format. Clean removes
outputs and graph; no-op follows clean. One-file renames a model field from
`value` to `valueEdited`; broad renames it to `valueBroad` in all inputs,
including the previously edited file, so every input and its output change.
Both timed lanes use parallel analysis (single-flight disabled); metrics are
disabled.

### Isolated AOT probes

Small: 2,000 entries × 4 KiB (8 MiB). Large: 32,000 entries × 16 KiB (500 MiB).
Writes add 2,000 new entries to an independently restored pack. Probe files
live beside the build cache under `/workspace/byte-store-results`, on the same
workspace filesystem; the build measurements use the production cache paths.
CPU uses Linux
CLOCK_PROCESS_CPUTIME_ID, including Dart mutator/GC threads. Peak RSS is for the
whole isolated process, including untimed index preparation for get/write.

| Cache / operation | Before wall / CPU ms | After wall / CPU ms | Before / after peak RSS MiB |
| --- | ---: | ---: | ---: |
| Small index startup, including validation | 16.30 / 16.48 | 1.23 / 1.41 | 13.8 / 9.4 |
| Small bulk file read / allocation | 3.12 / 3.26 | 0.05 / 0.18 | 13.1 / 9.4 |
| Small UTF-8 / offset map only | 0.56 / 0.70 | 0.54 / 0.70 | 13.7 / 9.4 |
| Small raw value reads | 9.61 / 10.16 | 9.12 / 9.46 | 9.4 / 9.4 |
| Small value checksum workload | 5.28 / 5.48 | 5.44 / 5.57 | 9.4 / 9.4 |
| Small validated gets | 15.56 / 15.89 | 20.13 / 20.29 | 18.5 / 15.1 |
| Small writes | 29.41 / 29.92 | 41.19 / 41.59 | 22.5 / 14.7 |
| Large index startup, including validation | 723.55 / 724.51 | 19.38 / 20.74 | 514.4 / 17.9 |
| Large bulk file read / allocation | 177.10 / 178.52 | 0.62 / 0.79 | 506.2 / 9.6 |
| Large UTF-8 / offset map only | 12.72 / 13.33 | 9.31 / 9.91 | 512.7 / 13.1 |
| Large raw value reads | 167.25 / 169.63 | 157.26 / 158.47 | 9.4 / 9.4 |
| Large value checksum workload | 338.03 / 338.29 | 344.62 / 344.47 | 9.4 / 9.4 |
| Large validated gets | 562.25 / 567.03 | 563.10 / 567.16 | 547.0 / 34.9 |
| Large writes | 75.43 / 77.12 | 98.96 / 97.39 | 544.1 / 44.8 |

Raw read/checksum probes isolate component workloads and must not be summed
as an exact decomposition: bulk startup I/O, individual gets and synthetic
checksum loops have different allocation/syscall patterns. The extra key/header
checks slow small-value gets; large-value gets are
approximately unchanged after reducing temporary views to one record read and
one header view. Journal publication adds write/lock-refresh operations. This
change targets startup and memory with unused history; it does not claim faster
hot reads or writes. Metadata-only map construction is inexpensive relative to
historical payload allocation and checksum work. The candidate still validates
metadata CRCs during startup, and requested values during gets.

### Actual JSON builds

The normal ten-input analyzer pack is 102,608 bytes; the 500-input pack is about
880 KiB (901,263 bytes baseline). The accumulated case adds 32,000
valid unused linked entries, totaling 500 MiB of historical values, in that
fixture's actual analyzer pack, not a separate unused fingerprint. This is
synthetic history around real builders, not the unavailable reference workspace.
The candidate's large journal is 1.1–1.2 MB.

| Inputs / cache | Case | Before s | After s |
| --- | --- | ---: | ---: |
| 10 / empty | clean | 0.1412 | 0.1430 |
| 10 / normal warm | clean | 0.1260 | 0.1355 |
| 10 / normal warm | no-op | 0.0036 | 0.0037 |
| 10 / normal warm | one-file | 0.0845 | 0.0863 |
| 10 / normal warm | broad | 0.1363 | 0.1405 |
| 10 / accumulated | clean | 0.8046 | 0.1486 |
| 10 / accumulated | no-op | 0.0036 | 0.0036 |
| 10 / accumulated | one-file | 0.7194 | 0.1032 |
| 10 / accumulated | broad | 0.8177 | 0.1578 |
| 500 / empty | clean | 1.1041 | 1.0784 |
| 500 / normal warm | clean | 0.9623 | 0.9193 |
| 500 / normal warm | no-op | 0.0419 | 0.0410 |
| 500 / normal warm | one-file | 0.1462 | 0.1448 |
| 500 / normal warm | broad | 1.1669 | 1.1991 |
| 500 / accumulated | clean | 1.6401 | 1.0329 |
| 500 / accumulated | no-op | 0.0414 | 0.0419 |
| 500 / accumulated | one-file | 0.7838 | 0.1672 |
| 500 / accumulated | broad | 1.8501 | 1.2113 |

Normal-cache differences have overlapping samples: ten-input broad ranges are
0.128–0.144s before and 0.127–0.147s after; 500-input warm clean ranges are
0.869–1.012s before and 0.907–0.971s after. There is no demonstrated general
speedup on small caches. No-op starts no workers and does not read the store.

Accumulated ten-input clean/broad child CPU falls from 1.50/1.54s to
0.25/0.27s, and peak process RSS from 544/547 MiB to 48/50 MiB. Accumulated
500-input clean/broad CPU falls from 3.00/3.36s to 1.84/2.15s; peak
process RSS falls from 585/587 MiB to 91/91 MiB. Linux wait4 reports
CPU including reaped worker children; max RSS is the largest process, not the
sum of simultaneous workers. CPU figures are medians of each run's user+system
time. The approximately 91-second reference workspace is unavailable, so no
speedup is asserted for it.

Separate metrics-enabled 500-input warm-clean profiles confirm the boundary:
aggregate byte-store get time is 16.5→14.9ms for normal caches and
1,309→58.3ms with accumulated history. Put time is 0.70→1.30ms and
0.87→6.69ms respectively. Driver creation stays about 37–40ms per first
resolver; these probes observed two first-resolver workers with `--jobs 4`.
These diagnostic runs are excluded from the timing table; metrics get time
includes lazy initial index construction, so isolated probes above separate
that cost. Full component counters are in
[build-profiles.json](build-profiles.json).

All 180 measured builds match their case's generated source and native cache
output bytes across formats (SHA-256 comparisons). Separately, both fixtures'
clean/no-op/one-file/broad source outputs match stock build_runner. With the
shared cache root blocked by a regular file, both candidate builds succeed and
produce those same clean outputs.

## Supplied large Flutter application results

These results come from the supplied `build_runner_accelerator-pr82-report.md`,
not a rerun in the fixture environment above. The application has 26,103 actions
and 827 generated files. The host has 4 vCPUs, ext4 and Dart 3.13.4. It compares
main `5dc2e1b` with PR #82 head `e16f7fa`, using the same native binary because
Rust is unchanged. Worker AOT is enabled and metrics are disabled. The report
does not specify whether cold timings include AOT compilation or the configured
worker count. The 4 vCPU host count is not a worker-count measurement.

### Cold and fresh-cache regeneration

ABBA × 2 gives four cold samples per version; each repetition also includes two
regeneration builds with a fresh history. Times are wall seconds.

| Case | Main samples / range | Publication-index samples / range | Main / index median |
| --- | --- | --- | --- |
| Cold | 77.9, 75.0, 75.1, 75.5 | 76.2, 73.8, 76.9, 75.7 | 75.3 / 76.0 |
| Fresh-cache regen | 22.2–23.9 | 22.7–24.0 | 23.4 / 23.1 |

These samples do not demonstrate a cold or fresh-cache speedup or regression.
They agree with the fixture result that small unused history gives little room
for improvement.

### History accumulated through real builds

A public declaration was added to a widely imported shared library, built, then
reverted. Repeating this five times leaves unused linked summaries from actual
builds. Both formats grow from about 92 MB to 168 MB; about 76 MB (45%) is unused
by the restored source. The publication index is 1.2 MB. Regeneration then uses
the original source with this history intact.

| Measurement | Main | Publication index |
| --- | --- | --- |
| Alternating regen samples, wall s | 23.0, 23.5, 23.6 | 22.7, 22.2, 22.2 |
| Regen median, wall s | 23.5 | 22.2 |
| Reported CPU time, s | 45.4–46.9 | 44.1–45.2 |
| Reference switching regens, wall s | 23.8, 23.0 | 22.7, 22.3 |
| Builds accumulating history, wall s | 27.2, 27.6, 28.0, 28.4, 29.0 | 27.8, 27.3, 27.9, 26.1, 26.7 |

The three measured regen samples show about a 5% improvement with separated
ranges. The two switching regens are reference runs, not additional samples in
the reported medians. The increasing main times while accumulating history are
consistent with historical payload scanning; these few observations do not
establish a linear speedup model or predict gains for larger caches.

The supplied report states that all 827 generated files match the reference in
every run. Its `missing=1` refers to a pre-existing stale file without a generator.
The report also records 29 passing tests in the indexed store, packed store and
fingerprint test files.
Memory measurements and the full commands/cache paths are not included in the
supplied report. These observations apply to this application and cache history;
they do not identify it as the previously mentioned ~91-second workspace.

## Reproduction and artifacts

Use `tool/benchmark_blob_store.dart` as an isolated Linux AOT probe: compile it
against the baseline/candidate store source, then run `seed`, `index`, `read`,
`checksum`, `get`, `write` in fresh processes with the real cache path, record
count and value size. `load` isolates bulk file read/allocation; `index-only`
preloads bytes and isolates UTF-8 decoding/map construction without checksums.

Prepare baseline and candidate workers against the same absolute fixture
package configuration. The measured baseline and toolchain identities are
recorded in [metadata.json](metadata.json).
Keep SDK `lib`/`version` beside the
benchmark worker `bin` as in the production AOT SDK facade. Run:

```sh
BENCH_DIR=/path/to/benchmark-artifacts
python3 scripts/benchmark_shared_byte_store.py \
  --baseline-worker "$BENCH_DIR/baseline-worker" \
  --candidate-worker "$BENCH_DIR/candidate-worker" \
  --baseline-probe "$BENCH_DIR/baseline-probe" \
  --candidate-probe "$BENCH_DIR/candidate-probe" \
  --cache "$BENCH_DIR/build-cache" \
  --results "$BENCH_DIR/comparison" \
  --dart "$PWD/.toolchains/dart/dart-sdk/bin/dart" \
  --frontend "$PWD/rust/target/release/build_runner_accelerator" \
  --jobs 4 --repeats 5 --counts 10 500
```

The supplied cache is disposable: the script clears it and restores its own
format-specific templates. Retained per-run timing/resource rows are in
[builds.csv](builds.csv) and
[micro.csv](micro.csv). Build rows also retain
a digest of the sorted output-file SHA-256 manifest for each case. The checked-in
harness and probes make the comparison repeatable.

## Verification and measurement limits

Verification commands and results are recorded in [validation.json](validation.json).
An independent Python zlib CRC32/layout check validates all 66,086 metadata
records in the cache templates, preventing a matching reader/writer checksum bug
from escaping tests.

The metadata index and retained values still grow with unique historical keys;
these measurements do not demonstrate disk reclamation or index memory bounded
by active keys. Small-value workloads can pay the validated-get cost shown above,
and writes pay for the second publication file. Networked filesystems and
cross-platform durability behavior were not benchmarked here.
