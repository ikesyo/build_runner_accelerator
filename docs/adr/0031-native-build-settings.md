# ADR 0031: Native build settings and configuration invalidation

- Status: Accepted
- Date: 2026-10-09
- Amends ADR 0029.

## Context

ADR 0029 routes define/release/config to stock. The native selector always uses
dev_options, and its manifest fingerprint does not identify CLI overrides or
named/package override files. Merely accepting these options would reuse the
wrong options, mappings, outputs and worker catalog. Watch pins worker artifacts
for a session, which also prevents correct reuse when selected factories change.

## Decision

Extend the native CLI boundary to define/release/config for the existing
manifest subset, including prewarm. Preserve the entire stock invocation;
unsupported build/watch syntax/configuration still routes as a whole before
actions. Prewarm retains its existing rejection of unsupported CLI syntax. Missing
selected files route before binary acquisition or manifest generation; auto
prewarm skips with a diagnostic, while rust errors.
Use a shared lightweight settings parser and build_config's official key/config
parsers. Differentially validate the parser against the bounded stock version's
BuildRunnerCommandLine and BuildOptions APIs. Keep Analyzer out of the manifest
code compilation path and continue using the isolated official trigger parser.

Separate ordinary builder definitions from selected named configuration, matching
stock. Resolve shallow defaults/mode/target/mode/global/mode/CLI overrides in
stock precedence order. CLI defines do not alter application selection. Preserve options map insertion
order across manifest/planning/IPC, including nested JSON, since a Dart builder
can observe that order. The wire fields remain unchanged.
Use identical settings in full generation, early catalog and trigger helpers.

Include supported CLI and selected/package config inputs in manifest/probe
identity and therefore graph compatibility. Replace watch pools when the
manifest identity changes. Compile caches may share identical code across
runtime settings, with existing SDK/source/dependency validation, because
options arrive at runtime; changed catalogs cannot share artifacts. Detached
prewarm retains the same configuration vector as foreground prewarm/build.

Watch application/output topology changes remain stock-only: 2.16.2 resident
reload differs from fresh builds for mapping/enablement changes. Auto hands the
complete invocation to fresh stock watch; rust errors before actions. Value-only
configuration changes remain native.

The original compact short spelling/config path boundary is replaced by
[ADR 0032](0032-stock-settings-spellings-and-paths.md). Ambiguous
package overrides and unsupported manifests remain fallback/error cases.
No partial application or silent loss of settings is permitted.

## Consequences

This replaces only ADR 0029's settings boundary; its other CLI, mode, process
and fallback contracts remain in effect.

See [configuration.md](../configuration.md) for stock APIs, precedence, input
identity, watch and cache boundaries. The settings fixture changes content,
output mappings, emission, target filters and builder enablement. Its serial
stock/native comparisons cover unchanged/restored builds, errors and retained
outputs, watch, JIT/AOT/prewarm and lossless fallback. Core full verification
includes that differential suite. Parser tests use stock APIs rather than only
asserting private cache keys.
