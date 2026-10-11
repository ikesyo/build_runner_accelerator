# ADR 0032: Native build-filter demand and output state

- Status: Accepted
- Date: 2026-10-10
- Amends ADR 0029 and ADR 0031; extends the private state contract in ADR 0030.

## Context

Stock build_runner 2.16.2 selects non-optional steps when any declared output
matches a filter, then builds generated primary inputs and generated assets
read by those steps on demand. It does not filter the allowed outputs of a
step. The previous build state, conflicting outputs and process/session boundary
also affect deletion. A path-only action or final-output filter cannot reproduce
these rules.

## Decision

Keep the complete phase-aware action/producer graph. Filters select eager roots;
normal producers execute through the existing resident worker's recursive asset
RPC demand path. Primary-input demand precedes reuse checks. Reuse evaluates
the ordered stock InputTracker inputs, then globs and resolver dependencies,
against actual dependency results. A changed generated primary does not bypass
old input checks; once a checked input requires execution, new reads determine
further demand. Shared
producers and all siblings of a multiple-output action execute once per build.
A reused producer also hides declared siblings it did not generate, preventing
stray files from satisfying a generated dependency or a glob.
Single binary build results add `dep_graph` metadata using the same reachable,
deduplicated resolver graph as batch results. The demand client merges nested
single graphs before committing and requires this metadata for filtered builds;
missing evidence fails the transaction rather than permitting unsafe reuse.
Existing readers ignore this additive metadata. Batch graph emission is unchanged.
All binary action results add `stock_inputs` in official InputTracker iteration
order, separately from broad observed `reads`. Glob and resolver-entrypoint
tracking retain their stock order. Filtered execution requires ordered evidence;
ordinary execution continues using its existing broader dependency fields.
Action results also record complete actual glob membership, including when a
builder only consumes part of the stream. Reuse compares membership rather than
bytes. Plain sources precede earlier-phase generated outputs, with each group
sorted using Dart's UTF-16 asset-ID order. Membership is persisted per action
and glob, preserving different phases' views of the same pattern.
Ordinary asset RPC uses the same listing order so an unfiltered build supplies
valid evidence for filtered reuse without rerunning membership-only builders.
The private binary graph writes format 2 with actual-output locations and ordered
stock inputs and glob membership. Format 1 can still be read by ordinary builds, but filtered builds
with actions lacking ordered evidence route to stock. Configuration transitions removing prior builder
applications or output declarations also route to stock before actions, because
source reclassification requires additional stock lifecycle work. Source/cache
location changes with recorded state remove old physical outputs using the old
location, including conflicts in the opposite output tree. Other configuration
changes without stock plan-compatibility evidence route to stock.
Stock's `InBuildPhase.identity` includes `outputsToArtifactTree`, so a recorded
source/cache transition proves that the previous stock plan cannot be reused;
unrelated option-only changes do not supply this evidence.
Canonical parsed release/config flags and original define values form configuration identity;
filters, AOT/JIT artifact selection and retired deletion flags do not.
No deletion infers
previous location from path existence.
Failures retain the existing all-success output/graph commit boundary.

Persist only evaluated actions in the successful incremental state. A still
declared but undemanded normal output from a compatible previous build can
remain on disk for that build. On a subsequent process/watch restart, a declared
file absent from that state is a conflicting output and is removed unless
actually generated or reused. Continuing watch builds do not rescan unchanged
such files as new conflicts; a new or modified unrecorded package-path output is
a conflict. Restoring an input can also reclassify an unchanged unrecorded
file as a generated-output conflict during watch. Filtered watch accepts external
writes even when their names match generated-output suffixes. It suppresses
writes matching committed actual-output bytes rather than every
generated-looking write, so external edits reach demand and conflict
reevaluation without incidental unrelated events. Removed producer declarations
caused by input deletion use the ordinary graph
deletion path. Cache-built declared outputs also remove conflicting package-path
files. Clean plans replace the entire artifact tree on successful commit,
including unselected or no-longer-declared cached files. Compatible incremental
restarts classify unrecorded declared cache files as conflicts.
The private graph also carries watch source classification. An unchanged,
formerly declared source-path output does not become a plain source just because
its producer input is deleted. Retain this exclusion across continuing builds
and clear it on restart. Changes to still-declared unrecorded outputs can
reclassify them even when bytes are unchanged; use event paths as well as the
snapshot. Stock ignores modifications/removals of unknown, no-longer-declared
assets; only an ADD can introduce them as new sources during the same watch.
Artifact-tree scans on restart also classify unrecorded files with no remaining
output declaration as conflicts; package-path files require a declaration.
Undeclared artifacts without a corresponding plain source are never exposed
as readable sources, independently of whether physical cleanup is due yet.
Filtering is runtime demand and is excluded from manifest/worker/config
identity; it cannot cause reuse of an unevaluated action.

The native CLI subset supports repeated and comma-separated values (OR), root
relative paths, `package:` paths relative to lib, and `asset:` paths relative to
the package root. Package names may contain `*`. Path globs support `*` and whole
`**` segments. URI query/fragment/percent syntax, escaping, non-ASCII, classes,
braces, `?`, absolute and dot-segment paths use stock. Reject empty/missing values
through the ordinary early capability route, preserving stock diagnostics/status.
`--` continues to stop accelerator parsing and routes to stock.

Filtered manifests containing optional, post-process or zero-declared-output
builders, or `run_only_if_triggered`, route as a whole to stock in auto and fail explicitly in rust. This
boundary is checked after manifest validation, before build actions.
Package-path conflicts with declared dependency outputs also route before
actions, preserving stock's dependency-conflict error rather than deleting
files in another package.
In stock, optional builders are demanded rather than selected eagerly, while post-process
builders operate on actual normal outputs and sources without the ordinary
output filter. Extending this subset requires separate lifecycle comparisons.
Initial resolver builds support cycles through actual reads; incremental filtered
reuse of a recorded cyclic resolver graph routes to stock before actions.
The native acyclic graph evaluator visits children first and evaluates the entire
reachable graph, matching stock's eager subgraph checks. Stock's library-cycle
member ordering requires additional evidence before incremental cycles can be supported.

All fallback routes retain original spelling/order and force-AOT/JIT flags.
Unsupported lexical syntax routes before native acquisition or manifest creation.
Dart always uses stock. Filters are build/watch-only; prewarm retains its rejection
of stock build-only arguments. Existing settings options remain supported.

## Evidence and consequences

The stock sources are `build_plan/build_filter.dart`,
`build_runner_command_line.dart` (`addMultiOption`), `build/build_dirs.dart`,
`build/build.dart` (`_matchingPrimaryInputs`, `_buildOutput`, `_computeStepAction`,
`_runPostBuildAction`) and `build/build_series.dart` (`_computeDeletes`,
`_writeBuildOutput`), together
with `build_plan/build_plan.dart` (`_createIncremental`,
`withCompatiblePreviousBuild`). These belong to the supported version window,
not a stable public API.

`scripts/correctness_build_filter.sh` compares bytes, existence/deletion, exit
codes and real builder history in isolated stock/native workspaces, including
chains, siblings, secondary shared dependencies, incremental transitions and
watch restarts. Unsupported optional/post-process combinations use stock
comparisons and strict-mode rejection. Parser/routing regressions protect the
lossless early and late fallback vector.

Demand execution is serialized on one resident worker, like existing nested
optional execution. It trades parallelism for correct dependency discovery;
normal unfiltered execution retains its current scheduler.
