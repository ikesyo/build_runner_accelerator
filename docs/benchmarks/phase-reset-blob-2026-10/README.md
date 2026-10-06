# Per-reset overlay blob measurements

Replacing per-asset spool files with one blob per reset substantially reduces
spool time. A maintainer-reported application comparison improved regen by
2.8%; the smaller local fixture did not establish a meaningful whole-build
improvement. Synthetic I/O supports greater benefit for many small files.
The [transport contract](../../adr/0027-reset-overlay-blob-transport.md)
describes publication, validation and lifetime.

## Application comparison

Maintainer-supplied results; the application and raw traces were unavailable
locally. Baseline `633ba2b` contains PR #91; candidate `f7de876` is the blob
experiment. Dart 3.13.4 linux_x64, Rust 1.94.1 release, jobs=4 on four logical
CPUs, kernel 6.18.44, ext4 (`rw,relatime,discard`) for workspace and caches.
Each lane used a cached AOT worker built from its corresponding sources.

Trace-disabled regen, alternating lanes, five samples per lane:

| Lane | Median seconds | Min–max seconds |
| --- | ---: | ---: |
| Baseline | 21.2 | 20.5–22.0 |
| Blob | 20.6 | 19.2–21.6 |

The median reduction is 0.6 s (2.8%), with all five paired runs favoring blob.
Cold ABBA, two samples per lane, was 87.7/82.9 s versus 83.3/83.2 s; this
is insufficient to establish a cold improvement. Cold runs rebuild AOT.

Separate WALL_TRACE runs (baseline n=4, blob n=3) reduced total spool from
about 400–750 ms to about 10 ms and phase-reset wall from 1367–1586 ms to
800–926 ms. Large updates included 649 files / 1.7 MB, 651 / 1.8 MB and
145 / 5.9 MB. Worker reset did not absorb the savings; Analyzer drivers
remained resident. Cleanup reset remained dominated by worker work. Trace whole-build times overlap; they are not speed samples.

The trace set includes one preliminary run per lane using the same sources
and setup, without checking executable identity against later runs. An AOT
recompilation run and a source-fallback setup were excluded. Earlier reports
used a different container, so their absolute times are not comparable.
The report records 827/827 outputs matching byte-for-byte, one pre-existing
missing output, and no remaining blob files after builds.

## Controlled local mixed fixture

Baseline `46ff144` (PR #91); candidate `07ab22d`, subsequently rebased as
`f7de876`. Measurements predate the PR's added capability guard. Linux x86_64,
kernel 6.18.44, 2 CPU quota, 8 GiB limit, Dart 3.13.3, Rust 1.98.1 release,
overlay filesystem, warm OS page cache. Both lanes use the same SDK,
dependencies and cache conditions, with corresponding AOT workers differing
only in transport sources and held unchanged within each lane.

The six-phase fixture includes 64 Riverpod/Freezed/JSON inputs, 144 shared
conditional/transitive sources, a resolver-free probe and post-process.
Every measured build matched all 384 stock build_runner outputs byte-for-byte.
Five barriers transport 320 values / 665050 bytes per regen.

Cold removes graph, outputs and analyzer caches while retaining prepared AOT,
manifest and SDK summaries; regen removes workspace state and generated
source outputs while retaining shared caches. One-file and broad edits change
provider names and output bytes. Setup and priming are untimed. Runs alternate
AB, BA, AB, with all metrics/traces disabled. Each cell has n=3;
milliseconds are median [min, max].

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

Regen median reductions of 0.25%/1.43% are inside observed variability. The
jobs=4 cold difference is unexplained and is not evidence for reset savings.

Separate WALL_TRACE runs, n=3 per lane/jobs, milliseconds median [min, max]:

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

Traces show spool/reset savings without a clear increase in worker reset or
dispatch; next no-op timings remain comparable. Independent interval medians
must not be summed; worker elapsed durations are not frontend wall. Staging
moved transport reads into
`cache_invalidation`, so compare it together with `overlay_read`.

Separate metrics runs retain 10/20 reset RPCs for jobs=2/4, 665050 logical
write bytes and 1330100/2660200 worker read bytes. Index JSON adds about
49/98 KB of IPC. Regen process-tree CPU medians were 3.040→3.023 s and
2.974→3.007 s; maximum individual-process RSS was 149.8→152.3 MiB and
156.2→162.8 MiB, rather than concurrent process-tree peak RSS.

## Synthetic I/O

Actual Rust blob writer versus per-asset files, fresh roots, warm page cache,
seven alternating samples per lane on overlay and tmpfs. Four sequential
Rust readers are used below; this is a transport microbenchmark, not a Dart
worker or application benchmark. Allocation is untimed; blob deletion is
timed, while baseline file cleanup is untimed. No fsync is issued.
Total median milliseconds:

| Values × bytes | Overlay files→blob | tmpfs files→blob |
| --- | ---: | ---: |
| 4096 × 64 | 200.863→13.230 | 43.866→10.915 |
| 650 × 2700 | 16.059→3.268 | 7.654→2.894 |
| 145 × 41000 | 14.228→5.562 | 5.011→4.374 |
| 8 × 1048576 | 5.116→4.840 | 6.220→6.601 |

Separate strace of 650 × 2700 with four readers reduced openat/close from
3260 to 15 each and statx from 3252 to 7. Writes remained 651, with equal
logical write/read bytes; indexed reads introduce seeks. The benefit comes
from fewer files and metadata operations, not one write syscall or lower
payload volume. A few large files can be neutral or slightly worse.

## Validation and limits

106 Rust tests and related Dart tests passed, along with analysis/format,
release compilation and both quick verification variants (with/without
arbitrary builders). Coverage includes malformed/incomplete transport,
partial-write cleanup/recovery, source/cache update→delete→recreate, repeated
resets/next builds, stock output equality, incremental failure atomicity,
post-process and four-worker watch. Full-suite and non-Linux validation
remain outstanding.

Application findings are reported evidence, not a local rerun. Small sample
counts do not establish general statistical significance. The detailed raw
samples and harnesses are retained locally outside Git.
