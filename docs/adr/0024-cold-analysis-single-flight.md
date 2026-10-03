# ADR 0024: Single-flight cold worker analysis

- Status: Accepted
- Date: 2026-10-03
- Amends: ADR 0009 (cold resolver fan-out), ADR 0021 (reader visibility)

## Context

Multiple resolver workers can miss the same empty shared byte store and link
the same dependencies concurrently. Earlier JIT prewarm experiments paid extra
startup and competed with the build workers. A packed reader also retained its
initial index until it wrote a record, so waiting for another worker's writes
alone did not guarantee a cache hit.

## Decision

- At the startup publication boundary, adopt complete, checksum-valid
  records appended since the reader's last scan. The linked-entry check under
  the startup lock refreshes the index before a waiter resumes analysis.
  Readers never truncate a partial tail; only the writer recovery path can
  do that under its exclusive lock. Ordinary misses do not poll the file: many
  misses are genuinely new keys, and publication-boundary refresh is sufficient
  for waiting readers. Removing miss polling did not establish a wall-time gain.
- Gate real worker linking calls with an OS lock in the byte-store
  fingerprint directory (`.analysis-startup.lock`). Acquire after SDK-summary
  validation, before `libraryFor`, `libraries`, `findLibraryByName`, or a
  resolving `astNodeFor` call can start linking. Syntax-only calls remain
  parallel and do not acquire ownership.
  This leaves non-resolver actions and the Rust parallel scheduler unchanged.
- Check for linked entries only after acquiring the lock. An empty store, or
  one containing only syntax/unlinked entries, holds the lock through the
  linking call and releases it when that call completes, including failures.
  Concurrent calls in one resolver retain ownership until all finish. Stream
  calls release before yielding a library to consumer code. Resolver release
  also releases any outstanding lease. Waiting workers then check the published cache and refresh
  their packed indices at this synchronization point. Existing valid `.linked` entries (packed or
  legacy, according to the active layout) bypass ownership. This is a cache
  temperature heuristic, not proof that every workspace dependency is cached.
- Share one gate per fingerprint in each isolate. Reference-count concurrent
  and nested acquisitions so optional builders cannot wait on their own
  process's lock. Once linking has populated the store, the gate stays open
  for that worker process, including phase resets and watch builds.
- Never delete the lock file. Process termination releases ownership. Retry
  nonblocking lock contention asynchronously; unavailable locking or a
  three-minute timeout falls back to normal parallel analysis. Cache and
  lock failures cannot change outputs or fail a build.
- Shared-store opt-out disables the gate. Set
  `BUILD_RUNNER_ACCELERATOR_ANALYSIS_SINGLE_FLIGHT=0` to retain shared caching
  with simultaneous cold linking for A/B measurements. The gate applies to
  real build workers; independent JIT prewarm remains opt-in and does not
  acquire it.
- With runtime metrics enabled, report acquisition/check time as
  `analysis_startup_wait_us` in the per-action resolver breakdown.

## Consequences

Cold real workers reuse the first owner's linked entries without a separate
prewarm process or an IPC change. Warm workers pay one lock/check per
fingerprint and then bypass the startup gate, retaining ordinary resolver fan-out. Syntax-only actions
leave the next linking action eligible for ownership. A partially warm cache
can still duplicate uncached work; this decision does not introduce per-key
analysis locks or serialize every library.

Tests cover stale readers, torn tails, cross-process publication and waiting,
warm parallel continuation, nested leases, timeout fallback, and killed owners.
Wall-time improvement on the large reference workspace has not been measured;
the previously discussed ten-second saving remains a hypothesis.

## Initial local timing

Compared baseline commit `a722a77` with this implementation using the same
release native binary, precompiled AOT workers, warm SDK summaries, `--jobs 4`,
isolated caches, and alternating variant order. Each value is the median of
five runs; cold runs clear the byte store, and both cases clear build outputs
and the build graph. Metrics were enabled for both variants. The machine had
three CPUs in its affinity mask but a two-CPU cgroup quota. No other verification
jobs ran during these measurements.

| JSON inputs | Byte store | Baseline seconds | Candidate seconds | Change |
| ---: | --- | ---: | ---: | ---: |
| 10 | Empty | 0.345 | 0.365 | +5.8% |
| 10 | Warm | 0.320 | 0.310 | -3.2% |
| 500 | Empty | 1.645 | 1.836 | +11.6% |
| 500 | Warm | 1.428 | 1.629 | +14.1% |

Disabling the gate on the candidate did not remove the 500-input regression.
A further check with metrics disabled and explicit precompiled worker paths
(bypassing normal AOT validation) also retained that regression. Crossing the
two worker binaries between the two workspaces subsequently showed that the
extra system CPU followed the workspace rather than the binary. These initial
results do not isolate a regression caused by the gate; the shared-directory
comparison below supersedes them for assessing worker behavior.
The approximately 91-second reference workspace is unavailable in this
environment; these fixtures cannot establish its expected ten-second saving.
Raw measurements and scripts are in `/workspace/single-flight-speed`, including
`results/optimized-summary.json` and `results/selected-aot-summary.json`.

