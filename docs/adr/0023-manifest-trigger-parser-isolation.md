# ADR 0023: Run the official trigger parser outside the manifest generator

- Status: Accepted
- Date: 2026-10-02

## Context

The manifest generator imported build_runner's `BuildTriggers` to normalize
configuration and preserve its digest and warning behavior. That import also
pulled Analyzer into the generator's compiled kernel: 800 source dependencies
and a 28.2 MB kernel in the measured JSON fixture. The generator and worker
compiled Analyzer independently, contending for CPU during fully cold AOT
startup even though manifest generation needs no resolved Dart source.

## Decision

- Keep the official `BuildTriggers.fromConfigs` parser, aggregation, digest,
  and warning rejection. Move its invocation and existing normalization into
  `manifest/trigger_worker.dart`, outside the generator's import closure.
- The generated worker accepts an internal `--manifest-triggers <root>
  <result>` command before runtime initialization. It loads the official
  build configurations and writes the digest and normalized triggers to an
  invocation-local JSON file. It does not initialize a resolver, execute
  builders, enter IPC, or write generated outputs.
- After emitting the worker entrypoint, the generator uses the existing
  invocation-local early-AOT readiness marker. Only an existing executable
  whose recorded source matches the current worker source is eligible.
  This shares the worker compile already needed for the build.
- Missing, mismatched, unavailable, or unsuccessful worker execution uses
  the same helper from Dart source with the current package configuration.
  Malformed responses also use the source helper. Recognized unsupported
  trigger errors use a structured response, preserve the original diagnostic,
  and reject immediately without repeating deterministic parsing failures.
  Worker and source attempts own separate result files; timed-out attempts are
  never decoded, even if the child survives termination and writes late.
  Execution uses the existing bounded probe termination policy. Trigger
  parsing failure still rejects the manifest and preserves conservative
  auto-mode fallback. Temporary result files are removed after every attempt.
- AOT policy, builder selection, manifest format, probe cache identity, and
  worker IPC remain unchanged. No new persistent trigger cache is introduced.

## Consequences

The generator kernel no longer compiles Analyzer. The first measurement reduced
it to 153 dependencies and 1.94 MB. The AOT worker still includes the official
parser, so cold execution and subsequent rebuilds retain AOT performance.
Source-only and internal worker-override paths incur a separate helper launch; their
performance is not the target of this decision.

The helper rereads build configuration. The frontend's existing post-generation
fingerprint validation rejects or retries inputs that changed during generation.
Worker source and dependency validation invalidate older AOT artifacts normally.
Correctness checks must cover trigger unions, duplicates, official warnings,
digest identity, helper fallback, and stock-generated output equality.
