# Updating after the 0.x compatibility cleanup

This guide covers the changes in the continuing 0.x development line. The
[current CLI/environment reference](launcher-and-release.md),
[implementation audit](compatibility-audit.md), and
[ADR 0030](adr/0030-compatibility-cleanup-and-disposable-state.md) describe the
interfaces, affected producers/consumers, and reasons for this cleanup.

## Changes to scripts and CI

| Retired behavior | Update |
| --- | --- |
| `aot-prewarm` alias | Use `prewarm`. The alias fails in every mode, including dart; it is not forwarded to stock. |
| `BUILD_RUNNER_ACCELERATOR_PACKED_STORE` | Remove it. All values, including `0`, are ignored; both shared stores are packed-only. Use `BYTE_STORE=0`, `DEP_CACHE=0`, or a fresh `CACHE` directory for diagnosis. These names have the `BUILD_RUNNER_ACCELERATOR_` prefix. |
| Older internal worker artifacts/messages | Update the preinstalled frontend with the package and remove internal `--worker` or artifact overrides. The package regenerates its worker as needed. Required IPC fields and matching versions are checked as specified in [protocol/v1.md](../protocol/v1.md). |

Stock build_runner configuration/builder compatibility and auto/rust/dart mode
behavior are maintained. Stock's retired `--delete-conflicting-outputs`/`-d`
flags remain accepted by native build/watch; they are not accelerator aliases.

## Regenerated internal state

These formats are not stable API; old state need not be migrated:

| State | Current update behavior |
| --- | --- |
| Manifest | v9 uses explicit `extensions` or post-process `input_extensions`. Builder-level flattened fields are removed. Old, invalid or incomplete manifests regenerate; configured metadata must agree with its definition. |
| Graph | Obsolete formats/schemas and corrupt records are diagnosed and rebuilt from empty. Filesystem IO errors remain errors. Old filenames outside the current path are ignored. |
| Worker AOT/kernel, generator/probe and SDK summary | Format/content/SDK/dependency identity checks select usable artifacts; misses regenerate them. |
| Analyzer/directive cache | Packed stores use `byte_store/v2/<fingerprint>` and `dep_parse/v3-<sdk>`. Both per-key readers/writers and analyzer per-key readiness scanning are removed. Old directories remain untouched and unselected. |

The first build may regenerate the manifest/graph, compile the worker/generator
and refill analysis caches. There is no promise that every cache is cleared on
every update. `prewarm` can prepare compilation and analysis; it does not
regenerate build outputs or the action graph.

Cache format changes do not delete user sources or existing generated source
files. Normal successful build actions still replace outputs and handle their
ordinary stale-output lifecycle.

## Safe recovery

1. Stop build/watch/prewarm processes for the workspace and shared cache.
2. Check package and preinstalled frontend versions (`--version`); update the
   frontend to match the package. Remove internal artifact overrides.
3. Retry `build --mode rust --force-jit` for strict diagnostics without AOT.
   `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` uses memory-only analyzer storage;
   `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` parses directives without shared
   caching. A fresh `BUILD_RUNNER_ACCELERATOR_CACHE` directory isolates disk state.
4. If needed, rename `.dart_tool/build_runner_accelerator` to a backup directory
   and rebuild. This preserves sources and generated source files; artifact-tree
   intermediates are rebuilt. Keep the backup until outputs have been checked.
5. For immediate stock recovery, use `build --mode dart` with required stock
   flags. Do not delete source files or generated source outputs to repair cache
   compatibility. Prune obsolete shared directories only while their users are
   stopped.
