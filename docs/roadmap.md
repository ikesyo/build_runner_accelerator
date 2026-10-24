# Roadmap

Open work toward the 1.0 release. Implemented behavior belongs in the
[compatibility contract](launcher-and-release.md), [fixture inventory](compatibility-probes.md)
and [ADRs](adr/README.md). This page does not establish that a release has run.

The mixed-application benchmark with default workers and three repeats is
complete; see [results and replay](benchmarks.md).

## First-release gates

Signing setup and tagged publication are operational: the
[v0.16.0 release run](https://github.com/ikesyo/build_runner_accelerator/actions/runs/40005469094)
passed production signing, five-target packaged E2E, final signed-artifact
verification and GitHub Release/pub.dev publication.
The [main CI run at d6e77de](https://github.com/ikesyo/build_runner_accelerator/actions/runs/40108128620)
also passed all five packaged-distribution lanes and both minimum/current
SDK Resolver lifecycle checks, retaining the distribution artifacts.

Remaining initial validation:

- [ ] Exercise the Artifact Attestation steps added after v0.16.0 in a real
  release workflow: producer/manifest OIDC attestations, pre-publication
  verification, and downloaded published-asset verification before pub.dev.
  See [the remaining checks](distribution-validation.md#next-release-checks-requiring-github).

For each release candidate, require successful correctness and five-target
packaged-distribution evidence for that exact commit. Earlier successful runs
establish that the pipeline works; they do not certify a later candidate.
Use [distribution validation](distribution-validation.md) for replay and evidence.
SDK/dependency checks and packaged-distribution E2E are separate gates; a
complete platform × SDK × dependency matrix is not required for 1.0.

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
