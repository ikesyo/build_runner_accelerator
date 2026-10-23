# ADR 0042: Isolated runner resolver compatibility

- Status: Accepted
- Date: 2026-10-23

## Context

Runners 2.15.3, 2.16.0 and 2.16.1 permit Analyzer 13.3 through 14.x, but their resolver cannot compile
with Analyzer 14.5 after removal of an internal setter (dart-lang/build#5197).
The worker implements its own correct analysis options, yet imports enough
runner internals to compile that upstream resolver transitively. Raising the
runner floor to 2.16.2 also raises the effective Analyzer floor to 14.3.
Users need older Analyzer support without separate package releases or artifacts.

## Decision

Support runner `>=2.15.3 <2.17.0` and Analyzer `>=13.3.0 <15.0.0` in one release
line. For runners 2.15.3, 2.16.0 and 2.16.1, prepare a content-keyed private copy of the
library, pubspec and license, applying only the #5197 AnalysisOptionsBuilder backport.
Reject unexpected patch shapes. Preserve Pub's original package and the
application's package configuration and lockfile.

Use a separate compilation package configuration for all generated Dart code:
manifest generator, trigger/factory helpers, worker source/kernel/AOT and
analysis prewarm. Include the effective package resolution and source content
in existing cache identities; remove the selection on a newer-runner transition.
Validate copied source before use and publish complete directories from staging.
Compatibility state is disposable setup state, including during `--only-check`.
Builder-visible assets and resolver package roots retain the original application
resolution; the copied sources are compiler inputs only.
No stock runner is launched by the accelerator and no stock installation is
repaired. The native protocol and output transaction boundary do not change.

Keep one package/tagpr flow and the existing five Rust artifacts. Add mixed
resolution correctness checks inside an existing CI lane; do not add manual
release steps or version-specific publishing. Minimum/latest Dart jobs retain
their existing SDKs and downgrade/upgrade strategy.

## Consequences

Analyzer 13.3 becomes usable again. Known-broken stock 2.16.1/14.5 can run through
the accelerator; comparisons use fixed stock 2.16.2 with the same Analyzer.
Keep remote source ownership and committed snapshots in the worker's minimal
filesystem adapter. Seed a concrete upstream BuildState for Analyzer bootstrap
and updates, selecting its positional/named constructor once per isolate with
typed constructor tear-offs. Its ordinary contentOf implementation handles
per-asset lookups directly; do not put an Invocation/noSuchMethod bridge on
that path. The seed state contains committed outputs, while the remote package
namespace and source-read bookkeeping remain separate. Unsupported constructor
shapes and unknown filesystem APIs fail explicitly. ReaderWriter supports both
location parameter spellings while Rust owns visibility.

Select 2.15.3's default keep-modified policy through an internal version-derived
flag in build/watch. Do not turn it into the explicit demand-mode CLI flag:
ordinary generators with post-process cleanup must retain their existing route.
Keep original digests for retained bytes and regenerate missing outputs.
`-d` remains retired throughout the supported window. Retain the existing conservative
digest/resolver guard if an unrelated edited output survives; failure must not
publish outputs or graph changes. Clear that guard only for edited outputs
whose primary inputs changed. Do not persist implicit legacy selection as an
explicit demand-state transition: upgrading the runner restores its new default.
The dependency comparison covers legacy retention, restart, regeneration,
watch and upgrade in the same release line.
The backport is a deliberately bounded private-source compatibility surface;
additional fixes require explicit evidence rather than opportunistic text edits.
See the [review and verification command](../dependency-window-review.md).
