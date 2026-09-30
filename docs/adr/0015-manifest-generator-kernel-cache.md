# ADR 0015: Cache the manifest generator's kernel snapshot

- Status: Accepted
- Date: 2026-09-30

## Context

The v0.7.0 large-workspace report observes a 12–15 second delay before the
generator emits the worker entrypoint. ADR 0014 removes the probe from the
cold critical path but cannot start worker compilation before that entrypoint.
Even a warm probe and worker AOT cache leave this generator startup delay on
manifest regeneration.

The generator imports the official build_runner trigger implementation, which
imports Analyzer AST types. Source execution therefore compiles a substantial
dependency closure before entering main. Builder selection itself must remain
compatible with build_config and the existing manifest selection rules.

## Decision

Cache a Dart VM `--snapshot-kind=kernel` artifact under the machine-wide cache
root from ADR 0012, in `manifest-kernel/<key>/generator.dill`. On a miss, the VM
compiles without running main, then the frontend executes the resulting kernel
with the same package configuration and generator arguments as source execution.
The generator continues to read workspace configuration and emit the early
worker entrypoint before probing; ADR 0014's AOT overlap remains unchanged.

The cache key includes a format version, OS/architecture, the selected VM's
SDK version, allowed experiments, SDK VM platform kernel contents, the absolute generator
path and contents, and the absolute package-config path and contents. Kernel
source URIs are absolute: this cache intentionally does not promise reuse
across relocated package roots or checkouts. Changes to runtime build.yaml
inputs regenerate the manifest but do not themselves invalidate compiled code.

Metadata records the compiler depfile's complete source dependency list and
content digests, including mutable path dependencies. Every hit validates
those digests, requires the generator in the list, and validates the kernel
file's own digest. Missing/unparsable metadata, a missing generator dependency,
a content mismatch, or an outdated key is a miss.
Source mtimes alone are insufficient, including after branch switches.

Compilation uses an invocation-specific staging directory and publishes files
by rename. Artifact and metadata digests reject a partially published pair.
Concurrent misses may duplicate work; this iteration does not introduce locks.
Cache preparation failures preserve source execution and the existing
auto/rust/dart mode contract. `BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT=0`
disables the optimization for comparisons or troubleshooting.

`BUILD_RUNNER_ACCELERATOR_METRICS=1` reports snapshot hit/miss and preparation
time on stderr, plus generator runtime stage times. Dart's stage timer starts
inside main, so it excludes VM startup and source compilation.

## Consequences

Manifest regeneration with a warm snapshot avoids recompiling the generator.
An existing valid manifest does not perform snapshot validation or preparation.
The first snapshot creation still compiles the same dependency closure and
serializes a kernel; it can be slower than source execution. This decision does
not claim a speedup for an entirely cold machine cache. Probe and worker AOT
caches retain their independent invalidation rules.

Kernel snapshots are preferable here to trained JIT snapshots because they
cache compiled code without capturing generator runtime state. No public
manifest or worker IPC format changes.

The targeted correctness probe covers cache misses/hits, content invalidation
with restored mtimes, an independent worker SDK override, runtime build.yaml
changes, corrupted artifacts, an unavailable cache, and the disabled/source
route. Native tests also cover SDK,
package-config, generator and dependency identities. Performance measurements
and the investigation of early builder selection belong in the experiment
report, not in the cache validity contract.
