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
  for waiting readers.
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
  also releases any outstanding lease. Waiting workers then check the published
  cache and refresh their packed indices at this synchronization point.
  Existing valid `.linked` entries (packed or legacy, according to the active
  layout) bypass ownership. This is a cache temperature heuristic, not proof
  that every workspace dependency is cached.
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
fingerprint and then bypass the startup gate, retaining ordinary resolver
fan-out. Syntax-only actions leave the next linking action eligible for
ownership. A partially warm cache can still duplicate uncached work; this
decision does not introduce per-key analysis locks or serialize every library.

Tests cover stale readers, torn tails, cross-process publication and waiting,
warm parallel continuation, nested leases, timeout fallback, and killed owners.
Wall-time improvement on the large reference workspace has not been measured;
the previously discussed ten-second saving remains a hypothesis.

## Supporting evidence

A same-directory comparison reduced aggregate child CPU by 23% and cold elapsed
time by 6.9% on a synthetic shared dependency closure, with the ordinary
500-input fixture effectively unchanged. The packed-write improvements in
[ADR 0025](0025-packed-cache-publication-without-fsync.md) subsequently reduced
cold elapsed time a further 11.4% and 17.3% on those fixtures. These are native
frontend measurements with precompiled workers; they do not predict the
unavailable reference workspace's saving.

Generated-source and native-cache outputs matched baseline in both comparisons;
the synthetic generated sources also matched stock build_runner. Process tests
cover publication before builder release, stream subscription under ownership,
consumer work without ownership, and completed writes surviving owner
termination. The full release matrix remains required before merging.

Detailed conditions, timing tables, superseded experiments, and validation logs
are recorded in the [benchmark note](../benchmarks/cold-worker-analysis-2026-10.md).
