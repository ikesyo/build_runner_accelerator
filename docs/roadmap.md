# Roadmap

Open work toward the 1.0 release. Implemented behavior belongs in the
[compatibility contract](launcher-and-release.md), [fixture inventory](compatibility-probes.md)
and [ADRs](adr/README.md). This page does not establish that a release has run.

## First-release gates

- [ ] Validate Artifact Attestation in a real release workflow: producer and
  manifest OIDC attestations, pre-publication verification, and downloaded
  published-asset verification before pub.dev.
  See [the validation steps](distribution-validation.md#next-release-checks-requiring-github).

Routine candidate checks and publication procedures are maintained in
[distribution validation](distribution-validation.md).

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
- [ ] Close accelerator's remaining Pub workspace compatibility gaps with
  stock build_runner: workspace watch, build filters, output policies, named
  configurations and `--define`. These are accelerator limitations, not stock
  runner limitations. Validate cross-package invalidation, output selection,
  no-op reuse and failure/recovery against stock before enabling each combination.
- [ ] Expand workspace builder coverage to optional producers, shared-library
  parts and trigger-only builders, and support overlapping nested source sets
  and safe individual/workspace state transitions. Preserve transactional
  publication and validate each boundary against stock; see the current
  [workspace subset](launcher-and-release.md#workspace-builds).
- [ ] Expand the validated `build.yaml` and post-process subsets,
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
