# Roadmap

Open work for the pre-release line. Implemented behavior belongs in the
[compatibility contract](launcher-and-release.md), [fixture inventory](compatibility-probes.md)
and [ADRs](adr/README.md). This page does not establish that a release has run.

The mixed-application benchmark with default workers and three repeats is
complete; see [results and replay](benchmarks.md).

## First-release gates

The workflow implements same-commit correctness gates, locked builds/tests,
five-target signed-artifact E2E, and GitHub Artifact Attestation verification
before Release publication and again before pub.dev. SDK minimum/current
Resolver lifecycle checks are also implemented. Remaining operational gates:

- [ ] Configure the production release signing secret and publish a tagged test release.
- [ ] Retain successful five-target packaged-distribution evidence for the
  candidate commit from CI, a release run or a workflow dry-run.
- [ ] Retain successful Actions OIDC/attestation evidence and published-asset
  verification from the candidate release.

Use [distribution validation](distribution-validation.md) for workflow replay,
signing requirements and evidence. Local Linux success cannot establish the
other platforms or GitHub OIDC/publication behavior. SDK/dependency checks and
packaged-distribution E2E are separate gates; a complete platform × SDK ×
dependency matrix is not required for 1.0.

## Distribution after 1.0

- [ ] Add macOS Developer ID signing and notarization.
- [ ] Add Windows Authenticode signing.

Neither is configured in the current workflow. Attestation verifies provenance,
not OS signing or Gatekeeper/SmartScreen approval. See
[platform evidence and limits](distribution-validation.md#platform-facts-and-unverified-minimums).

## Compatibility

- [ ] Resolve the published Conduit dependency conflict: generators requiring
  Analyzer 12 cannot use the native Analyzer 13.3+ window. Keep the validated
  registry fixture's Analyzer override distinct from ordinary package support.
- [ ] Validate additional web compiler configurations: DDC hot reload,
  library bundles/frontend server, nondefault flags, dart2wasm,
  release/deferred outputs, the dev extractor's exposed `.deps`, cold
  script-worker watch and multi-package workspaces. Existing dart2js/DDC
  fixtures cover only their documented configurations; retained compiler
  archives are not raw-byte identical.
- [ ] Expand the validated `build.yaml`, post-process and workspace subsets,
  preserving explicit rejection outside them.
- [ ] Validate additional mixed builders and multi-package real projects beyond
  the pinned single-root FVM probe.
- [ ] Compare conditional import/export dependency selection with stock before
  changing invalidation rules.

Exact validated versions, configurations and blockers are maintained in the
[compatibility inventory](compatibility-probes.md) and linked fixture guides.

## Performance and protocol research

- [ ] Evaluate chunked results for outputs beyond the protocol v1 frame limit.
- [ ] Re-evaluate indexed/lazy graph persistence and automatic worker counts
  using reproducible benchmarks.
- [ ] Validate resolver-aware batching in larger mixed-builder workspaces.
- [ ] Consider builder-specific fast paths only with a measured advantage over
  the generic manifest path under identical conditions.

Use the [development verification guide](development.md) and
[benchmark method](benchmarks.md#measurement-notes). Compatibility probes alone make no
performance claim; small targets can be dominated by startup and IPC costs.
