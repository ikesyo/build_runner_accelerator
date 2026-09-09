# ADR-0058: reuse resolved frontend state during watch builds

- Status: accepted
- Date: 2026-09-05

## Context

The native watch loop resolves a `Workspace` and dynamic builder manifest
before creating or reusing its worker pool. It then called the standalone build
entrypoint, which loaded the workspace and resolved the manifest again for the
same watch iteration. A valid manifest was not generated twice, but package
configuration fingerprinting, manifest deserialization, and Rust config
conversion were repeated. If the manifest was stale, the second resolution
also repeated the post-generation validation path.

The duplicate work is independent of the builder names and becomes more
visible for watch rebuilds whose actual action set is small or empty.

## Decision

- Keep `build::run` as the standalone entrypoint that owns workspace loading,
  frontend selection, and Dart fallback.
- Add a resolved `build::run_with_config` entrypoint that accepts the already
  loaded `Workspace` and `RustBuildConfig`.
- Have each watch iteration pass its resolved values directly to that entrypoint
  after initializing or reusing the worker pool.
- Do not change worker lifecycle, manifest compatibility, or builder-specific
  execution behavior as part of this optimization.

## Consequences

- A watch rebuild performs one workspace load and one manifest fingerprint/read/
  parse/config-conversion sequence instead of two before planning actions.
- The standalone build path and Dart fallback boundary remain unchanged.
- The resolved config is scoped to the same watch iteration and is not reused
  across filesystem events, so package/build configuration changes continue to
  be detected by the next iteration.

## Verification

- Rust 1.98.1 unit tests: 33 passed
- `scripts/watch_smoke_arbitrary_builder.sh`: output deletion, atomic save, and
  rename cases passed
- Existing target-cycle, dependency-target, package-target, capture, and
  Freezed benchmark regressions remain green
