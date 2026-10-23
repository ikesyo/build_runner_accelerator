# ADR 0008: Runtime expected-output mappings

Stock fallback and frontend-mode statements below are superseded by
[ADR 0036](0036-native-only-execution.md) for 0.14.0. Unsupported requests now fail
explicitly; native correctness and supported-subset boundaries remain.


- Status: Proposed
- Date: 2026-09-14

## Context

build_runner uses two related but distinct sources of truth. build.yaml creates
builder applications, resolves ordering, build_to, required_inputs, and target
filters. The instantiated Builder then supplies buildExtensions, which is the
mapping used to compute expected outputs for a specific input. That runtime
mapping may depend on resolved BuilderOptions.

built_value_generator:built_value is a normal Builder returned by builtValue, not
a post-process builder. Its published build.yaml declares .dart to
.built_value.g.part, build_to: cache, and an applies_builders relationship to
source_gen|combining_builder. The latter is a normal builder which consumes
.g.part through required_inputs; its part_cleanup companion is a separate
cache-only post-process builder.

The previous manifest path treated the static build.yaml mapping as the
complete expected-output plan. That is insufficient for option-dependent,
multi-factory, capture, or literal mappings, and it also loses the primary
input when a later phase consumes a generated output.

## Decision

The Dart manifest generator remains the compatibility boundary and source of
truth for package graph and build configuration semantics. For each selected
application that needs runtime data—normal builders with multiple factories or
resolved options, and post-process builders with resolved options or without a
validated input extension list—it instantiates the configured factory with the
resolved options and BuilderOptions.isRoot, then serializes a validated runtime
mapping into the application entry. A single-factory normal builder with no resolved options
uses its validated build.yaml mapping directly.

For post-process builders, a validated runtime `inputExtensions` list takes
precedence over the deprecated build.yaml `input_extensions` field and known
cleanup defaults. Nonempty resolved options require probing even when either
static source is available. Invalid runtime inputs remain unsupported rather
than falling back to a static list. Applications without options retain the
existing static/default path when available.

The shared definition keeps its usable static input list. Runtime lists are
attached to individual applications, so a target with options cannot change
the inputs of a target using the default configuration.

The Rust side consumes that normalized mapping generically. It does not
identify built_value, source_gen, or any other package by name. A configured
application may override its static normal-builder extensions or post-process
input extensions; the static definition still supplies ordering, phase,
required-input, target, visibility, and lifecycle metadata. The planner also
follows declared-output edges back to the original primary input for
targetSources matching and includes the configured builder instance in action
identity.

Probing is bounded and failure-tolerant at the frontend boundary. A missing
or invalid probe result makes the manifest unsupported: --mode auto falls
back to stock Dart build_runner, while --mode rust reports an explicit
unsupported-manifest error. Builder/resource residency, optional demand
execution, overlay visibility, stale-output deletion, and all-success publication remain
unchanged.

## Deliberate non-goals

This ADR does not generalize all post-process builders or workspace semantics.
Mappings that cannot be safely normalized—such as an empty input key
(build_extensions: {"": ...}), unsupported capture/path forms, or an
unvalidated runtime shape—remain on the fallback boundary. A package-specific
Rust branch is not an allowed substitute for a failed normalization.

## Validation

The built_value fixture is compared against stock for generated source and
cache outputs, non-triggered inputs, and removal of outputs after the input
stops being a built_value library. Its single-factory, no-option case uses the
validated static mapping; option-dependent and multi-factory cases exercise the
runtime probe boundary. Generic Rust tests cover multiple mappings,
capture/literal paths, runtime overrides, empty expected-output lists, output
collisions, and multi-phase primary-input chains.

The post-process fixture also compares option-dependent input selection against
stock while keeping the legacy declared extensions unchanged. It covers
switching to a different input suffix, stale-output removal, no-op, and returning
to the original mapping. It also compares a target with an input-extension
option alongside a target without options using the same post-process definition.
