# Compatibility audit for the 0.x cleanup

This audit records the obsolete compatibility paths removed during ongoing
0.x development and the stock/recovery behavior retained. It is preparation for
an eventual 1.0, not a final 1.0 contract or a next-release decision.

The [cleanup/update guide](compatibility-cleanup.md) is the current user-facing
reference. [ADR 0030](adr/0030-compatibility-cleanup-and-disposable-state.md) records
the boundary. This inventory separates accelerator history from stock semantics.

| Boundary | Current producer / caller and consumer | Decision and reason |
| --- | --- | --- |
| Public CLI | launcher_options.dart, Rust cli.rs/main.rs; setup scripts | Remove aot-prewarm. All maintained callers now use prewarm. Explicit rejection applies even in Dart mode. Retain stock argument routing from ADR 0029, force flags and auto/rust/dart. |
| Public environment | Launcher, frontend, worker/resolvers and prewarm helpers | Keep the listed public overrides; keep diagnostic controls and opt-in experiments with separate classification. No environment switch is removed in this pass. See the complete name inventory in the cleanup/update guide. |
| Diagnostic alternative | PACKED_STORE=0 selects FileByteStore and per-key directive JSON | Keep to isolate index/publication problems; this is an explicit alternative, not a migration reader. Select new per-key namespaces, leaving old directories untouched. BYTE_STORE=0 and DEP_CACHE=0 provide cache-free recovery. |
| Custom worker IPC | worker/client.rs sends initialize and build/batch; worker.dart/protocol.dart receive | Require exact accelerator_version both ways and initialization reply ID. Keep all capability checks, including optional demand when needed. Require current build fields and initialize phase/workspace context. Current Rust producers already send every required field. |
| Binary result dependency tracking | Worker successful and error results; Rust protocol.rs | Require explicit dependency, deletion and resolver lists plus batch dep_graph; missing edges must not silently become an empty dependency graph. Error results now also send resolver_entrypoints. Validate nested wire version. |
| Manifest | emitter.dart/model.dart emit; frontend.rs, builder/manifest.rs/validation.rs and watch.rs consume | v9 emits only explicit normal extensions or post-process input_extensions. Remove flattened fields, singular output_suffix, fallback mapping reader and unused flattened getters. Update watch's generated-write filter to use extensions; it was still a live consumer. Require mapping fields, kind, trigger digest, explicit options/filter/optional metadata, and configured is_root/target_order. Invalid cached manifests regenerate; missing local worker regenerates instead of selecting a stale external path. |
| Graph | Successful native commit writes graph-v3.bin; build/watch read | Retain binary/schema validation. Invalidate old JSON, unsupported binary formats/schemas and corrupt records with diagnostics; rebuild from empty. Propagate filesystem IO failures. Never migrate by deleting user outputs. Old filenames are ignored. |
| Worker AOT/kernel | Generated entrypoint, native worker_kernel.rs | Keep SDK, package-config, source/dependency and artifact digest checks, cache rebasing, SDK-facade repair, source/kernel fallback and compile locking. These protect current artifacts and portable CI caches; they are not promises to run artifacts from earlier 0.x releases. Invalid artifacts recompile, and forced AOT remains strict. |
| Generator/probe/SDK summary | Manifest helpers and worker analyzer initialization | Keep content/identity validation and source fallback when caches are missing/unavailable. Current generators still use these recovery paths. Storage schema is internal; old state may be ignored without migration. |
| Analyzer/directive packs | IndexedBlobStore and PackedAnalysisByteStore/AssetDepsCache | Earlier packed/per-key formats already have no default migration reader. Keep corruption-as-miss, locked tail repair, checksummed publication and memory fallback. Rename the per-key readiness helper so it describes the active diagnostic store rather than legacy migration. |
| Stock mappings | Official BuildConfig/PackageGraph, mapping.dart and factory probes | Keep source_gen/cleanup builder metadata completion, multi-factory/runtime expected-output probes, optional builders and empty-extension semantics. These are stock builder/configuration compatibility, not accelerator 0.x support. |
| Stock asset/resolver semantics | Remote BuildStep, Rust asset RPC, phased dependencies and resolver resets | Keep visibility, missing-asset behavior and safe sequential resolution when prefetch is declined/unresolved. A fresh sequential RPC applies current visibility, so this fallback is not an old IPC-default path. Keep directive comparison semantics matching stock. |
| Distribution / process lifecycle | Signed releases, compiled launcher fallback, stock child supervisor | Keep signatures/version-pinned release selection and compiled-launcher recovery. Keep internal process-group/supervision transport from ADR 0029; it is not public CLI/environment API. |
| Historical text | CHANGELOG, benchmarks, prior ADR decisions and tooling filenames | Preserve changelogs and measurements. Mark old alias decisions superseded; active README/protocol/scripts/tests describe the current behavior after this cleanup. Historical aot_prewarm script filenames are tooling names, not accepted commands. |

Verification includes the required Rust/Dart unit checks, the repository's full
stock comparisons and `scripts/correctness_upgrade.sh` (also in quick verify).
The upgrade probe seeds v8 flattened manifest, obsolete JSON graph and old cache
namespaces, checks regeneration and preservation, then compares clean/no-op/
incremental/per-key outputs with stock. Synthetic custom workers test missing or
mismatched version, wire version and required capability without changing
committed graph or generated outputs.
