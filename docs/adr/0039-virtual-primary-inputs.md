# ADR 0039: Virtual primary inputs

- Status: Accepted
- Date: 2026-10-21

## Context

Stock build_runner supplies `$package$`, `lib/$lib$`, `test/$test$`, and
`web/$web$` as virtual primary inputs for every package. Builders use their
names as ordinary input suffixes to declare fixed output paths. These IDs
participate in planning even though they are unreadable and are not files.
A filesystem-only snapshot cannot schedule those actions or retain their
primary dependency across incremental builds.

## Decision

Add the four stock virtual IDs to each scanned package's planning snapshot,
independently of physical source files. Give them stable primary-input evidence
with no readable content. Apply the usual target sources, `generate_for`, phase,
action identity, demand, output validation, deletion, and all-success commit
rules to actions using these primaries.

Normalize their documented input tokens as suffix mappings with literal output
paths. Do not translate them into exact matches: an ordinary filename ending in
the same token still uses suffix replacement. Anchored exact mappings retain
their existing meaning. The all-asset mapping can match virtual inputs just as
it matches other primary candidates.

Block reads of the four reserved IDs in the shared phase-aware asset view.
`canRead` returns false, reads fail as missing, and virtual identities are not
filesystem candidates for globs. Snapshot existence records the availability
of a primary identity, not the availability of bytes.

Reject eligible physical sources at the reserved paths before actions. Stock
can enumerate such sources despite their unreadability, and their deletion can
remove virtual-action outputs depending on prior graph classification. That
source/placeholder alias transition is outside the supported model; do not
silently treat a physical alias as a stable virtual identity.

Reject declared outputs at the reserved virtual paths before actions. Such
outputs are outside the supported subset; an action must not materialize or
replace a virtual primary. Normal generated outputs continue through the
existing source/cache overlay and phase visibility rules.

Invalidate old private graph input semantics through the configuration digest
domain. No IPC fields or graph serialization structures change.

## Rationale

Keeping virtual primaries in the shared input model preserves stock suffix and
scope semantics without per-builder branches or fabricated source files.
Separating primary existence from readability lets dirty checking remain stable
while all worker reads continue through the same visibility boundary. Existing
transaction rules then cover fixed-output aggregates and their failures without
a separate publication path.
