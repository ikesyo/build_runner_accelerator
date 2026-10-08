# Migrating accelerator 0.x to the 1.0 contract

This contract is implemented on the development line before the 1.0 release.
The package version is still managed by the release workflow. Stock
build_runner remains the output/configuration reference, and auto/rust/dart
keep their documented selection behavior.

## Public commands and options

The stable accelerator commands are `build`, `watch`, and `prewarm` (default:
`build`). Options are `--mode auto|rust|dart`, `--root`, `--dart`, `--jobs`,
`--interval-ms`, `--worker`, `--force-aot`, `--force-jit`, `--help`/`-h`, and
`--version`. `--background` is valid only for `prewarm`. Compile flags are
mutually exclusive and retain stock semantics. Other stock commands/options
select stock directly in auto/dart, preserving argument order; rust rejects
unsupported native commands/options. `aot-cache-key` is a native diagnostic
utility whose cache-key output is internal, not a stable storage API. The
retired stock flags `--delete-conflicting-outputs`/`-d` remain accepted and
ignored for native build/watch because this is stock compatibility. `prewarm --mode dart` succeeds without warming anything;
strict Rust mode fails when native execution is unavailable.

Replace `aot-prewarm` with `prewarm`, including scripts and CI. The old alias
fails in every mode; it is not forwarded to stock build_runner.

`--worker` is supported, but custom workers must implement the generated
manifest builder IDs and the current IPC and use the **exact same accelerator
package version** as the native frontend. Rebuild custom workers on every
package upgrade. Protocol v1 remains the wire format; matching `v: 1` alone is
insufficient. Both initialization messages require `accelerator_version` and
the existing binary/visibility/reset capabilities remain required. Missing
required build fields (including `is_root`) fail rather than defaulting to a
potentially different BuilderOptions configuration.

## Environment classification

Names below have the `BUILD_RUNNER_ACCELERATOR_` prefix. Existing switches are
retained for diagnosis, recovery or explicitly opt-in experiments; none is
removed in this rebaseline. Unknown environment names are ignored, not promised
as extension points. Platform cache selection also honors LOCALAPPDATA,
XDG_CACHE_HOME and the platform home/cache conventions.

| Class | Names | Contract |
| --- | --- | --- |
| Stable | `BIN`, `CACHE`, `RELEASE_BASE_URL`, `WORKER_AOT` | Preinstalled frontend, cache root, signed HTTPS release mirror and worker compilation policy. |
| Diagnostic, supported but output/schema not stable | `DEBUG`, `METRICS`, `ANALYSIS_TRACE`, `WALL_TRACE`, `PLAN_ONLY` | Error stack, worker metrics, analysis details, frontend timing, and non-building plan inspection. Trace needs METRICS; PLAN_ONLY exits before executing actions. |
| Diagnostic recovery controls | `BYTE_STORE`, `DEP_CACHE`, `PACKED_STORE`, `DEP_PREFETCH`, `MANIFEST_SNAPSHOT`, `EARLY_CATALOG`, `PART_FILTER`, `SDK_SUMMARY_PREWARM`, `ANALYSIS_PREWARM` | Set `0` to disable the corresponding optimization; PACKED_STORE=0 selects a separate per-key store. BYTE_STORE also accepts false/off. |
| Experimental, opt-in | `ANALYSIS_SINGLE_FLIGHT`, `COMPILE_PREWARM`, `MANIFEST_PREWARM` | Set `1` to enable; disabled by default, may change or be removed in a later release. |
| Experimental tuning | `ANALYSIS_PREWARM_JOBS`, `ANALYSIS_PREWARM_DIRS`, `RESOLVER_CAP` | Prewarm shard count/directories and resolver concurrency cap; no stable performance guarantee. |
| Internal | `WORKER_KERNEL`, `WORKER_AOT_PATH`, `WORKER_AOT_BACKGROUND_LOCK`, `MANIFEST_WORKER_AOT`, `SUPERVISED` | Artifact overrides and subprocess coordination; no public compatibility guarantee. Do not set in normal CI. |

WORKER_AOT uses `1`/`auto` for synchronous compilation, `background` for
background compilation, `force` for mandatory AOT and `0` for the non-AOT path.
The existing other-value non-AOT behavior is retained; prefer explicit `0`.
CLI force flags take precedence. The internal `--stock-arguments-json` and
`--accelerator-process-group` transport options are not public CLI. Toolchain variables DART_BIN, DART_SDK,
CARGO_BIN, PUB_CACHE, CARGO_HOME and RUSTUP_HOME belong to repository scripts,
not the project-facing launcher option API.

## Regenerated internal state

Manifest v9 contains explicit `extensions` mappings or post-process
`input_extensions`; flattened input_suffix/input_match/input_anchored,
output_suffix/output_suffixes at builder level are removed. The launcher/native
frontend generates the manifest; consumers must not edit or depend on its
storage schema. Old, missing or invalid manifests are regenerated.

Graph schemas and binary formats are disposable. Obsolete/corrupt graphs are
diagnosed and rebuilt from empty, causing actions to run again. Old filenames
outside the current graph path are ignored. Worker AOT, kernels, probe results
and SDK/analyzer caches are selected only when their format and content/SDK/
dependency identity checks pass; misses regenerate them. Analysis packs continue
to ignore earlier formats with no migration. The diagnostic per-key analyzer
namespace is now `byte_store/per-key-v1/<fingerprint>` and directive cache
namespace is `dep_parse/per-key-v1-<sdk>`; their old directories remain on disk.
There is no promise that every cache is cleared on every version update.

The first build may regenerate the manifest/graph, compile the worker/generator
and refill analysis caches. `prewarm` can prepare the compile/analysis portion;
it does not regenerate build outputs or the action graph. Existing sources and
outputs are not deleted because a cache format changed. Normal successful build
actions still replace outputs and handle their ordinary stale-output lifecycle.

## Safe recovery

1. Stop all build/watch/prewarm processes for the workspace and shared cache.
2. Check package and preinstalled frontend versions (`--version`); update the
   frontend and rebuild custom workers together. Remove internal artifact
   overrides from your environment.
3. Retry `build --mode rust --force-jit` to get a strict diagnostic without AOT.
   Disable BYTE_STORE/DEP_CACHE or use a fresh CACHE directory to isolate shared
   analysis state. `PACKED_STORE=0` is another publication/index diagnostic.
4. If needed, rename `.dart_tool/build_runner_accelerator` to a backup directory
   and rerun `build`. This retains user sources and generated source files;
   artifact-tree intermediates are rebuilt. Preserve the backup until the
   generated outputs have been checked.
5. For immediate stock recovery, use `build --mode dart` with any required stock
   flags. Do not delete source files or generated source outputs merely to fix
   accelerator cache compatibility. Prune obsolete shared cache directories
   only while all processes using them are stopped.

See [ADR 0030](adr/0030-one-zero-contract-and-disposable-state.md) for the boundary
and [protocol/v1.md](../protocol/v1.md) for required message fields.

The implementation inventory is in [the compatibility audit](compatibility-audit-1.0.md).
