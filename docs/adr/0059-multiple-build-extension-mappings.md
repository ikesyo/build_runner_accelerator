# ADR-0059: multiple build-extension mappings in the generic manifest

- Status: accepted
- Date: 2026-09-05

## Context

`build_config` represents a builder's `build_extensions` as a map, so one
builder can declare several input patterns. The first generic manifest
adapter accepted only one map entry. Its Dart model and Rust planner also
stored one input mapping, which made the adapter fall back even when every
individual mapping was otherwise representable.

The build_runner protocol treats all mappings that match one input as one
builder application. The allowed output set is the union of the outputs from
those mappings. A mapping that does not match the input must not contribute an
output.

## Decision

- Bump the dynamic manifest schema to version 5 and encode an ordered
  `extensions` list on each definition. Each entry owns its input match mode,
  anchor flag, and output list.
- Keep the flattened output fields in generated manifests during the
  transition so the generic watch reader can recognize every source output.
  The Rust reader accepts the old single-mapping fields as a v5 compatibility
  fallback, but newly generated manifests use the explicit list.
- Store the same ordered extension list in the Rust-owned
  `BuilderDefinition`. Candidate selection succeeds when any extension
  matches. Output planning visits only matching extensions and deduplicates
  the resulting AssetIds while preserving declaration order.
- Include every extension's metadata in the config digest so adding,
  removing, or changing one mapping invalidates the graph.
- Do not add a builder-name branch or a specialized fast path. Optional,
  post-process, external-process, and otherwise invalid mappings remain
  outside this generic subset.

## Consequences

- A single generic action can write the union of suffix, exact-path, and
  capture outputs when their mappings overlap, matching build_runner's
  `allowedOutputs` behavior.
- The action key remains one builder/input pair, so overlapping mappings do
  not create duplicate actions. Duplicate output AssetIds across distinct
  actions continue to be rejected before worker startup.
- Manifest version 5 invalidates any version 4 manifest, preventing a
  single-mapping reader from silently using an incomplete output set.
- The flattened fields are compatibility metadata only; planning decisions
  use the explicit extension list.

## Verification

- Rust 1.98.1 unit tests: 35 passed, including parser and output-union cases.
- `dart analyze dart_worker`: no issues.
- `scripts/correctness_multi_mapping_builder.sh`: stock/Rust clean output,
  overlapping output union, no-op, changed input, rename, and delete cases
  passed.
