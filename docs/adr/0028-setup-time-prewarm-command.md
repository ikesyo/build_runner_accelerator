# ADR 0028: Setup-time `prewarm` command and single-flight worker AOT compiles

- Status: Accepted
- Date: 2026-10-07

## Context

The one-time worker AOT compile (~25-30s on a large workspace) is the last
serial cost of a fully cold `build`: manifest generation, worker selection,
and `dart compile exe` of the generated entrypoint run inside the first
build's critical path. `aot-prewarm` already drives exactly that pipeline for
CI cache warming (ADR 0011), but it was a binary-level detail: the public
`dart run build_runner_accelerator` launcher did not surface it, it could not
detach, and nothing stopped two processes from compiling the same key at the
same time.

Two properties make setup-time warming safe to build on:

- All produced artifacts are content-keyed: the builder-manifest fingerprint,
  the AOT cache key (SDK, worker source, manifest, lockfile, package-config
  identity), the probe cache, and the shared byte-store fingerprint. A
  pubspec.lock, SDK, or build.yaml change between `prewarm` and `build`
  simply changes the key — the prewarmed artifact misses and the normal
  compile runs. There is no explicit invalidation protocol to get wrong.
- Prewarm writes only caches, never build outputs, so generated-file
  byte-identity is unaffected.

## Decision

- `prewarm` becomes the canonical command name on the launcher and the
  native binary; `aot-prewarm` stays accepted at the binary level for
  existing CI tooling. `prewarm` runs the shared pipeline — manifest
  generation, worker selection, AOT compile, analysis shards — so it cannot
  drift from what `build` warms.
- `prewarm --background` detaches: the launcher-side invocation returns
  immediately while a copy of the binary (new process group, lowered
  scheduling priority — `nice` on Unix, `BELOW_NORMAL_PRIORITY_CLASS` on
  Windows) runs the foreground pipeline with output to
  `.dart_tool/build_runner_accelerator/prewarm.log`.
- The workspace-local lock `.aot-background.lock` — previously only
  serialized `watch`'s background-compile spawns — now serializes all worker
  AOT compiles in `prepare_worker_aot`. A compiler that finds the lock
  waits, bounded, for the winner's atomically published artifact
  (temp-file + rename publish already makes a fresh artifact appear
  whole); on timeout, stale lock, or a lock holder that ends without
  publishing, it compiles itself. A second `prewarm --background` observes
  the lock and exits as a no-op.
- `prewarm` is a setup hook, not a contract. Under `--mode dart`, or in
  `auto` when the native binary or a compatible manifest is unavailable,
  it reports on stderr and exits 0: a `pub get` hook must not fail for
  lack of a frontend. `--mode rust` keeps strict semantics.
- `--background` is scoped to `prewarm`; other commands reject it.

## Consequences

- A developer's first `build` after `dart pub get` finds every cache warm
  when `prewarm` has finished; the compile the build would have paid is
  hidden inside dependency-resolution wall time. When prewarm is still
  running, the build waits on the lock instead of duplicating the compile —
  total work is identical and the build's reported compile time still
  approaches zero.
- Duplicate compiles remain possible in one narrow window (a loser whose
  bounded wait expires); last-writer-wins publish keeps that safe, only
  wasteful.
- The detached child's lifecycle is intentionally unmanaged: no pidfile,
  no cancellation command. The lock file doubles as the liveness record
  (stale-detection bound: 1h) and the log file as its output.
- The compile itself is at its floor. `dart compile exe` has no incremental
  mode and the generated worker is one entrypoint, so nothing inside the
  compile can be made cheaper at constant output. The measured cold-path
  budget (compile ≈ 22s of a ~46s cold build) therefore only yields to the
  two levers this ADR already uses — not paying it (content-keyed cache) and
  paying it invisibly (setup-time prewarm). Making the cold path faster than
  that would require a different artifact class (a JIT/kernel worker, which
  exists as the fallback and trades worker startup speed) or distributing
  prebuilt artifacts across machines; both are separate durable decisions,
  not refinements of `prewarm`.
