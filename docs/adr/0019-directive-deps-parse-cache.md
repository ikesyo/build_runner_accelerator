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
