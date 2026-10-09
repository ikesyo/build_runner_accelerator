# ADR 0030: Compatibility cleanup during 0.x and disposable state

- Status: Accepted
- Date: 2026-10-08
- Amends ADRs 0001–0004, 0009, 0011, 0019, 0021, 0022, 0024, 0026, 0028 and 0029.

## Context

Development continues through 0.x releases. This cleanup prepares for an eventual
1.0 by removing obsolete accelerator compatibility paths. It does not select the
next release version, set a 1.0 schedule, or finalize the 1.0 API.

The [implementation audit](../compatibility-audit.md) identifies current
producers/consumers and separates accelerator history from stock behavior.

## Decision

- Preserve stock build_runner configuration/builder semantics, resolver
  visibility, transactional output behavior and auto/rust/dart selection.
- Remove unused accelerator aliases, flattened manifest readers and implicit
  IPC defaults. Current producers send the required data; missing or inconsistent
  metadata must not silently choose a different builder configuration.
- Treat manifest, graph, AOT/kernel, generator/probe, SDK summary and analysis
  cache storage as disposable internal state. Validate identity and format;
  regenerate invalid state without guaranteeing old-format migration. Genuine
  filesystem IO errors remain explicit.
- Remove both per-key cache alternatives and PACKED_STORE. Cache-disable
  controls and a fresh cache root already provide diagnosis/recovery. Maintaining
  two extra storage implementations is unnecessary for those paths.
- Do not delete user sources, generated source files or old cache directories
  merely to handle a format change. Normal successful action commits retain
  their existing output replacement/deletion behavior.

The [launcher reference](../launcher-and-release.md) owns the current interface
classification; the [update guide](../compatibility-cleanup.md) owns retired
items, regeneration details and safe recovery steps.

## Internal worker and protocol version

The generated Dart worker is an internal package component. `--worker` is a
repository test/benchmark/diagnostic override, not a third-party extension API.
Require exact package/frontend/worker versions and retain capability and
malformed-message validation to detect stale artifacts and incorrect messages.

Keep protocol v1: framing, binary encoding, operations and visibility semantics
are unchanged. Package-version validation rejects older workers even if they
advertise v1 capabilities; the protocol is release-coupled rather than a promise
of cross-release compatibility. Incompatible framing would require a new
protocol decision and number. [protocol/v1.md](../../protocol/v1.md) owns the
handshake and required-field specification.

## Consequences

An update may incur a cold build and require refreshing/removing internal artifact
overrides. The release workflow still selects package versions independently.
Historical ADRs, changelogs and measurements remain history; superseded contract
claims are marked with links to this decision.

Regression coverage checks old/corrupt state, missing or inconsistent metadata,
worker-version rejection, preserved files and stock output equivalence. See
[development verification](../development.md) and `scripts/correctness_upgrade.sh`.
