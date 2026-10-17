# ADR 0034: Native output policies at the transaction boundary

- Status: Accepted
- Date: 2026-10-17
- Amends ADR 0002, ADR 0029, and ADR 0032.

## Decision

Implement build_runner 2.16.2's `--only-check` and
`--keep-modified-outputs` for one-shot builds using the existing normal-builder
filtered-demand evaluator. Without a filter, demand every declared output.
Policies do not affect manifest identity or BuilderOptions. The
[CLI reference](../launcher-and-release.md#output-policies) defines flag syntax,
command support and fallback boundaries.

## Verification at commit

After all demanded actions succeed, compare the transaction's final package-path
writes/deletions with disk, including conflicts at cache outputs' package paths.
Report stock's sorted `I`/`M`/`U` diagnostics and exit 1 on differences.

Verification publishes no generated files, intermediate artifacts or graph,
including on success and no-work builds. Artifact-tree differences are not
compared; setup/compilation caches may change. The next ordinary build reads the
last committed graph and applies uncommitted changes normally. Its dirty analysis
also handles files at previously omitted outputs that verification left intact.

## Retained bytes and reuse

Keep preserves existing manual bytes with the previous generated digest. Reads
serve real bytes; dependency comparisons use the logical digest. Missing outputs
invalidate their producer. Rerunning a producer can overwrite modified siblings;
omitted outputs and deleted inputs remove old files, including manual edits.
Commit preserves the logical snapshot of untouched outputs and records new
digests only for successfully rebuilt outputs.

Private graph format 3 records `retained_output_state`. Subsequent ordinary builds
continue demand evaluation even after repairing upstream files: a consumer that
previously read retained bytes must remain reusable when the producer regenerates
identical logical bytes. This marker changes reuse, not the output policy.

Only the current private format is read. As specified by ADR 0030, obsolete or
malformed graphs reset to a native cold build without migrating history or
removing existing files. Verification and failed actions leave the old graph
intact; a successful publishing build replaces it.

## Worker API boundary

Stock exposes the old MD5 through `BuildStep.digest` alongside retained manual
bytes. Native reuse hashes cannot supply that MD5, and resolver cache equivalence
is unproven. When keep finds modified outputs, enable `retained_output_guard` and
require `retained-output-guard-v1`; see [protocol v1](../../protocol/v1.md).
Clean/unmodified API use remains native-compatible.

Guarded digest/resolver calls latch an unsupported result even when the builder
catches the exception. Discard workers and the complete transaction before auto
retries the original stock invocation; rust errors without publication.

## Stock ownership

Stock's logical digest history cannot be imported into an older native graph.
Before stock keep or a publishing stock transition from native retained history,
record `stock-output-policy-state`. This includes runtime/late fallback and
explicit dart builds or watches. Later auto build/watch commands stay on stock;
rust errors until both disposable states are reset using the
[recovery guide](../compatibility-cleanup.md#safe-recovery).

Check this marker before native acquisition or manifest preparation. For
retained-history preflight, the launcher accepts only fully validated current
format/schema graphs. Native selection, transition checks, execution and fallback
share one graph load per attempt. Stock uses its own graph, including cold-build
semantics when absent; discarded native attempts publish nothing.

Read-only verify/help does not claim ownership. Once claimed, ownership persists
until explicit recovery, including after usage errors: another stock invocation
may already have adopted the claim. Prewarm does not inspect output-policy history.

## Failure and validation

Keep the existing all-success commit boundary: builder failure or interruption
during actions leaves native outputs and graph unchanged. Stock can publish
partial results on failure. Filesystem commit remains non-crash-atomic as defined
in ADR 0002; this change adds no rollback journal.

The supported version window remains `>=2.16.2 <2.17.0`. Stock evidence comes from
`build_runner_command_line.dart`, `build_plan/output_strategy.dart`,
`build_plan/build_plan.dart`, `build/build.dart` and `build/build_series.dart`.

`scripts/correctness_output_policies.sh` compares stock/native bytes, existence,
diagnostics, status and subsequent builds using the input-controlled
`build_filter_app` fixture. Coverage includes policy transitions, filters,
source/cache multi-output chains, failure, interruption before commit, lossless
fallback and compile modes. Watch policies test delegation; native watch support
requires separate validation of stock's resident event/reuse behavior.
