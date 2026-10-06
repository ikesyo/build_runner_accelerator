# Per-reset overlay blob measurements

One blob replaces per-asset spool files. It reduces file creation and metadata
work; it still writes each asset separately and workers still read indexed
ranges. The mechanism is supported by synthetic I/O and reset traces. A
reported application regen improvement warrants review; the smaller local
fixture alone did not establish a meaningful whole-build improvement.

## Application report supplied by the maintainer

Baseline `633ba2b` contains PR #91 (the differences from merged `bc6bd61` are
documentation/benchmark files); candidate `f7de876` is the rebased blob
experiment. Release Rust and distinct cached AOT workers were used per lane.
The application is unavailable in the local verification environment; these
are supplied results, not independently rerun application measurements.

Trace-disabled regen, alternating lanes, five samples per lane:

| Lane | Median seconds | Min–max seconds |
| --- | ---: | ---: |
| Baseline | 21.2 | 20.5–22.0 |
| Blob | 20.6 | 19.2–21.6 |

The median reduction is 0.6 s (2.8%). All five paired differences favored
blob: −1.4, −1.4, −0.3, −0.6, −0.1 s. This supports an application-specific
improvement, not a general statistical-significance claim. Cold ABBA had two
samples per lane (87.7/82.9 s versus 83.3/83.2 s), insufficient to establish
an improvement.

Separate WALL_TRACE results show total spool about 400–750 ms becoming about
10 ms, and phase-reset wall 1367–1586 ms becoming 800–926 ms. Large update
sets included 649 files / 1.7 MB, 651 / 1.8 MB and 145 / 5.9 MB.

| Phase | Baseline reset / spool ms | Blob reset / spool ms |
| --- | ---: | ---: |
| freezed | 362–603 / 214–432 | 163–218 / 3–4 |
| json | 98–130 / 24–35 | 91–123 / 0–4 |
| combining | 91–120 / 11–13 | 99–110 / 0–1 |
| mockito | 339–479 / 191–242 | 140–171 / 2–7 |
| part cleanup | 287–397 / 14–80 | 290–307 / 2 |

Worker-reset union and directive/Analyzer time did not absorb the spool
savings. Drivers remained resident (`graph_cleared=false`). The report says
827/827 outputs matched byte-for-byte, with one pre-existing missing output, and no
blob files remained after builds. The cleanup phase remains dominated by
worker work. Trace whole-build times overlap and are not speed-run samples.

Measurement metadata subsequently supplied by the maintainer: Dart 3.13.4
stable linux_x64, rustc 1.94.1 with `cargo build --release`, kernel 6.18.44,
four logical CPUs, default jobs=4 confirmed by four reset participants.
Workspace, build outputs and machine-wide caches all reside on ext4 mounted
`rw,relatime,discard`. Full commits are
`633ba2b31247bbc4ca5129349b06dcb76a15cbfd` and
`f7de876eff226f9bbc386c8b7aaca016e50037f6`.

The seven adopted traces are baseline wall1–3 plus preliminary `dbg2_bra91`,
and blob wall2–3 plus preliminary `dbg2_braBlob`. Preliminary runs used the
same setup. Each lane used a separate cached AOT worker built from its
corresponding sources. Workers used by wall1–3 were rebuilt after the last
cold run. The two earlier dbg2 runs used the same sources, but executable
identity with the later workers was not checked. Workers are not treated as
byte-identical across lanes because transport sources differ.

The report's original three-per-lane method and stated 20 measured builds
do not include the adopted preliminary traces consistently; the explicit
seven-run selection above supersedes that count. Lane selection swapped both
package configuration and lockfile; a lockfile comment separated AOT cache
keys because rootUri alone was insufficient. An AOT_PATH route causing source
fallback and blob wall1 (61 s, recompiling AOT after cold) were excluded for
setup reasons. Cold measurements delete/rebuild AOT. This container differed
from earlier application measurements, so absolute times across reports are
not comparable. Application raw traces were not available locally.

## Controlled local mixed fixture