## Shared-directory comparison and lock lifetime correction

The first implementation retained ownership until the entire builder action
released its resolver. It now releases when linking completes, before arbitrary
builder code resumes. Concurrent linking calls share ownership until all finish;
stream consumers do not retain ownership between library events. Failure and
resolver cleanup also release ownership. This removes unnecessary serialization
after cache publication without adding another warmup process.

The final comparison alternates baseline and candidate precompiled workers in
the **same working directory**, with the same package config, analyzer cache and
accelerator cache. Each cold case clears the byte store, and clean cases clear
the graph and generated files. AOT compilation is excluded; explicit worker
paths bypass AOT validation. Metrics are disabled. No other verification jobs
run during measurement. The CPU quota, SDK, native binary and four-worker
setting are unchanged. Each value is the median of five runs.

One case extends the ten-input JSON fixture with a synthetic shared import cycle
of 200 files, each containing a class with 100 fields. This tests repeated linking
of a common dependency closure; it is not the unavailable reference workspace.

| Case | Shared closure baseline | Shared closure candidate | 500-input baseline | 500-input candidate |
| --- | ---: | ---: | ---: | ---: |
| Empty byte store, clean | 1.225s | 1.141s | 1.529s | 1.524s |
| Warm byte store, clean | 0.443s | 0.422s | 1.320s | 1.300s |
| No-op | 0.0101s | 0.0105s | 0.0404s | 0.0401s |
| One-file comment edit | 0.325s | 0.322s | 0.261s | 0.257s |
| Broad comment edit | 0.574s | 0.540s | 1.318s | 1.278s |

The shared-closure cold case uses 2.280s versus 1.752s of aggregate child CPU
(user plus system), a 23% reduction; elapsed time falls 6.9%. The normal
500-input cold case is effectively unchanged. These measurements validate
reduced redundant work on a shared closure but cannot predict a ten-second
saving on the reference workspace or isolate the timing correction's share of
the gain. All source and native cache outputs match baseline for every measured
case. The synthetic case is also checked against stock build_runner.

Reproduce locally with `python3 /workspace/single-flight-speed/final.py` after
preparing the workspaces; `heavy.py` generates the synthetic inputs. Raw data,
artifact hashes and full commands are retained in `results/final-measurements.json`,
`results/final-metadata.json`, and `results/final-summary.json`. These are local
artifacts, not a portable benchmark harness.

A subsequent stream-only correction defers subscription until lock acquisition;
neither JSON benchmark uses that entry point. Tests assert that stream analysis
starts under ownership and that consumer work does not retain ownership.

## Local verification

Linux x64, Dart 3.13.3, Cargo 1.98.1; the repository pub cache and an offline
Dart CLI wrapper alongside the SDK executable were used. Static analysis of
`lib bin test tool`, all 133 Dart tests, Rust's 97 tests, both the default quick
verification and `VERIFY_ARBITRARY_BUILDER=1` quick verification, and generic watch smoke passed. Watch covered generated-output
deletion, source edits, and conditional dependency edits.

Final verification logs are in `/workspace/single-flight-speed/final-verify.log`,
`final-arbitrary-verify.log`, `final-all-dart-tests-stream.log`, and
`final-stream-analyze.log`. The arbitrary-builder run covers every case,
including failure recovery, selective invalidation, globs, target sources,
extension mapping and output conflicts. The timing comparison baseline is
`a722a77`; the full release matrix is still required before merging.

Functional four-worker check:

```bash
DART_BIN=/workspace/build_runner_accelerator/.toolchains/dart/dart-sdk/bin/dart-single-flight \
BUILD_RUNNER_ACCELERATOR_CACHE=/workspace/build_runner_accelerator/.toolchains/single-flight-json-final-cache \
BUILD_RUNNER_ACCELERATOR_METRICS=1 JOBS=4 COUNT=10 \
  bash scripts/benchmark_json_serializable.sh
```

The ten-input JSON fixture used an empty accelerator cache, existing SDK
summary and workspace dependencies, and AOT workers. All source-output byte
comparisons with stock passed; no-op used the native no-work path. Native
end-to-end seconds from this single functional run:

| Clean | No-op | One file | Broad (10 files) |
| ---: | ---: | ---: | ---: |
| 46.908 | 0.223 | 0.639 | 0.844 |

Clean includes worker compilation. Other verification processes ran
concurrently, and stock's build cache was already populated. These times are
recorded for the validation policy, not a performance comparison or evidence
of the anticipated large-workspace saving. The command log is
`/workspace/single-flight-json4-final.log`.

A separate native clean probe with warm worker AOT and an empty byte store
recorded 24 gets / 0 hits / 24 puts for the first resolver action, versus
24 gets / 22 hits / 2 puts for the other resolver worker's first action.
The remaining two puts belong to its different primary input. All ten source
outputs remained byte-identical. `--jobs 4` retains the existing resolver cap
of two active resolver workers. Raw action metrics are in
`/workspace/single-flight-native-probe.log`; process tests exercise contention
explicitly because this small fixture need not overlap the first linking call.
