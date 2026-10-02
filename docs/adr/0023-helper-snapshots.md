# ADR 0023: Warm snapshots for catalog and analysis helpers

- Status: Accepted
- Date: 2026-10-02

## Context

The early catalog and analysis prewarmer pay Dart source compilation and JIT
startup on each invocation. Compilation experiments support
warm snapshots for these short-lived helpers, while retaining AOT for the
resident worker and the existing `dart compile exe` pipeline.

## Decision

Resolve each helper as a validated app-jit snapshot, then a validated kernel,
then source. Check the workspace-local tier and shared tier at each priority.
On a complete miss, keep the source invocation and queue a detached compiler
until the foreground operation finishes, with a per-helper lock at launch.
Watch releases queued training after each build so it can finish while the
event loop waits. This keeps helper compilation out of the first cold build:
immediate training measured a 5.1% regression on a two-CPU environment. A
subsequent build started before training finishes can still contend with it.
The compiler first publishes a
kernel and dependency metadata, then trains that exact kernel to produce
app-jit. Failed training leaves the kernel usable.

`BUILD_RUNNER_ACCELERATOR_HELPER_SNAPSHOT=0` selects source and suppresses
background compilation. The resident worker's AOT policy is unchanged.
Catalog training writes a disposable entrypoint; analysis training warms the
existing analyzer cache within the requested directories. Summary-only prewarm
trains with `--dirs none` rather than scanning the entire workspace. Runtime
arguments still select the actual output
entrypoint and prewarm shards/directories.

Validate source dependency digests, artifact contents, package configuration,
OS/architecture, and the executing Dart SDK version/revision. Helper SDK
selection follows `--dart`, independently of the worker's `DART_SDK` override.
Shared artifacts use the existing atomic staging and metadata validation.

App-jit ignores runtime `--packages` and retains its training configuration
URI. Bind helper keys to the configuration file location and resolved package
roots, in addition to logical dependency identities. A relocated workspace
trains its own helpers; these snapshots are not portable CI artifacts.
Remote distribution is deferred.

## Consequences and validation

Warm repeated helper invocations avoid source compilation and may reuse JIT
code. A helper failure still follows the existing optional prewarm or
authoritative full-generator behavior. Invalid cache metadata/content selects
a lower tier; VM startup failures are not themselves retried at another tier.

Rust tests cover relocation/SDK revision identity and source/artifact digest
invalidation. `correctness_helper_snapshot.sh` covers real helper training,
JIT/kernel output equality, shared restore, disablement, corrupt snapshots,
dependency edits with preserved mtime, prewarm arguments, and failed training.
It runs in quick verification. The
[benchmark report](../benchmarks/helper-snapshots-2026-10.md) separates helper
timings from complete builds and records first-build training contention.
