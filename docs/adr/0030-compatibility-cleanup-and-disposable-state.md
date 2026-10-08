# ADR 0030: Compatibility cleanup during 0.x and disposable state

- Status: Accepted
- Date: 2026-10-08
- Amends ADRs 0001–0004, 0021, 0022, 0024, 0026, 0028 and 0029.

## Context

Development continues through 0.x releases. Before an eventual 1.0, remove
obsolete accelerator compatibility paths and clarify which interfaces are
public and which state can be regenerated. This decision records the current
cleanup; it does not select the next release version, set a 1.0 schedule, or
finalize the 1.0 API. Further compatibility decisions may follow during 0.x.

## Decision

Stock build_runner configuration, BuilderOptions, expected-output mapping,
resolver visibility, resource lifetime and transactional output behavior remain
our compatibility reference. The auto/rust/dart selection policy is unchanged.
Remove the specific obsolete accelerator aliases, message defaults and storage
readers identified in this audit. Retaining every interface or internal format
from earlier 0.x releases is not a requirement for this cleanup.

The supported CLI and environment classifications are listed in
[the cleanup/update guide](../compatibility-cleanup.md). Remove the
`aot-prewarm` alias at both launcher and native parser boundaries, including
Dart mode; use `prewarm`.
Keep diagnostic cache-disable switches, but remove both per-key storage
alternatives: analyzer FileByteStore selection/readiness scanning and
AssetDepsCache JSON read/write/filename-key encoding. Shared analyzer and
directive caches always use packed storage. Remove PACKED_STORE; old values
are ignored like other unknown environment names. BYTE_STORE=0, DEP_CACHE=0
and a fresh CACHE directory provide diagnosis/recovery, and corrupt entries
remain misses. The extra storage implementations are not needed for these
recovery paths. Old per-key directories remain untouched and are never selected.
Keep opt-in analysis experiments disabled by default. Internal transport and
artifact overrides are development mechanisms, not stable user API.

Manifest v9 drops flattened mappings and their reader. Only explicit extensions
or post-process input_extensions describe mappings. A cached manifest that
cannot be parsed or validated is regenerated. Required mapping fields and the
configured package-root/order bits and explicit options/filter/optional metadata
are not inferred from older messages. An invalid
or obsolete graph is diagnosed and rebuilt from empty; filesystem IO errors
remain errors. No migration path deletes user sources or existing outputs.
Only normal successful action commit may replace outputs. Old storage outside
the selected namespace remains untouched.

Manifest, graph, generator/probe cache, worker AOT/kernel, SDK summary and
analysis cache formats are not stable API. Identity validation, format versions
and content digests may invalidate them on updates. Recovery recomputes state;
there is no guarantee to migrate a previous release's entries. Removing the
per-key alternatives leaves their earlier 0.x directories unused.

## Worker and IPC boundary

The workspace-specific Dart worker is an internal package component, generated
by the package. Third-party worker implementations are not a supported
extension point. Keep `--worker` as an internal artifact override for repository
tests, benchmarks and diagnostics, without a public compatibility guarantee.

The generated worker, package runtime and native frontend must have exactly the
same accelerator package version. Internal worker overrides pass the same
checks to catch stale artifacts and malformed test messages. `initialize` and
`initialized` exchange the required `accelerator_version`, compared with the runtime package constant and
native Cargo package version. Initialization reply IDs must match. Release
artifact metadata continues to validate the frontend distribution separately.
Capabilities remain mandatory; matching versions do not establish message
validity. Both receiving endpoints reject missing/mismatched wire `v`.

Retain wire protocol v1: frame layout, binary encoding, operations and visibility
semantics are unchanged. This is a release-coupled protocol, not an independently
versioned cross-release API. The new handshake deliberately rejects older v1
workers lacking version identity, even when they advertise capabilities.
A future incompatible frame layout would require a new protocol decision and
number. These checks protect internal package communication; they do not
establish a third-party integration contract.

All current producers send build kind, allowed_outputs, options, phase,
instance_key, is_root and triggers and initialize phase_count. Make these
required and type checked (including workspace and batch context). Build-result
dependency/deletion lists and batch dep_graph are also required instead of silently selecting old defaults.
Batch children inherit only the documented blocked_assets field. Required
binary capabilities and reset overlay validation are retained. See
[protocol/v1.md](../../protocol/v1.md).

## Consequences and validation

Updating a workspace from an earlier 0.x release may incur a cold build;
no cache migration is promised.
The package regenerates its worker as needed; internal artifact overrides must
be refreshed or removed when updating. Old CLI calls
fail explicitly with a replacement command. Historical changelogs, measurements
and prior ADR evidence remain history; this decision supersedes their contract
claims where indicated.

Tests cover current producers, missing fields/version identities, obsolete
manifest mappings, invalid graph recovery, cache isolation, and stock output
comparisons after regeneration. Release version bumps remain tagpr's task.
This cleanup applies to the continuing 0.x development line; the eventual 1.0
API and release timing remain separate decisions.
