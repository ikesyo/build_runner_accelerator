# ADR 0030: 1.0 contracts and disposable accelerator state

- Status: Accepted
- Date: 2026-10-08
- Amends ADRs 0001–0004, 0024, 0026, 0028 and 0029.

## Decision

Stock build_runner configuration, BuilderOptions, expected-output mapping,
resolver visibility, resource lifetime and transactional output behavior remain
our compatibility reference. The auto/rust/dart selection policy is unchanged.
Compatibility with accelerator 0.x commands and internal storage is not required.

The supported CLI and environment classifications are listed in
[the migration guide](../migration-1.0.md). Remove the `aot-prewarm` alias at both
launcher and native parser boundaries, including Dart mode; use `prewarm`.
Keep diagnostic cache-disable switches and the per-key store alternative:
these isolate publication/index failures without deleting generated outputs.
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
there is no guarantee to migrate a previous release's entries. The per-key
analysis alternative uses a new namespace to avoid reusing 0.x state.

## Worker and IPC boundary

Custom workers, package runtime and native frontend must have exactly the same
accelerator package version. `initialize` and `initialized` exchange the
required `accelerator_version`, compared with the runtime package constant and
native Cargo package version. Initialization reply IDs must match. Release
artifact metadata continues to validate the frontend distribution separately.
Capabilities remain mandatory; matching versions do not establish message
validity. Both receiving endpoints reject missing/mismatched wire `v`.

Retain wire protocol v1: frame layout, binary encoding, operations and visibility
semantics are unchanged. This is a release-coupled protocol, not an independently
versioned cross-release API. The new handshake deliberately rejects older v1
workers lacking version identity, even when they advertise capabilities.
A future incompatible frame layout or independently supported worker release
would require a new protocol decision and number.

All current producers send build kind, allowed_outputs, options, phase,
instance_key, is_root and triggers and initialize phase_count. Make these
required and type checked (including workspace and batch context). Build-result
dependency/deletion lists and batch dep_graph are also required instead of silently selecting old defaults.
Batch children inherit only the documented blocked_assets field. Required
binary capabilities and reset overlay validation are retained. See
[protocol/v1.md](../../protocol/v1.md).

## Consequences and validation

Updating from 0.x may incur a cold build; no cache migration is promised.
A custom worker must be rebuilt against the selected package. Old CLI calls
fail explicitly with a replacement command. Historical changelogs, measurements
and prior ADR evidence remain history; this decision supersedes their contract
claims where indicated.

Tests cover current producers, missing fields/version identities, obsolete
manifest mappings, invalid graph recovery, cache isolation, and stock output
comparisons after regeneration. Release version bumps remain tagpr's task; this
change defines the 1.0 boundary without publishing a 1.0 release.
