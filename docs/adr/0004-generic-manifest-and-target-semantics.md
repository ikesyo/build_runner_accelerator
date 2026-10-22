# ADR 0004: Generic manifest and target semantics

Stock fallback and frontend-mode statements below are superseded by
[ADR 0036](0036-native-only-execution.md) for 0.14.0. Unsupported requests now fail
explicitly; native correctness and supported-subset boundaries remain.


- Status: Accepted
- Date: 2026-09-07
- Amended by [ADR 0035](0035-package-source-identity.md) for source sets and overlapping watch inputs.
- Amended by [ADR 0039](0039-virtual-primary-inputs.md) for stock virtual primary inputs.

## Context

The first prototype used fixed builder branches. That approach made each new
builder add Rust matching logic, Dart catalog entries, and special output
handling. It also represented only the root target, while official
build_runner configuration can select builders from dependency-owned targets,
target cycles, multiple extension mappings, and post-processors.

## Decision

Use a generated, workspace-specific manifest as the generic boundary:

- Dart resolves official package, target, builder, phase, option, and
  build_to semantics from PackageGraph and BuildConfig.
- The manifest identifies builders by their full package-qualified ID and
  points to a generated Dart worker entrypoint with the required factories.
- Rust consumes owned builder definitions and configured applications rather
  than parsing all of build.yaml itself.
- The model carries package/target scope, dependency-owned targets, stable
  target order, strongly connected component phase semantics, source filters,
  the lossless `required_inputs` suffix list, optional outputs, normal and
  supported post-process builders, and multiple literal/capture
  extension mappings.
- Non-dot filename/path input suffixes retain ordinary suffix matching and
  literal output fragments. For example, `schema.yaml -> lib/schema.dart`
  produces `lib/schema.dart` at the root and `nested/lib/schema.dart` from
  `nested/schema.yaml`; it is not an anchored exact match. These literal
  fragments are not normalized by adding a dot. The existing path safety
  subset and ADR 0039's virtual-primary restrictions still apply.
- Compatible normal `is_optional` builders remain in the action plan but are
  omitted from eager execution. A later action's asset read can request the
  exact optional action through the resident worker, preserving the same
  phase-aware overlay and transaction boundary.
- Dart resolves builder order and target/SCC member order into the configured
  worker phase and target-order fields. Rust preserves that resolved timeline
  before applying visibility checks; package and target identity therefore
  cannot be lost when phase numbers are reused.
- Logical visibility is phase-aware and independent from physical storage:
  source outputs resolve at package paths, cache outputs resolve in the
  artifact tree, and stale/deleted outputs remain hidden through the pending
  transaction overlay. The same visibility rule is applied by the Dart worker
  adapter and by Rust's asset RPC.
- The manifest generator and Rust validator reject shapes outside the
  supported subset. auto uses the Dart fallback for those shapes; rust fails
  explicitly.
- When official configuration declares multiple factories, or a legacy
  post-process definition omits reliable input extensions, the generator may
  instantiate those known factories in an isolated probe using the resolved
  package config. It records only validated runtime mappings; a failed probe
  keeps the definition on the fallback path.
- Popular builder fast paths, if ever added, must remain separate from the
  generic manifest path and must demonstrate a measured benefit.

## Consequences

Adding a builder normally changes its Dart package configuration, the shared
manifest/action model, and a stock-vs-native fixture rather than adding a
special case to main.rs. The generic path scales across package names while
preserving official configuration as the source of truth.

Manifest generation is workspace-specific and can be cached using package
configuration and SDK inputs. Generated files belong under
.dart_tool/build_runner_accelerator/ and are disposable. The supported subset
is intentionally narrower than all of build_runner; the fallback is part of
the design, not an error hidden from users.

## Alternatives considered

- A growing static catalog of popular builders: rejected as the primary path.
- Reimplement all of build.yaml parsing in Rust: rejected because it duplicates
  official build-runner resolution.
- Runtime reflection or guessed factory loading: rejected because imports,
  factory identity, and failure boundaries would be ambiguous. The bounded
  probe above is different: it uses the official import and factory identity
  already present in the manifest, only to validate their declared mapping.
