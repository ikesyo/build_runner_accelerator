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

Stock 2.16.2 accepts compact short options and normalized configuration AssetIds.
Configuration identity alone also cannot detect a worker published before its
matching manifest during an interrupted settings switch or mixed cache restore.

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
code compilation path, YAML parsers out of the launcher, and continue using the
isolated official trigger parser.

Support attached `-cNAME` and groups of native boolean abbreviations (`r`, `d`).
Follow stock args: an attached value consumes the suffix only when its option
comes first; value-taking abbreviations later in a group are invalid. `-c=NAME`
includes `=` in the value, and separate values are never expanded as flags.
Grouping does not extend the build/watch-only acceptance of the retired `d` flag.

Construct `build.<config>.yaml` before normalization, replace backslashes with
forward slashes, and normalize POSIX segments inside the package like AssetId.
Choose the last config value before rejecting paths escaping the package. Use
the full normalized relative filename for preflight, loading and cache identity,
while retaining the original invocation. Config remains a name, not a file-path
option.

Separate ordinary builder definitions from selected named configuration, matching
stock. Resolve shallow defaults/mode/target/mode/global/mode/CLI overrides in
stock precedence order. CLI defines do not alter application selection. Preserve
options map insertion order across manifest/planning/IPC, including nested JSON,
since a Dart builder can observe that order. The wire fields remain unchanged.
Use identical settings in full generation, early catalog and trigger helpers.

Include supported CLI and selected/package config inputs in manifest/probe
identity and therefore graph compatibility. Replace watch pools when the
manifest identity changes. Compile caches may share identical code across
runtime settings, with existing SDK/source/dependency validation, because
options arrive at runtime; changed catalogs cannot share artifacts. Detached
prewarm retains the same configuration vector as foreground prewarm/build.

Bind the private version-9 manifest to the exact UTF-8 worker source with
`worker_source_digest`, using the existing FNV-1a disposable-state identity.
Before reuse, check the expected local worker bytes. Missing metadata, a missing
worker or a digest mismatch requires generation before actions. Restored caches
are rebased only to matching local source; stale absolute worker paths are never
used. Each artifact retains atomic publication and early compile overlap. This
check detects mixed generations at reuse time; it does not serialize competing
builds. Existing prewarm locks and unstable-workspace fallback still apply.

Watch application/output topology changes remain stock-only: 2.16.2 resident
reload differs from fresh builds for mapping/enablement changes. Auto hands the
complete invocation to fresh stock watch; rust errors before actions. Value-only
configuration changes remain native.

Stock's watch reload predicate compares raw config names, not normalized
AssetIds. Keep the resolved plan when a selected-file edit is not a recognized
configuration event; later source edits also use that plan until a recognized
event reloads it. Match deepest-package attribution: selected root configs
inside dependencies are not root config events. Canonical selected root configs
take precedence over artifact/output event filters. Separate build/prewarm
invocations always resolve current settings.

Ambiguous package overrides and unsupported manifests remain fallback/error
cases. No partial application or silent loss of settings is permitted.

## Consequences

This replaces only ADR 0029's settings boundary; its other CLI, mode, process
and fallback contracts remain in effect. Protocol v1 and BuilderOptions are
unchanged. Older unbound version-9 cache entries require one regeneration;
compatible worker code continues to share validated AOT/kernel artifacts.

See [configuration.md](../configuration.md) for stock APIs, precedence, input
identity, watch and cache boundaries. The settings fixture changes content,
output mappings, emission, target filters and builder enablement. Its serial
stock/native comparisons cover unchanged/restored builds, errors and retained
outputs, watch, JIT/AOT/prewarm and lossless fallback. Core full verification
includes that differential suite. Parser tests use stock APIs rather than only
asserting private cache keys. Coverage includes compact groups, normalized paths
and stock's watch reload distinctions.

Publication recovery tests restore manifest A alongside a valid empty worker B,
edit an input and compare stock/native success and generated bytes in JIT/AOT,
then check no-op and restored inputs. Without the guard the JIT case fails with
`Unknown builder`. Unit tests cover unbound manifests, changed worker source and
empty/ASCII/UTF-8 digest vectors.
