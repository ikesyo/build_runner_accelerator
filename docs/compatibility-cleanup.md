# Updating after the 0.x compatibility cleanup

This guide covers the changes in the continuing 0.x development line. The
[current CLI/environment reference](launcher-and-release.md),
[implementation audit](compatibility-audit.md), and
[ADR 0030](adr/0030-compatibility-cleanup-and-disposable-state.md) describe the
interfaces, affected producers/consumers, and reasons for this cleanup.

## 0.14.0: stock fallback removal

The accelerator now requires native execution. Unsupported CLI, manifest, state,
or runtime API requests fail explicitly; no stock process is started. Native
binary resolution/download errors also fail, including prewarm. There is no
published macOS Intel artifact; use a compatible preinstalled binary or stock.

| Previous command | Replacement |
| --- | --- |
| `dart run build_runner_accelerator build --mode auto` | `dart run build_runner_accelerator build` |
| `dart run build_runner_accelerator watch --mode rust` | `dart run build_runner_accelerator watch` |
| `dart run build_runner_accelerator build --mode dart` | `dart run build_runner build` |
| Accelerator `clean`, `serve`, or stock-only flags | Run the corresponding `dart run build_runner ...` command directly. |

All old `--mode` values are errors with migration guidance. Both leading and
command-level help/version now describe the accelerator. Stock comparisons
remain the correctness reference; the native supported subset has not widened.

A legacy `stock-output-policy-state` marker is still a refusal boundary: the
native graph cannot import stock's logical digest history. Updating does not
clear the marker or silently resume native execution. Direct stock use no longer
records markers, so reset both build states before returning to native after
stock execution, especially when keeping manually modified outputs.

## Changes to scripts and CI

| Retired behavior | Update |
| --- | --- |
| `aot-prewarm` alias | Use `prewarm`. The alias fails in every mode, including dart; it is not forwarded to stock. |
| `BUILD_RUNNER_ACCELERATOR_PACKED_STORE` | Remove it. All values, including `0`, are ignored; both shared stores are packed-only. Use `BYTE_STORE=0`, `DEP_CACHE=0`, or a fresh `CACHE` directory for diagnosis. These names have the `BUILD_RUNNER_ACCELERATOR_` prefix. |
| Older internal worker artifacts/messages | Update the preinstalled frontend with the package and remove internal `--worker` or artifact overrides. The package regenerates its worker as needed. Required IPC fields and matching versions are checked as specified in [protocol/v1.md](../protocol/v1.md). |

Stock build_runner configuration/builder semantics remain the reference within
the supported native subset. Stock's retired `--delete-conflicting-outputs`/`-d`
flags remain accepted by native build/watch; they are not accelerator aliases.

## Regenerated internal state

These formats are not stable API; old state need not be migrated:

| State | Current update behavior |
| --- | --- |
| Manifest | v10 adds source sets for all targets and dependency public-asset restrictions. Old, invalid or incomplete manifests regenerate; configured metadata must agree with its definition. |
| Graph | Schema 5 invalidates snapshots/actions made with the overbroad root source defaults. Obsolete formats/schemas and corrupt records rebuild from empty. Filesystem IO errors remain errors. Old filenames outside the current path are ignored. |
| Worker AOT/kernel, generator/probe and SDK summary | Format/content/SDK/dependency identity checks select usable artifacts; misses regenerate them. |
| Analyzer/directive cache | Packed stores use `byte_store/v2/<fingerprint>` and `dep_parse/v3-<sdk>`. Both per-key readers/writers and analyzer per-key readiness scanning are removed. Old directories remain untouched and unselected. |

The first build may regenerate the manifest/graph, compile the worker/generator
and refill analysis caches. There is no promise that every cache is cleared on
every update. `prewarm` can prepare compilation and analysis; it does not
regenerate build outputs or the action graph.

Cache format changes do not delete user sources or existing generated source
files. Normal successful build actions still replace outputs and handle their
ordinary stale-output lifecycle.

A native cold build replaces its private artifact tree only after all actions
succeed. This removes extra parent-package cache outputs from older builds
without trusting obsolete graph records to delete files in nested packages.
Failure or cancellation before commit leaves both the old cache and graph intact.

## Safe recovery

1. Stop build/watch/prewarm processes for the workspace and shared cache.
2. Check package and preinstalled frontend versions (`--version`); update the
   frontend to match the package. Remove internal artifact overrides.
3. Retry `build --force-jit` for diagnostics without AOT.
   `BUILD_RUNNER_ACCELERATOR_BYTE_STORE=0` uses memory-only analyzer storage;
   `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` parses directives without shared
   caching. A fresh `BUILD_RUNNER_ACCELERATOR_CACHE` directory isolates disk state.
4. If `stock-output-policy-state` exists or you have switched to stock since
   the last native build, rename **both** `.dart_tool/build_runner_accelerator`
   and `.dart_tool/build` to backup directories before rebuilding natively.
   Do not remove only the marker: an older native graph cannot reuse stock's
   newer logical digests. This is a cold rebuild and does not preserve keep
   history; copy any manually edited generated outputs you need to retain
   outside the workspace first. Existing generated source files are not deleted
   by the reset, but a successful build can replace them.
5. Otherwise, if a native cache reset is needed, rename only
   `.dart_tool/build_runner_accelerator` to a backup directory and rebuild.
   This preserves sources and generated source files; artifact-tree
   intermediates are rebuilt. Keep backups until outputs have been checked.
6. For immediate stock recovery, use `dart run build_runner build` with the
   required flags. Do not delete sources or generated source outputs to repair
   cache compatibility. Prune obsolete shared directories only while their users
   are stopped.
