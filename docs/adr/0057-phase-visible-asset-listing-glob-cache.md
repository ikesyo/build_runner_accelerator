# ADR 0057: Phase-visible package asset listing and worker-local glob cache

- Status: Accepted
- Date: 2026-11-27

## Context

After batching primary-input resolution (`resolve_assets`) and piggybacking
filesystem paths on positive disk-backed `can_read` responses, per-action
`find_assets` RPCs remain the dominant IPC round-trip source in multi-model
builds. On `fixtures/json_serializable_500_app` (500 models, `--jobs 1`, broad
edit), phase 1 (`source_gen:combining_builder`) issues 500 `find_assets` RPCs
(`lib/model_XXX.*.g.part`) out of 505 total `asset_requests`.

Within a single non-lazy phase, the set of visible existing assets in a package
is immutable until Rust commits phase outputs via `reset_resolver`: outputs
written by actions in the current phase remain hidden from all same-phase
actions, and no optional producers run mid-phase. Stock `build_runner` matches
globs locally against a sorted per-package index with literal-prefix binary
search (`BuildFileIndex`).

## Decision

- Protocol v1 gains a `list_visible_assets` asset operation taking `package`
  (plus the standard `build_id`, `phase`, and `kind` context). Rust collects
  all visible existing assets in that package under the exact same visibility,
  deletion, and existence rules as `find_assets`, strips the `"{package}|"`
  prefix, and returns `sources` and `generated` as two UTF-16-sorted lists of
  package-relative paths.
- Rust enforces the frame-size limit before sending and declines
  `list_visible_assets` with an error response during lazy, optional, or
  filtered demand builds (`handle_lazy_asset_request`), where globs must
  trigger optional producers only for matching patterns and observe newly
  materialized outputs mid-phase.
- The Dart worker caches the listing in `VisiblePackageAssetsCache`, keyed by
  `(package, phase, postProcess)` and bound by identity to the active
  `blockedAssets` set, and clears it on every `reset_resolver`, `reset`, and
  build start (and saves/restores it around `apiFingerprintQuery`).
- To avoid speculative listing overhead on 1-file incremental builds,
  `_RemoteAssetFinder` requests `list_visible_assets` only when executing a
  multi-request batch (`requests.length >= 2`) or starting on the second glob
  lookup in the same `(package, phase, postProcess)`, and only for simple POSIX
  globs (`*`, `**`, `?`, no character classes, braces, escapes, leading `/`, or
  `.`/`..` segments). On any decline, malformed answer, or complex pattern, it
  remembers the decline for that key and falls back to `find_assets`.
- Local matching binary-searches each sorted list by the glob's literal prefix
  before calling `Glob.matches` (normalized to case-sensitive POSIX context on
  non-POSIX hosts so results agree with Rust's `matches_glob`), emitting
  `sources` before `generated` and preserving `observedGlobs`,
  `observedGlobMembers`, `observedGlobResults`, and `readableCache` side
  effects unchanged.
- `BUILD_RUNNER_ACCELERATOR_GLOB_CACHE=0` disables the worker glob cache for
  diagnostics and A/B comparisons. Metrics expose
  `list_visible_assets_requests`/`list_visible_assets_results` on the Rust side
  and `ipc_list_visible_assets_calls/us` + `ipc_find_assets_cache_hits` on the
  Dart side.

## Consequences

- On `fixtures/json_serializable_500_app` (broad edit, `--jobs 1`, AOT),
  phase 1's 500 `find_assets` RPCs collapse to 1 `list_visible_assets` RPC
  (total `asset_requests` drops from 505 to 6; `ipc_frames_sent/received` drops
  from 511 to 12), while 1-file incremental builds incur zero
  `list_visible_assets` overhead.
- Binary search on UTF-16-sorted `sources` and `generated` lists keeps 500
  combining-builder globs $O(N \log N)$ rather than $O(N^2)$, with output order
  and dependency tracking byte-identical to `find_assets` and stock
  `build_runner`.
- Optional, filtered, post-process, and complex-glob builds keep exact
  per-glob `find_assets` behavior via server-side decline and worker fallback.
