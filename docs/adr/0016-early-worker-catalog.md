# ADR 0016: Select the worker catalog before cold generator compilation

- Status: Accepted
- Date: 2026-09-30

## Context

ADR 0015 avoids source compilation on a generator snapshot hit. A completely
cold cache still compiles the generator's Analyzer dependency closure before
ADR 0014 can start worker AOT compilation. This leaves compilation of the
generator on the worker startup critical path.

Porting the official build_config YAML/default semantics into Rust would add
a second compatibility implementation. Emitting every builder definition
instead of the selected catalog can import invalid or unavailable factories
and changes the final worker's AOT identity.

## Decision

On a generator snapshot miss or source fallback, Rust runs the small
`tool/generate_worker_catalog.dart` helper before compiling the full generator.
The helper uses the existing package graph loader and official BuildConfig
parser, then uses the
same target ordering, source patterns, application selection, factory IDs and
worker emitter as the full generator. These shared libraries do not import
Analyzer. Rust orchestrates selection; selection semantics remain in Dart.

If synchronous worker AOT is enabled, the helper's entrypoint starts the
existing early AOT thread. Generator kernel compilation and the factory probe
can then overlap worker compilation. A snapshot hit skips the extra helper;
the full generator emits the early entrypoint as in ADR 0014. JIT, background
AOT, explicit worker artifacts, and custom workers skip the helper as well.
`BUILD_RUNNER_ACCELERATOR_EARLY_CATALOG=0` disables this earlier selection pass
and the compiled-worker probe described below.

On a probe cache miss, the full generator can run the already compiled worker
in a separate `--factory-probe <requests.json> <result.json>` process. This
instantiates the same selected factories with their target-local options and
root flags, returning mappings and runtime types in the existing probe result
format. It starts neither the worker build runtime nor IPC. Normal worker
startup still reserves stdout for IPC; the probe process's output pipes are
drained, as with the existing source probe.

Rust publishes an invocation-specific readiness file only after AOT preparation
succeeds and the source still matches the source captured before compilation.
The generator independently compares the published source with its current
entrypoint before launching the executable. Readiness waiting is bounded to
90 seconds; actual factory execution retains the existing 30-second timeout
and termination handling. Missing/invalid/mismatched readiness, failed execution,
or invalid JSON uses the source probe. Separate result files prevent a
timed-out child from writing into the source retry's result. Complete responses
use the existing validated probe cache; partial factory failures retain the
existing unsupported-manifest behavior.

The full generator remains authoritative for triggers, runtime factory probes,
manifest conversion and compatibility. Helper failure discards its entrypoint
and continues through the full generator. A successfully compiled early worker
whose source differs from the final worker is discarded. The normal worker
cache validation and preparation then use the final source. Always join the
early thread before returning, including generator failure or failure to spawn
the generator, so temporary compile artifacts cannot race a later invocation.
No graph or generated build output is committed by the helper.

## Consequences

Cold compilation can start worker AOT before the heavyweight generator has
compiled, and reuses that compiled code for the factory probe. The extra
lightweight process and concurrent compiler CPU/memory
use are real costs; actual completed cold builds, rather than entrypoint
timings alone, determine the performance result. Existing valid manifests and
warm generator snapshots avoid the extra selection pass. Cache identities,
manifest version, worker IPC and frontend fallback modes do not change.

Integration verification covers matching catalogs and source/AOT probe results,
warm snapshot hits, helper failure, mismatched source, full generator failure,
JIT/background/explicit artifacts and disabled early selection. Unit tests
cover readiness timeouts, artifact/source validation, multi-factory options,
root flags, post-process factories and isolated factory exceptions.
Existing selection and builder compatibility probes continue to
exercise the shared rules. Measurements belong in
[the startup report](../benchmarks/manifest-startup-2026-09.md).
