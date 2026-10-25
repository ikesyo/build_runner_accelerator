# Documentation

## Using the accelerator

| Guide | Purpose |
| --- | --- |
| [Project README](../README.md) | Install, run, and understand the main limitations |
| [CLI and compatibility contract](launcher-and-release.md) | Supported dependencies, options, output policies, environment controls and platforms |
| [Configuration](configuration.md) | `build.yaml`, option precedence, source sets and watch reloads |
| [Compatibility inventory](compatibility-probes.md) | Validated workloads, exact fixture scope and known blockers |
| [Migration and recovery](compatibility-cleanup.md) | Retired options, switching from stock and interrupted publication |
| [Benchmarks](benchmarks.md) | Measured results and their limitations |

## Developing and releasing

| Guide | Purpose |
| --- | --- |
| [Development](development.md) | Checkout setup, verification and focused correctness checks |
| [Roadmap](roadmap.md) | Open release gates and future work |
| [Distribution validation](distribution-validation.md) | Release workflow, packaged E2E, provenance verification and platform evidence |
| [Architecture decisions](adr/README.md) | Durable decisions and superseded contracts |
| [Worker protocol](../protocol/v1.md) | Internal Rust/Dart wire contract |

Fixture READMEs own detailed configuration and coverage; the compatibility
inventory links to them. Files under [benchmarks/](benchmarks/) and
[probes/](probes/) retain dated measurements, lockfiles and replay evidence.
Their old commands describe the recorded run, rather than the current CLI.
ADRs preserve decision history; follow supersession notices for current rules.

## Keeping documentation useful

- Update the guide that owns a behavior when changing it. Other pages should
  link to that guide instead of repeating its contract or test inventory.
- Keep the README focused on adoption and common commands. Put implementation
  details in ADRs, the protocol or source comments.
- Keep only open work in the roadmap. Record completed compatibility work in
  the inventory and fixture; retain release evidence in distribution validation.
- Give measurements a date, source revision, toolchain, command and scope.
  Preserve raw evidence and distinguish historical results from current behavior.
- Check relative links and heading anchors when moving or merging content.
  README installation versions are maintained by `scripts/sync_release_metadata.py`.
