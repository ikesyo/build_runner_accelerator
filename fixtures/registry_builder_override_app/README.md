# Conduit registry with a fixture-only Analyzer override

This fixture executes the published, unmodified
`conduit_build_runner:registry_builder` factory against stock build_runner
2.16.2 and the native frontend. It deliberately overrides Conduit's published
Analyzer constraint. It demonstrates compatibility of this configuration;
ordinary Pub resolution of Conduit 6.0.0/7.0.0 with the native baseline still
fails. The separate [stock-only reference](../registry_builder_app/README.md)
retains both dependency-conflict checks.

## Exact configuration

| Component | Version/configuration |
| --- | --- |
| Dart / Rust used locally | 3.13.3 / 1.98.1 |
| `conduit_build_runner` | Published 7.0.0, original factory import and sources |
| `build_runner` | 2.16.2 on both sides |
| `build` | 4.0.11 |
| `dependency_overrides.analyzer` | 14.5.0, only in this fixture's root pubspec |
| Other Conduit generators | All five explicitly disabled |
| Native builder jobs / Cargo jobs | 1 / 2 |

No dependency constraints in the accelerator or the Pub cache are modified.
The official factory import also imports Conduit's other generators; that
complete import compiled under the override without source patches. This does
not establish that those other generators can execute under Analyzer 14.

The scripts copy the source manifests and copy builders from the stock-only
fixture, then add this fixture's `build.yaml` and `placeholder_probe.dart`.
Both temporary applications resolve the same tracked lockfile and use the same
SDK and Pub cache. The source/cache manifest producers are test helpers; the
aggregate consumer is the real registry builder. Companion runtime libraries
are intentionally absent because the registry emits imports without resolving
or checking those libraries. Its API/output contract is documented in the
[stock-only guide](../registry_builder_app/README.md#output-contract).

## Checks

```bash
bash scripts/correctness_registry_override.sh
bash scripts/watch_smoke_registry_override.sh
```

Build checks compare complete source inventories and bytes, all current cache
outputs, and ordered `findAssets('lib/**')` results from later-phase probes.
The probes run on `$lib$`, `$test$`, and `$web$`; the real registry runs on
`$package$`. They verify that all four virtual IDs are unreadable and absent
from enumeration, while a real source ending in `$lib$` keeps normal suffix
replacement. A physical source at a reserved virtual path is rejected before
actions without changing generated outputs or the graph.
Scope checks exclude and restore the registry's virtual primary
with `generate_for` and check stale fixed-output removal.

Lifecycle checks cover clean/no-op, registered and non-registered changes,
source/cache generated changes, addition/deletion/rename, and empty aggregation.
Selected registry builds also compare demand-driven producers, no-op reuse,
and changed generated inputs.
Malformed generated JSON fails inside the real registry. Native retains the
preceding source outputs, cache bytes, and graph; recovery compares bytes with
stock. Paired stock/native watch checks cover changes, source/cache additions,
rename/deletion, failed cycles and recovery, output restoration, and non-target
changes. Logs and snapshots live outside the watched application directories.

Stock may retain old physical cache files after a producer disappears; native
removes stale producer artifacts. Comparisons therefore use current declared
cache outputs and the builder-visible ordered enumeration. Old cache artifacts
must never remain in the registry or in later-phase probe results.

## Limits

This is an isolated registry configuration with an explicit dependency override,
not support for the full Conduit builder set, a runnable Conduit server, or an
override-free supported package solution. Duplicate class-name tie ordering,
other Analyzer versions, mixed real project workspaces, and performance remain
outside this probe. Reserved virtual paths as declared outputs fail explicitly.
Physical sources at these paths are also unsupported: stock can enumerate them
despite unreadability, and deleting them can remove outputs of virtual actions
until a clean graph is created. The native fixture rejects this history-dependent
shape instead of treating it as an ordinary virtual input.
The shared virtual-input decision is [ADR 0039](../../docs/adr/0039-virtual-primary-inputs.md).
