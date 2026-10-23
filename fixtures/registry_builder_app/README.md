# Conduit registry builder dependency probe

This is a **stock-only reference**, not a supported native fixture. The builder
is `conduit_build_runner:registry_builder`, not a Drift builder or a package
named `registry_builder`.

## Version boundary

The published package API lists versions 6.0.0 and 7.0.0. Both require
`analyzer ^12.0.0`, `build ^4.0.5`, and `source_gen ^4.2.2`. Version 7.0.0
requires Dart `>=3.12.0 <4.0.0` (6.0.0 uses `>=3.12.0-0 <4.0.0`).

The accelerator requires `build_runner >=2.15.3 <2.17.0`, whose minimum release allows Analyzer
`>=13.3.0 <15.0.0`. Its own Analyzer constraint is `>=13.3.0 <15.0.0`.
Neither intersects the published Conduit constraint. `dart pub get` rejects
both published versions before a native manifest/action can be created.
The script checks this diagnostic, so a network error cannot count as a pass.

The reference lockfile instead pins Conduit 7.0.0, stock build_runner 2.14.1,
build 4.0.5, and Analyzer 12.1.0, with no accelerator dependency and no overrides.
Use the same Dart 3.13.3 SDK and pub cache as the main repository checks. This
older stock runner is outside the native compatibility window; it must not be
used as evidence of stock/native equality.

Upstream master at `03f181d53c9323671ded6204f40ad2fa83de3461` has version 7.0.0
with Analyzer `^13.0.0` and Dart `>=3.13.0`, which intersects the expanded native Analyzer window. This unpublished
revision has not been validated here. No upstream fork, dependency override,
or production compatibility-window change is part of this probe.

Sources:

- [Published versions and constraints](https://pub.dev/api/packages/conduit_build_runner)
- [7.0.0 archive](https://pub.dev/api/archives/conduit_build_runner-7.0.0.tar.gz):
  SHA-256 `d22a43418f45356556e6fab64a82826aade4398731da74aefc65696b5b30deae`;
  inspect `build.yaml`, `lib/builder.dart`, and `lib/src/registry_builder.dart`.
- [Upstream pubspec](https://github.com/conduit-dart/conduit/blob/03f181d53c9323671ded6204f40ad2fa83de3461/packages/build_runner/pubspec.yaml)

## Output contract

The official factory `registryBuilder` ignores options and returns
`RegistryBuilder`. Its mapping is `$package$` → `lib/conduit.g.dart`,
`auto_apply: root_package`, `build_to: source`, non-optional. The synthetic
primary exists even with no manifests; it is not a real input file to create.
The five `required_inputs` suffixes order it after manifest producers.

It enumerates `findAssets(Glob('lib/**'))`, recognizes suffixes below, and reads
only those assets with `readAsString`. It decodes each JSON map and casts the
associated list to strings. Malformed JSON therefore fails in the real builder.

| Manifest suffix | JSON key | Runtime suffix |
| --- | --- | --- |
| `.channel.conduit.json` | `channels` | `ChannelRuntime` |
| `.serializable.conduit.json` | `serializables` | `SerializableRuntime` |
| `.controller.conduit.json` | `controllers` | `ControllerRuntime` |
| `.managed.conduit.json` | `managedObjects` | `EntityRuntime` |
| `.config.conduit.json` | `configurations` | `ConfigurationRuntime` |

Bindings are sorted by class name before imports and bootstrap assignments are
written. Companion library paths replace `.json` with `.dart`; the builder
does not read, resolve, or check those libraries. It uses neither Resolver nor
`inputLibrary`, and it never deletes its primary. There is no cleanup builder
in this isolated configuration. The registry is still emitted for an empty
set of manifests. Duplicate class names are not rejected by the implementation;
no tie-order guarantee is claimed here.

## Regression command and scope

```bash
bash scripts/correctness_registry_builder.sh
```

The other five Conduit generators are explicitly disabled. Two fixture-only
copy builders supply a source controller manifest and a cache channel manifest;
the official registry is the consumer. The remaining kinds are source JSON.
No companion runtime library is supplied. This is a generator contract probe,
not an executable Conduit server or a test of the other Conduit generators.

The script observes clean/no-op builds, sorted aggregation of all five kinds,
non-target changes, source/generated input changes, addition, deletion, rename,
old source-output removal, logical cache-input removal, empty aggregation, malformed generated JSON
failure, and recovery of
the preceding successful registry bytes. Failure does not assert atomic stock
publication. Dependency probes reject the current native baseline for both
published Conduit versions.

Stock 2.14.1 leaves the old physical channel JSON cache files after rename and
deletion, while excluding them from registry enumeration. The regression checks
both physical retention and the absence of stale/duplicate registry bindings;
it does not confuse a cache directory listing with the builder's visible inputs.

This override-free reference cannot resolve the native baseline. The separate
[override fixture](../registry_builder_override_app/README.md) uses Analyzer
14.5.0 with stock/native build_runner 2.16.2 to compare output bytes, ordered
enumeration, atomic recovery, and paired watch. It also exercises the shared
virtual-primary model from [ADR 0039](../../docs/adr/0039-virtual-primary-inputs.md).
That experiment does not change the published dependency conflict above.
