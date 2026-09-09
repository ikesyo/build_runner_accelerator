# ADR-0060: generic cache-only PostProcessBuilder subset

- Status: accepted
- Date: 2026-09-06

## Context

`PostProcessBuilder` consumes an asset produced by an earlier builder phase and
may create outputs that are not declared by `build_extensions`. The generic
manifest and planner previously modeled only ordinary builders, so a resolved
post-process definition had to fall back even when its input and output
behavior was simple.

Post-process execution also has different visibility rules from an ordinary
source builder: the primary input is the generated asset from the preceding
phase, outputs are dynamic, and the resulting assets must not become ordinary
builder candidates in the same build. Current `build_config` no longer treats
the post-process `input_extensions` field as reliable, while the runtime
builder still exposes the information.

## Decision

- Bump the dynamic manifest schema to version 6 and encode a `kind` on each
  definition. Normal builders and post-process builders use separate generated
  worker catalogs while sharing the generic definition and action model.
- Support a deliberately small post-process subset: a `package:` factory with
  non-empty, simple dot-prefixed `input_extensions`, `build_to: cache`, and
  JSON-compatible options. Auto-applied post-process definitions are not
  promoted into the generic path yet.
- Special-case only the verified current `source_gen:part_cleanup` import,
  factory, and key when its deprecated config field is absent, supplying the
  runtime's `.g.part` extension. This keeps the current `json_serializable`
  pipeline in the generic path without guessing extensions for arbitrary
  post-process builders.
- Plan and execute normal builders before post-process builders. The planner
  hides existing post-process outputs from normal source candidates, then
  exposes the non-optional outputs planned by normal actions as the post-process
  primary-input snapshot.
- Treat post-process outputs as dynamic cache assets. Accept only non-empty,
  relative paths in the same package, reject output collisions with another
  action, and retain the outputs in the normal asset graph for incremental
  invalidation and stale-output cleanup.
- Give a post-process build step access to its primary input only. Support
  `deletePrimaryInput` only for that exact primary input, applying it during
  the final atomic commit. Deleting any other asset, or deleting from an
  ordinary Builder, remains an error.
- Keep unsupported definitions on the existing fallback/error boundary. No
  builder-name fast path, external process, complex input mapping, or optional
  normal-builder behavior is added by this ADR.

## Consequences

- A generic manifest can now represent a cache-only PostProcessBuilder without
  embedding builder-specific logic in Rust or Dart.
- Dynamic outputs participate in no-op, incremental, rename, input deletion,
  and stale-output cleanup. A deleted post-process output is regenerated when
  its action is scheduled by the Rust graph.
- Post-process outputs are hidden from ordinary builder candidate selection,
  preventing a cache artifact from being mistaken for a source input.
- The verified `source_gen:part_cleanup` bridge removes generated `.g.part`
  cache inputs with the same primary-input deletion semantics as stock
  build_runner.
- The supported subset is intentionally narrower than the full build_runner
  API. Unsupported post-process features continue to use Dart fallback in
  auto mode and fail explicitly in Rust mode.

## Verification

- Rust unit tests cover version-6 parsing and post-process definition metadata.
- `dart analyze dart_worker` reports no issues.
- `scripts/correctness_post_process_builder.sh` compares stock and Rust output
  for dynamic output, no-op, input change, rename, input deletion, and stale
  output cleanup.
- `scripts/correctness_current_json.sh` compares current
  `json_serializable`/`source_gen` clean, no-op, one-file, and broad builds,
  including `.g.part` cleanup.
- `scripts/watch_smoke_current_json.sh` compares current JSON generation for
  input change, generated-output deletion, and a `generate_for`-preserving
  rename under stock and Rust watch.
- `scripts/watch_smoke_post_process_builder.sh` compares input-change and
  rename behavior under stock and Rust watch mode.
