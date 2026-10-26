# ADR 0043: Native shared-library parts

- Status: Accepted
- Date: 2026-10-25

## Context

Runner 2.17 introduces `adds_to_library`: shared outputs, phase-specific
resolver contents, and automatic source part-directive edits. Supported
versions are listed in the
[compatibility contract](../launcher-and-release.md#supported-dependencies).

## Decision

Model shared contributions separately from ordinary declared builder outputs.
Persist each action's upstream-formatted and escaped header/import/source
sections in graph schema 7. Give the final shared output one graph owner, the
last contributing action for that library. Its visibility begins after the
first contributing phase. Reconstruct each phase's accumulated content using
both reused and newly executed contributions, with no stock subprocess.
Represent a contribution change as a phase-visible resolved-library dependency,
in addition to its shared-part asset. Invalidate later resolver consumers through
their recorded entrypoints and dependency graph, preserving unrelated actions.
Directive edits are ordinary source changes visible to every phase; replay uses
the current transaction's read edges and invalidates only affected optional
producers, which still run only on demand.

Index contributors and final owners once in `SharedLibraryPlan`. The phase
coordinator reconstructs a library only when its visible contributor count
changes and publishes only libraries with fresh contribution evidence. Staged
actions and outputs replace earlier results by key rather than accumulating
intermediate passes. Keep the persisted contribution separate from transport
metadata and per-library source-edit evidence; consume that evidence before
replay so watch state cannot retain handwritten source copies.

Generate a typed shared-step factory and codec only for shared-part catalogs.
Those workers compile the resolved runner's constructor, accumulator, codec,
and PartDirectives APIs. Ordinary workers keep their typed constructor path
and never compile the new interfaces. Read build_config's new flag once per
definition; remember legacy types after the first missing-getter exception.
There is no Function.apply in BuildStep construction. Experiments supplied via
`--enable-experiment` wrap generated worker execution in withEnabledExperiments.

Carry optional `part_phase_index` and `shared_part` metadata in protocol v1,
requiring `shared-library-parts-v1` for selected shared builders. Rust, rather
than the builder, owns the extra shared output. Use reset overlay blobs even
for one worker when content originates in Rust: worker memory does not contain
Rust-assembled parts or source edits.

Stage source edits in the existing transaction, check their original bytes
before publication, and journal them with generated outputs and graph. Replay
affected execution against the edited overlay before committing. Reject
non-stabilizing directive updates after eight replays. Deduplicate replayed
writes so recovery sees only the final expected bytes. `--only-check` compares
these source mutations without publishing them. Generated libraries remain
owned by their producing builder and are never edited automatically.

## Supported boundary

Support multiple contributors, ordinary outputs alongside contributions, empty
contributions, source language overrides, nested/non-lib paths, enhanced-parts
imports (imports without source are ignored, as in stock), failure/recovery, and resident watch. Source input additions, deletions and renames are supported with downstream
normal builders, including resolver consumers. Filtered builds and explicit retained-output policy with shared
builders are rejected before actions.
Trigger-only shared builders and post-process deletion of a shared library's
primary input are also outside this boundary.

## Stock reference correction

Stock 2.17.1 caches phase-specific accumulated content. `addContribution`
invalidates the final content but leaves later phases in `_contentsByPhase`.
After an input-set change, a normal resolver can consequently observe only the
first contributor although the final shared part contains both contributors.
The accelerator invalidates and rebuilds phase contents; reproducing this
missing-output defect is outside the compatibility guarantee.

The correctness probe defaults to an isolated stock source copy with one cache
invalidation line added before recording a contribution:
`_contentsByPhase.removeWhere((cachedPhase, _) => cachedPhase >= phase);`.
It records original/corrected hashes and the exact correction in
`stock-reference.json`. Only the stock workspace's package configuration points
to this copy; neither Pub cache, lockfile, native package configuration nor
runtime is patched. `--stock-reference raw` reproduces the unmodified comparison.
For every addition, rename and deletion, a third, clean workspace runs
unmodified stock and must match the native file inventory and bytes. This
separates intended output parity from the upstream incremental cache defect.

## Validation

The [shared-part fixture](../../fixtures/shared_parts_app/README.md) defines the
stock/native lifecycle comparison, run in the existing minimum/current SDK jobs.
