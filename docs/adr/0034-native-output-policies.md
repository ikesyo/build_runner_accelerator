# ADR 0034: Native output policies at the transaction boundary

- Status: Accepted
- Date: 2026-10-17
- Amends ADR 0002, ADR 0029, and ADR 0032.

## Decision

Implement build_runner 2.16.2's `--only-check` and
`--keep-modified-outputs` for one-shot builds in the existing normal-builder
filtered-demand subset. An unfiltered policy build demands every declared
output using the same evaluator. Multiple-output actions, dependent builders,
source/cache outputs, and supported build filters use the same phase, reuse,
and deletion rules. Policy flags are runtime inputs, excluded from manifest
configuration identity. They do not change BuilderOptions. Protocol v1 gains an optional internal
worker initialization guard and capability.

Both flags are non-negatable; repeated identical flags are accepted. Specifying
both is a stock usage error, not a precedence rule. Auto/dart delegate invalid
stock syntax to stock with the original invocation; rust rejects it before
setup. The retired deletion flag and `-d` remain accepted no-ops.

## Verification

After all demanded actions succeed, compare the transaction's final source-path
writes/deletions with disk. Missing/new outputs produce `M`, incorrect bytes
produce `I`, and existing outputs scheduled for deletion produce `U`. Sort and
report `Verify failed due to Incorrect|Missing|Unexpected:` and fail with status
1 on any difference. Source-path conflicts with cache outputs are also checked.
Artifact-tree outputs are not compared. No output, intermediate artifact, or
graph is published on either successful or failed verification. Manifest,
compiled-worker, analyzer, and other setup caches may still be prepared.

The in-memory graph used during verification is disposable. A later normal
build reads the last committed graph, so uncommitted results cannot be reused
as if they were reflected on disk. A no-work verification follows this same
boundary and does not save graph metadata. Ordinary dirty analysis also handles
files at declared but previously omitted outputs, so the following normal build
can remove conflicts that verification deliberately left untouched.

## Keeping modifications

Keep is a reuse policy, not a veto on commit writes. Existing generated files
are retained with their previous logical digest even when their bytes differ.
Reads serve the real retained bytes; dependency comparisons use the previous
digest. A missing output invalidates its producer. Input/configuration changes
can rerun the producer and overwrite modified sibling outputs. Removed inputs
or newly omitted outputs delete their old files, including manual modifications.

Persist the logical snapshot of retained outputs separately from actual bytes,
using existing action digests and snapshot metadata; never bless manual bytes
as newly generated content. Rebuilt outputs receive new digests only on a
successful transaction commit. Switching to overwrite or verify detects those
retained modifications against the generated digests. Private graph format 3
adds `retained_output_state`: subsequent ordinary builds use demand evaluation
until the private graph is discarded. Repairing a producer to identical logical
content must not rerun a consumer that previously read retained manual bytes;
such legitimate consumer results can survive multiple ordinary builds. This
marker changes reuse, not output policy: ordinary builds still repair manually
modified outputs. Formats 1/2 load with the marker false because they predate
native keep support. Watch from this state routes to stock before actions,
including after an ordinary build; prewarm does not consume the state.

## Retained bytes and worker APIs

Stock also exposes the old MD5 through `BuildStep.digest`, even while reads
return retained manual bytes. Native reuse hashes do not encode that MD5, and
resolver content/cache semantics cannot be assumed equivalent. When keep finds
modified recorded outputs, initialize opts into `retained_output_guard` and
requires `retained-output-guard-v1`. A stale worker lacking this capability is
unsupported before actions. Clean/unmodified API use remains native.

Guarded digest/resolver API use latches an unsupported result even if a builder
catches the exception and writes a fallback value. Rust discards the complete
transaction. Auto retries the complete original stock invocation after workers
are dropped; rust errors with no output/graph publication. This is runtime
capability routing, not a JSON alternative to the binary protocol.

After runtime auto fallback, any late fallback with native retained history,
or invoking a publishing stock build/watch from native retained history
(including explicit dart mode), a private `stock-output-policy-state` marker
keeps subsequent build/watch commands on stock in auto and makes rust explicit
about the unsupported history. Stock can now hold logical digest history that
cannot be imported into the previous native graph. The launcher checks this
marker before native acquisition, and the binary checks it before manifest
preparation. The native graph and generated artifact cache are not rewritten
by the discarded attempt. Fallback uses stock's own graph; without one, stock
performs its normal cold build, including regenerating existing files. We do
not import native graph history into stock. Reset both disposable build states using the recovery
guide before requiring native again; prewarm does not consume this marker.
The launcher reads format 3's validated header/trailing history byte without
loading the whole graph. It can also route retained-history watch before binary
acquisition. A read-only stock verify/help invocation does not claim ownership.

## Compatibility boundary

Native watch with either policy is unsupported and routes before native
acquisition or manifest generation. Stock's resident keep event filtering and
verify's in-memory state after a failed verification need separate lifecycle
validation before enabling native watch. Prewarm rejects these build-only flags.

Optional, post-process, trigger-only and zero-output builders, unsupported filter
syntax, cyclic resolver reuse, and configuration changes from recorded policy
state route the whole request to stock in auto and error before actions in rust. Late fallback retains both
policy and compile-mode flags. Dart always runs stock.

All-success commit remains stronger than stock's partial publication after a
builder failure. Cancellation during actions leaves outputs and graph unchanged.
The existing commit sequence remains **not crash-atomic**: interruption or I/O
failure after filesystem commit begins can leave changed files with the old
graph. This change adds no rollback journal or crash durability guarantee.

## Evidence and validation

The supported version window remains `>=2.16.2 <2.17.0`. Upstream evidence:
`build_runner_command_line.dart` (`outputStrategy`, flag definitions),
`build_plan/output_strategy.dart`, `build_plan/build_plan.dart` (retained bytes
with old digests and invalid missing outputs), `build/build.dart` (step reuse),
and `build/build_series.dart` (verification, deletion, graph persistence, watch
filtering). These private APIs are version-specific compatibility evidence.

`scripts/correctness_output_policies.sh` uses the tracked `build_filter_app`
fixture, whose inputs control bytes, omitted outputs, and failure. It compares
stock/native output bytes and existence, intermediate artifacts, diagnostic
categories, exit codes, graph immutability during verify, normal-build recovery,
keep/restart transitions, filters, multi-output chains, failure, and Ctrl-C
before commit. CLI tests compare official stock parsing and exercise lossless
early/manifest/runtime fallback and compile modes. Watch policy requests test routing;
watch execution remains stock-owned.
