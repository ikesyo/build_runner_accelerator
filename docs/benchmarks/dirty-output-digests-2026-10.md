# Dirty output digest deduplication (2026-10-07)

Baseline: main `b8b4ff9d1c387a332b9780d92e0a0b614e343395`.
Candidate deduplicates the union of recorded and declared outputs by the
`PathBuf` returned by `output_path()`, for one `analyze()` call. It retains
source/cache distinctions, recorded-only/dynamic/optional outputs, and replays
successful digests in the original recorded-action order followed by each spec
immediately before its dirty check. Missing results do not erase earlier
logical-ID values. Hashing and non-NotFound I/O errors are unchanged.

## Conditions and commands

Linux, 3 available CPUs, Rust 1.98.1 release, Dart 3.13.3, jobs 1.
A disposable copy of `fixtures/json_serializable_500_app` supplied 500 inputs,
500 cache parts and 500 source outputs. Both lanes used the same package lock,
SDK, pub cache, fixture/cache paths and explicitly prepared AOT worker.
Three repeats alternated lane order. SDK summaries and OS page cache stayed
warm; cold cleared graph/output and analyzer byte-store/directive caches;
warm-clean cleared graph/output while retaining analyzer caches.
One-file/broad renamed `value` to `valueEdited`/`valueBroad`, changing output bytes.

Build both source trees with `cargo build --release --locked --manifest-path
rust/Cargo.toml`, using separate target directories. Resolve the copied fixture
with `dart pub get --offline` and prepare its AOT worker with an untimed native
build. The comparison command is:

```bash
PUB_CACHE="$PUB_CACHE" python3 scripts/benchmark_cold_build.py \
  --baseline "$MAIN_BIN" --candidate "$CANDIDATE_BIN" \
  --frontend-dart "$DART_BIN" --root "$FIXTURE" --cache "$CACHE" \
  --results "$RESULTS" --worker "$AOT_WORKER" \
  --jobs 1 --repeats 3 --stock-check
```

The actual repeated comparisons reused the stock hashes from the initial stock
run rather than recompiling stock. All 1,000 outputs matched stock and the other
lane in every case/repeat. A separate diagnostic run compared full ordered
`dirty`, `lazy_force_keys`, and deleted-action key lists: all 15 pairs matched
(clean/broad: 1,000 dirty; no-op: 0; one-file: 2).

## Output I/O and dirty time

Temporary, uncommitted instrumentation counted each `fs::read` attempt in
`output_digest()` and the successful bytes passed to `digest_bytes()`. These are
**dirty output** counts, excluding snapshot/worker/commit I/O. Missing paths
count as read attempts but perform no hash. The diagnostic timer spanned
`analyze()` entry through deleted-action collection in both lanes, including
baseline recorded-output reads outside its original `dirty_check_us` timer.
Counters and timer were absent from the separate process-wall comparison.

| Case | Read attempts main → candidate | Hashes main → candidate | Bytes read/hashed main → candidate | Full analyze median ms main → candidate |
| --- | ---: | ---: | ---: | ---: |
| Cold clean | 1,000 → 1,000 | 0 → 0 | 0 → 0 | 6.386 → 7.855 |
| Warm clean | 1,000 → 1,000 | 0 → 0 | 0 → 0 | 6.438 → 8.354 |
| No-op | 2,000 → 1,000 | 2,000 → 1,000 | 978,000 → 489,000 | 10.668 → 10.164 |
| One-file | 2,000 → 1,000 | 2,000 → 1,000 | 978,000 → 489,000 | 10.526 → 10.035 |
| Broad | 2,000 → 1,000 | 2,000 → 1,000 | 978,108 → 489,054 | 14.135 → 13.788 |

The production `dirty_check_us` now starts before collection, covering recorded
and declared output work. Its endpoint still precedes deleted-action collection;
it is not directly comparable with the baseline metric's narrower interval.

## Whole-process wall time

Direct native frontend timing includes process startup, manifest/graph/snapshot
work, dirty checks, needed worker execution and commit. It excludes the Dart
launcher, dependency resolution and AOT preparation. Values are medians with
min–max ranges, milliseconds, from the uninstrumented three-repeat run.

| Case | Main | Candidate |
| --- | ---: | ---: |
| Cold clean | 1,579.8 (1,499.8–1,608.1) | 1,564.6 (1,537.7–1,609.6) |
| Warm clean | 1,318.9 (1,304.5–1,345.2) | 1,291.4 (1,268.6–1,371.7) |
| No-op | 34.9 (34.1–37.5) | 35.3 (33.6–35.7) |
| One-file | 140.5 (140.0–147.1) | 141.7 (139.2–142.1) |
| Broad | 1,539.4 (1,496.2–1,564.0) | 1,597.8 (1,474.4–1,691.1) |

Reads/hashed bytes halve for overlapping outputs. Dirty medians improve about
0.5 ms for no-op/one-file, while path registration adds 1.5–1.9 ms to clean dirty
checks. No clear whole-process speedup is established by these three samples;
broad's higher median is within the overlapping observed ranges.

Local verification: cargo fmt check; Clippy all targets/features with warnings
denied; build tests (7), graph tests (8), plan tests (8); stock comparison above.
The added tests cover overlap, recorded-only/declared-only outputs, aliases with
identical resolved paths, source/cache collisions, missing/edited/deleted files,
next-pass refresh, optional outputs, deletion planning, and I/O errors.
Broader lifecycle/watch/compatibility suites remain for CI.
