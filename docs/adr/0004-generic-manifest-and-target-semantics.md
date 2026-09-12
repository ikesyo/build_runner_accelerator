# ADR 0004: Generic manifest and target semantics

- Status: Accepted
- Date: 2026-09-07

## Context

The first prototype used fixed builder branches. That approach made each new
builder add Rust matching logic, Dart catalog entries, and special output
handling. It also represented only the root target, while official
build_runner configuration can select builders from dependency-owned targets,
target cycles, multiple extension mappings, and cache-only post-processors.

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
  required inputs, optional outputs, normal and supported cache-only
  post-process builders, and multiple literal/capture extension mappings.
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