Baseline PR #91 head `46ff144`; blob candidate `07ab22d` (same experimental
transport subsequently rebased as `f7de876`). PR preparation additionally
requires the new capability/explicit reset field; the numbers below predate
that compatibility guard, and are not attributed to newly measured PR bytes.
Linux x86_64, kernel 6.18.44, 2 CPU quota, 8 GiB limit, Dart 3.13.3, Rust
1.98.1 release, `/workspace` overlay filesystem, warm OS page cache. Same
SDK, dependencies, cache paths and worker implementation apart from transport.
Each lane used its own AOT worker built from the corresponding sources,
kept unchanged within that lane's measurements. Workers differ in source and
bytes; they are not treated as identical.

The six-phase fixture has 64 Riverpod/Freezed/JSON inputs, 144 shared
conditional/transitive sources, generated outputs, a resolver-free probe and
post-process. Every measured build matched 384 stock build_runner outputs by
SHA-256. Five barriers transport 320 values / 665050 bytes per regen.
Cold removes graph/outputs and analyzer caches but retains prepared AOT,
manifest and SDK summaries; regen removes workspace state and generated
source outputs while retaining shared caches. No-op follows a successful
build; one-file and broad edits change provider names and output bytes.
Lane setup and priming are untimed. Runs alternate AB, BA, AB, with metrics,
WALL_TRACE and analysis trace disabled. Each cell has n=3; milliseconds are
median [min, max].

| Jobs | Case | Baseline | Blob |
| --- | --- | ---: | ---: |
| 2 | cold | 2829.3 [2664.3, 2869.3] | 2858.7 [2702.1, 2949.7] |
| 2 | no-op | 39.1 [38.9, 47.4] | 39.5 [38.5, 40.5] |
| 2 | one-file | 431.1 [390.5, 481.9] | 428.8 [387.3, 432.6] |
| 2 | broad | 1577.6 [1576.4, 1633.6] | 1599.1 [1475.5, 1657.1] |
| 2 | regen | 1855.1 [1790.6, 1998.4] | 1850.5 [1828.3, 1952.9] |
| 4 | cold | 2966.1 [2813.2, 3058.2] | 2463.9 [2391.1, 2700.1] |
| 4 | no-op | 40.5 [38.1, 43.1] | 40.0 [38.6, 43.4] |
| 4 | one-file | 425.5 [416.4, 432.2] | 430.8 [429.5, 450.5] |
| 4 | broad | 1631.4 [1591.1, 1693.7] | 1579.4 [1560.1, 1694.5] |
| 4 | regen | 1845.1 [1835.4, 1925.9] | 1818.7 [1786.0, 1992.9] |

Regen median reductions are 0.25%/1.43%, inside observed variability. The
jobs=4 cold difference is unexplained and not used as evidence for reset.

Separate WALL_TRACE, n=3 per lane/jobs, median [min, max] in milliseconds:

| Jobs | Boundary | Baseline | Blob |
|---|---|---:|---:|
| 2 | native whole build | 1810.5 [1768.2, 1855.1] | 1812.4 [1790.3, 1813.5] |
| 2 | exclusive phase reset | 54.6 [53.7, 57.4] | 31.9 [26.1, 34.7] |
| 2 | spool sum | 26.0 [25.5, 29.1] | 1.9 [1.9, 1.9] |
| 2 | frontend worker-reset union | 27.2 [26.8, 28.3] | 28.7 [22.8, 31.6] |
| 2 | exclusive dispatch | 1138.2 [1134.6, 1171.6] | 1142.6 [1134.3, 1148.2] |
| 4 | native whole build | 1930.6 [1914.8, 1931.8] | 1889.3 [1797.3, 1978.8] |
| 4 | exclusive phase reset | 85.2 [84.8, 89.5] | 49.1 [47.4, 65.1] |
| 4 | spool sum | 26.3 [26.0, 30.1] | 1.8 [1.8, 1.8] |
| 4 | frontend worker-reset union | 57.8 [57.7, 58.3] | 46.2 [44.1, 60.6] |
| 4 | exclusive dispatch | 1197.9 [1153.9, 1217.7] | 1209.0 [1118.1, 1217.4] |

