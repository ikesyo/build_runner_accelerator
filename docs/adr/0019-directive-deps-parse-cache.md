# ADR 0019: Content-keyed directive-deps parse cache

- Status: Accepted
- Date: 2026-10-02

## Context

Each worker's first resolver action walks the library cycle graph through
`AssetDepsLoader.load`: for every source file in the transitive import
closure it performs `BuilderFilesystem.readPhased` (asset `read` RPC +
disk read + UTF-8 decode) and then `parseString` to extract `import`,
`export`, `part`, and `part of` directives. The read half is semantically
required — `readPhased`'s `contentOf` side effects
(`buildState.updateSourceContent` + the `AnalysisDriverFilesystem` content
listener) are how dep-package file content reaches the analyzer's
in-memory filesystem, so no fast path may skip the read. The parse half,
however, is a pure function of `(importing asset id, decoded content)`:
identical inputs always produce identical `AssetDeps`, and every worker
re-parses the same dep-package files on every build.

Per-worker instrumentation (`BUILD_RUNNER_ACCELERATOR_METRICS=1`) shows
the walk is the dominant warm-start component: on the riverpod fixture
(~880-file closure) the stock walk costs ~1.0s per worker, of which the
re-parse is ~0.3s; the cost scales linearly with closure size, which is
what produced the observed 6–14s first-action cost on real workspaces.

## Decision

- `WorkerAnalysisDriverModel` installs `_CachingAssetDepsLoader`, an
  `AssetDepsLoader` subclass that keeps `readPhased` — including all of
  its visibility, read-tracking, and analyzer-filesystem side effects —
  verbatim, and caches only the parse result: the mapping from
  `(AssetId, content)` to `AssetDeps`.
- The cache lives on disk under
  `acceleratorCacheDirectory()/dep_parse/v1-<Platform.version>/` (the same
  machine-wide root as ADR 0012), keyed by
  `sha256("$assetId\n$content")`. The asset id is part of the key because
  relative directive URIs resolve against the importing file, so identical
  content in different assets must not share an entry. The SDK version in
  the directory name bounds the cache to one analyzer/feature-set
  generation.
- Entries are written atomically (tmp file + rename), are self-validating
  by construction (a key lookup can only return deps for exactly the same
  asset id and byte-identical content), and any read/write/decoding error
  degrades to a plain `parseString` — identical to stock behavior.
- Cache-hit `AssetDeps` keep their `ExpiringValue.expiresAfter` wrapper
  untouched, so phase semantics for generated assets are unchanged.
- `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` disables the cache entirely.
  Cache traffic (`dep_parse_cache_hits/misses/us`, `dep_read_phased_us`,
  `dep_parse_us`) is reported in the per-action metrics block.

## Consequences

- Warm cache: the per-file `parseString` (~1.3ms) drops to a sha256 +
  directory lookup (~0.2ms). On the riverpod fixture the walk goes from
  ~1.0s to ~0.75s per worker; the saving scales with closure size, and
  the cache is shared across workers and across builds.
- Reads are unchanged: `dep_read_phased_us` (~0.7s on the fixture) is
  now the residual walk cost and is semantically required — earlier
  attempts to skip or shortcut the read broke resolution because the
  analyzer's in-memory filesystem is populated exclusively through the
  `readPhased` → `contentOf` → content-listener path.
- Cold cache adds one atomic file write per parsed file (~0.1ms);
  correctness fixtures (`correctness_riverpod.sh`,
  `correctness_freezed.sh`) remain byte-identical to stock.

## Conditional import/export collection (2026-10-04)

Apply the same read-preserving, content-keyed parse reuse to
`collectResolverReads`, which supplements the ordinary cycle graph with all
conditional import/export alternatives. Existing `AssetDeps` values contain
only ordinary directive targets, so they cannot supply these alternatives.
Keep that format and cycle-graph behavior unchanged.

Persist the extracted, unresolved URI strings in a separate
`dep_parse/conditional-v1-<sdk>/store.bin` namespace using the shared indexed
store (ADR 0026). Keys bind the exact source bytes by SHA-256; SDK and extractor
version select the namespace. An extraction-semantics change bumps its version.
Because URI resolution happens afterward, package roots and importing asset
identity need not be part of the extraction key. Clear resolved in-memory
AssetIds on package-config changes and retain build/source-phase resets.

A hit still requires an action-visible byte read and its dependency recording.
Do not persist existence or conditional branch selection. Missing generated
assets remain observed dependencies and are retried on later actions;
rewrites change the content key. Failures fall back to extraction, and
`BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0` disables persistent reuse. Read and
full-content digest costs remain. On a miss, skip AST parsing if the required
`if` keyword is absent; otherwise use Analyzer's directive-only parser with
`parseString`'s feature/language-version settings. Keep full-unit parsing as
recovery for malformed or potentially misplaced directives. This avoids
building unrelated declaration ASTs without changing builders' resolvers.
Empty-cache publication still adds cost; see
[the paired measurements](../benchmarks/resolver-conditional-directives-2026-10.md)
for the fixture's improvements and limits.

## Collector digest lifetime (2026-10-04)

Keep the collector's content-only SHA-256 on an owned immutable byte snapshot
in the worker's existing read cache. Copy input buffers on insertion and expose
an unmodifiable typed byte view. Public builder reads still return mutable
copies. The collector reads the snapshot through the same action visibility,
post-process primary-input restriction and observed-read path before accessing
its lazy digest; it no longer copies and hashes shared cached bytes per action.
The ReaderWriter MD5 includes the AssetId and cannot serve this content key.
build_runner's `AssetContent.digest` is also MD5; `withBytes` can carry an old
digest onto replacement bytes by design. Neither provides the collector's
exact-byte SHA-256 guarantee. Rust snapshot digests are not carried by the
asset-read protocol, so this change does not expand that protocol. SHA-256
keys and the persistent raw-URI schema stay identical; no persistent namespace
change is needed.

Replacement always creates a new snapshot, even for the same caller buffer or
equal bytes. Removal and clear discard bytes and digest together: the existing
updated/deleted source/cache deltas evict changed IDs on resolver resets, and
build start/failure recovery clear the cache. Unchanged entries may survive an
incremental resolver reset. No digest persists beyond its byte entry or crosses
worker processes. There is no AssetId/mtime/object-identity validity shortcut.

Action-local outputs are mutable and separate from the shared cache. Reading
them creates a fresh snapshot and hashes it, so a same-phase or post-process
rewrite cannot reuse an earlier output digest. Missing/blocked assets do not
yield a snapshot or digest; generated assets are retried under each action's
visibility. Conditional URI resolution and dependency recording are unchanged.
