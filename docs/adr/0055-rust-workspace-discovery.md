# ADR 0055: Workspace discovery in the frontend

- Status: Accepted
- Date: 2026-11-16

## Context

Every `--workspace` invocation resolves the Pub workspace topology
(root, current package, output packages) before it can take locks or
load state. Until now `main.rs` delegated that resolution to a Dart
helper (`tool/resolve_workspace.dart`) and ran it twice: once before
acquiring the workspace locks and once after, so a topology change
during lock acquisition is detected before the result is used.

The helper is a JIT Dart process. Measured on the benchmark host, one
launch costs about 2.0 s of wall time and 2.8 s of CPU before any
build work starts. A `--workspace` no-op build therefore takes about
4.3 s wall (about 6 s CPU, about 280 MB RSS) while the build itself
reports `in 0s`, and the same double launch is charged to clean and
incremental workspace builds. The v0.19.4 reporter measurements show
the same pattern on a faster host (no-op 4.1 s, about 4x the CPU of
the single-package no-op). Nothing else on the no-op path starts a
process: the manifest is cache-served and the build short-circuits
before any worker starts when no action is dirty.

The helper's output is a deterministic function of files Pub and
build_runner already maintain:

- the current package's `pubspec.yaml` (its `name`, and the
  `resolution`/`workspace` markers stock's `BuildPaths.load` checks),
- `.dart_tool/pub/workspace_ref.json` in the current package, which
  names the workspace root,
- the root's `.dart_tool/package_graph.json` (`roots`: the workspace
  member names),
- `package_config.json` (package names to root paths), found by
  walking ancestors from the root.

## Decision

Resolve workspace discovery in the frontend, replicating the exact
semantics of the Dart path:

- `BuildPaths.load` (build_runner 2.16.2): the workspace root applies
  only when `workspace_ref.json` exists and the current pubspec
  carries `resolution: workspace` or a `workspace:` section; otherwise
  the request falls back to a single-package build at the current
  package, with the same graph/configuration identity as stock.
- The output packages are the root package plus, for a workspace
  build, every name in `package_graph.json`'s `roots`, with paths
  taken from `package_config.json`. A root name missing from `roots`,
  or an output package missing from `package_config.json`, is an
  error, as is a current package that is not one of the output
  packages at its own path.
- The existing result validation (canonical paths, containment under
  the root, no shared physical roots, consistency of the fallback
  shape) is unchanged, and discovery still runs before and after lock
  acquisition; the recheck is now cheap enough to keep as a full
  re-resolution rather than a fingerprint comparison.

Pubspec files are read with a YAML parser (yaml-rust2), not line
scans, so the opt-in check and package names follow the same YAML
semantics as the Dart side: comments, quoted and block scalars,
anchors and aliases, flow mappings, and document-level indentation
all resolve exactly as pub resolves them. (A line-scan approximation
was tried first and abandoned: review kept finding valid YAML shapes
it misclassified.)

One deliberate divergence: the Dart package-graph load also validated
that every package's declared dependencies are present in
`package_config.json`. That validation is not part of the topology
result and is not replicated; it still happens in manifest
generation, which loads the full package graph in Dart whenever the
configuration fingerprint changes.

Caching the helper's result under a file fingerprint, and replacing
only the second launch with a fingerprint recheck, were considered
and rejected: both keep a Dart process launch on the critical path of
every workspace build (or on every topology change), and the
fingerprint variant adds a second, cached source of truth for a
result the frontend can compute directly in milliseconds.

## Expected effect

`--workspace` invocations stop paying two Dart process launches when
nothing about the topology is being recomputed. Measured on the
benchmark fixture (workspace with builder-free members, 2,000 inputs,
jobs=2): the no-op lane drops from 4.00-4.40 s wall / 5.7-6.1 s CPU
to 0.28 s wall / 0.30 s CPU, and the clean lane from 36.26 s to
31.80 s wall, with byte-identical outputs. Behavior on valid
workspaces is unchanged; the workspace correctness fixtures and a
differential comparison against the Dart helper over the tracked
fixtures pin the replicated semantics.
