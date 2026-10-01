# ADR 0018: Cross-workspace manifest kernel reuse and a shared SDK summary lock

- Status: Accepted
- Date: 2026-10-01

## Context

ADR 0015 keys the generator kernel cache on the absolute package-config path
and contents. The cache directory is machine-wide (ADR 0012) but the key made
each slot workspace-private: a second checkout or workspace with identical
dependency resolution always missed and paid the ~10 s compile. On a warm
machine — worker AOT already shared (ADR 0014) and the probe reduced to a
cached-executor launch — the kernel compile is the dominant serial segment of
manifest regeneration, so the per-workspace key wasted the only real win the
machine cache could offer.

Separately, `.dart_tool/build_resolvers/sdk.sum` is rebuilt by every worker
process on a cold workspace (~1.3–1.5 s each at 4 workers) because
build_runner's `defaultSdkSummaryGenerator` holds no lock. ADR 0017 gave
prewarm shards a `.sdk-summary.lock`; workers still raced.

## Decision

- The manifest-kernel key replaces the package-config path/content slot with
  a **package-resolution digest**: a digest of the config content with the
  workspace's own package entry removed (that entry alone embeds the checkout
  path, and the generator never imports the workspace's own libraries) plus a
  sorted digest of the canonicalized directories every remaining `rootUri`
  resolves to — relative `../` and `file://` forms alike. Kernel files embed
  absolute `file://` source URIs, so identical resolution is the correct
  equality: two workspaces whose deps resolve to the same directories produce
  the same kernel, and a config that merely shares text but resolves
  elsewhere still misses. A config that cannot be parsed falls back to the
  previous path-anchored keying. The key format is bumped to
  `manifest-kernel-v2-*`; stale v1 entries age out in place.
- Worker resolver initialization resolves the SDK summary through the same
  `.sdk-summary.lock` protocol the prewarm shards use (exclusive-create
  lockfile, 250 ms poll, three-minute bound, two-minute max-age reclaim). On
  a cold `sdk.sum` the first worker generates while the rest wait; waiters
  then read the published file directly. The lock wait and post-lock work are
  recorded in the resolver profile's previously zero-valued
  `sdk_summary_lock_wait_us` / `sdk_summary_after_lock_us` fields.
- The early-AOT staging directory is re-asserted immediately before the
  `dart compile exe` spawn. A race had produced `PathNotFoundException` on
  the `.tmp.aot` output write, degrading a ~19 s compile into a ~30 s
  graceful fallback.

## Consequences

- A second workspace with identical dependency resolution on a warm machine
  skips the ~10 s kernel compile entirely. Measured on
  `fixtures/json_serializable_10_app` (Dart 3.13.4, 8 cores): fresh-workspace
  build with warm machine cache 10.4 s → 0.8 s wall; outputs byte-identical.
- Pub workspaces and `path:` deps that resolve to different checkouts key
  separately, so reuse is bounded to genuinely identical resolution.
- Worker SDK summary generation is single-flight per workspace; warm
  workspaces pay one `File.exists` check. Concurrent prewarm shards and
  workers now honor one lock file.
- Correctness is preserved: depfile digests still validate kernel sources on
  every hit, outputs remain byte-identical to stock, and every failure path
  degrades to the previous behavior.