Combined metrics were separate runs, one per lane/jobs. Reset RPC counts
remain 10/20 for jobs=2/4, logical write bytes 665050 and worker read bytes
1330100/2660200. Index JSON increases sent IPC bytes by 49082/98164.
Transport staging moves into `cache_invalidation`; compare the sum of it and
`overlay_read`, not `overlay_read` alone. Combined worker-stage medians fell
665→253.5 µs (jobs=2) and 729.5→252.5 µs (jobs=4). These are worker durations,
not frontend wall. No dispatch or next no-op penalty was established.
Regen process-tree CPU medians were 3.040→3.023 s and 2.974→3.007 s; maximum
individual-process RSS was 149.8→152.3 MiB and 156.2→162.8 MiB, not concurrent
process-tree peak RSS. Independent interval medians must not be summed.

## Synthetic I/O mechanism

Actual Rust blob writer versus per-asset files, fresh disposable roots, warm
page cache, seven alternating samples per lane, overlay and `/tmp` tmpfs,
four sequential readers in this table. Reader primitives are Rust, not Dart
workers, so these are transport microbenchmarks, not application speedups.
Values are allocated outside timing. Blob RAII deletion is timed; baseline
cleanup is outside timing. No fsync is issued. Total median milliseconds:

| Values × bytes | Overlay files→blob | tmpfs files→blob |
| --- | ---: | ---: |
| 4096 × 64 | 200.863→13.230 | 43.866→10.915 |
| 650 × 2700 | 16.059→3.268 | 7.654→2.894 |
| 145 × 41000 | 14.228→5.562 | 5.011→4.374 |
| 8 × 1048576 | 5.116→4.840 | 6.220→6.601 |

Separate strace of 650 × 2700 and four readers: openat/close 3260→15 each,
statx 3252→7, read 5213→2613, lseek 0→2600, write 651→651, mkdir 655→6,
fsync/fdatasync 0→0. Logical write/read bytes stay 1755000/7020000.
Thousands of small files therefore offer greater potential; a few large files
can be neutral or slightly worse. Filesystem and build-time share determine
the whole-build benefit.

## Validation and retained artifacts

The experiment passed 104 Rust and 42 Dart tests, targeted analysis/format,
real-worker source/cache update→delete→recreate, empty reset, next build,
malformed/truncated transport and failure recovery. Representative stock-byte
checks covered multi-phase/shared-dependency output, optional outputs/failure
atomicity, post-process incremental/delete/rename and four-worker watch.
PR preparation adds old-worker/message rejection tests (105 Rust, 43 Dart).

Full raw samples and local harnesses remain outside Git in
`/tmp/phase-reset-blob-results/` and `/workspace/phase-reset-io/`; these paths
are environment storage, not downloadable artifacts. Main tables and
conditions are reproduced here so the result does not depend on those paths.
The application report is maintainer-supplied and not committed verbatim.
No full-suite or non-Linux validation is claimed; run repository merge gates
before merging. There is no scheduler/batch/cap/single-flight/AOT/cache-policy
change, overlapping reset, generation-owner omission or builder-name special
case in this PR.

### PR preparation checks

Both required quick invocations passed on the prepared PR sources:

```sh
bash scripts/verify.sh
VERIFY_ARBITRARY_BUILDER=1 bash scripts/verify.sh
```

These include `dart analyze lib bin test tool`, Dart format checking, Rust
unit tests, stock/native byte equality and no-op, manifest snapshot lifecycle,
early-catalog/AOT/fallback checks, trigger incremental/rename/delete/failure
and arbitrary-builder cases (including output conflicts). Related Dart tests
passed 43/43; Rust tests passed 105/105; release compilation, new Rust blob
module rustfmt checking and `git diff --check` passed. Unrelated baseline Rust
formatting was preserved instead of committing whole-file reformatting.

The initial quick invocation with the SDK wrapper failed the existing
manifest snapshot expectation because its executable path cannot identify the
SDK kernel slot. Re-running with the same SDK's real `bin/dart`, `env -u HOME`
(to avoid the environment's read-only home), the same caches and toolchain
passed both quick variants. This is a verification setup correction, not a
transport failure or speed sample. Preparation logs are retained locally in
`/tmp/phase-reset-blob-pr/`. No full merge gate or other OS run is claimed.
