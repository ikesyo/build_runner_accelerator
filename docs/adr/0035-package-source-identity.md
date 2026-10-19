# ADR 0035: Package source sets and nested asset identities

- Status: Accepted
- Date: 2026-10-18
- Amends ADR 0004; uses ADR 0030's disposable private state policy.

## Evidence

Stock build_runner 2.16.2's `BuildConfigs`, `AssetTracker`,
`BuildPackagesAssetFinder` and `BuildPackages.pathFor` resolve input IDs per
package and target, rather than assigning every physical file exclusively to
its deepest package. With default root sources, `dep/lib/a.txt` is only an
input as `dep|lib/a.txt`. Explicit root `sources: ['**']` also includes the
parent ID `app|dep/lib/a.txt`; stock can build outputs for both IDs.

Native previously replaced the root defaults with `**`, admitting arbitrary
nested dependency files and producing extra parent-package cache outputs.
Filtering directory roots unconditionally would also be incompatible with
explicit overlapping sources and reads.

## Decision

Manifest v10 records all target source sets, including builder-free targets,
and dependency public-asset restrictions. Root defaults match stock's standard
in-build source paths plus additional public assets. Keep Analyzer isolated
from manifest compilation: test the lightweight default lists against stock's
constants. Explicit empty target sources remain empty.

Workspace source enumeration, snapshots, reads and globs use the same source
sets. Dependency public patterns restrict inputs even for that dependency's
own builders. `canRead` returns false outside those patterns; explicit reads
throw stock's `InvalidInputException`, rather than reporting a missing source.
The worker receives these public patterns at initialization and validates
builder inputs before phase and cache shortcuts. Resolver filesystem reads
retain their separate graph visibility, including generated non-public files.
Generated assets retain the graph's phase/location rules and are added
to glob candidates from the declared-output index, without scanning orphan
cache files as sources. Physical package containment does not remove parent
IDs from one-shot builds.
Embedded recursive wildcards such as `lib/**.dart` cross directory separators,
matching Dart glob semantics in source selection and generated-asset queries.

Prune directories using source patterns, rather than unconditionally hiding
dot-prefixed or `build`/`target` paths. Eligible hidden files are ordinary
sources. Root source sets admitting stock/native build implementation trees
under `.dart_tool` remain unsupported before actions: stock can consume its
prior artifact tree as new root inputs, but native's private layout differs.
auto delegates; rust errors. Broad `lib/**` + `dep/**`, or `**` excluding
`.dart_tool/**`, remain native for one-shot builds.

Stock watch events are attributed only to the deepest package. Parent aliases
can retain old membership and cached bytes until restart. Native resnapshots
cannot reproduce that history, so potentially overlapping watch source trees
are rejected before actions: auto delegates the complete watch invocation;
rust errors; dart remains stock. A conservative literal-prefix check uses
package roots without another file walk. Literal subtree exclusions such as
`dep/**` (with implementation trees excluded) permit native watch; complex
exclusions may not prove separation.
Non-overlapping default, narrowed and explicitly excluded sources remain native.

Graph schema 6 discards prior input/action evidence without migration or
source-file deletions based on obsolete records. A successful native cold build
replaces the private artifact tree, removing old extra cache outputs. Failure
or cancellation before commit preserves that tree and the old graph. The
existing non-crash-atomic filesystem publication boundary is unchanged.
Filtered builds record that undemanded cache outputs may be untracked. The
next ordinary build scans resolved package caches once and removes untracked files
at successful commit, before publishing rebuilt outputs; later ordinary
builds do not repeat that scan. Package-path files are not part of this cleanup.

## Validation

`scripts/correctness_nested_packages.sh` compares real stock/native builds with
input-controlled output bytes and omission, statuses, builder histories and
subsequent builds. It covers enabled/disabled dependency builders, source/cache
chains, filters, cache-glob membership across ordinary/filtered builds,
clean/incremental state, source listing/read/glob identity,
watch changes/restarts and mode routing, obsolete alias records, dependency file
preservation, failure and cancellation. Existing filter and upgrade suites
continue to cover their broader state contracts.
