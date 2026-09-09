# ADR-0063: local background AOT compilation

## Status

Accepted

## Date

2026-09-06

## Context

An AOT worker has a substantially lower startup cost than the script worker,
but the first `dart compile exe` can dominate a local build. Making that
compile part of the foreground worker-pool startup removes the benefit from
the first invocation and makes an AOT cache miss especially noticeable.

The CI path already has an explicit synchronous `aot-prewarm` command. Local
development needs a different timing contract while preserving the same
artifact validation and atomic publication rules.

## Decision

Add the opt-in mode:

```sh
BUILD_RUNNER_ACCELERATOR_WORKER_AOT=background \
  scripts/run_rust_frontend.sh build --root "$PWD" --mode rust
```

On a cache hit, the normal AOT worker is selected. On a cache miss:

1. The foreground process returns a Dart script worker immediately.
2. It starts the same binary as a detached `aot-prewarm` helper.
3. The helper performs the synchronous AOT compile and atomically publishes
   the depfile, metadata, and executable.
4. A later invocation selects the published AOT artifact after metadata
   validation.

The helper receives a per-workspace lock reservation. A second invocation
while the helper is running continues with the script worker without starting
another compiler. A stale lock is recoverable after a bounded age. The helper
does not inherit foreground stdio, so its compiler output cannot corrupt the
worker protocol or block the foreground command. If the helper fails, the
foreground build remains successful and the next invocation can retry.

For a long-running watch pool, the next rebuild checks whether the background
artifact has become valid. If so, the pool restarts its workers once and
switches from script to AOT without changing the default or explicit-worker
paths.

## Consequences

- The first local build pays only the script worker startup cost.
- A second build can receive the AOT startup benefit if compilation completed.
- A background compiler consumes CPU concurrently with the first build, so the
  mode remains opt-in and is not used by CI; CI should continue to use the
  synchronous prewarm contract.
- The existing kernel cache remains unchanged for default mode.
- A failed or unsupported background compile does not poison the artifact and
  does not fail the foreground build.

## Verification

`scripts/correctness_aot_background.sh` holds the compiler behind a gate and
confirms that the first build starts the script worker before the gate opens,
then verifies artifact publication and AOT reuse on the next build.
