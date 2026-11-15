# ADR 0054: Frontend asset digests for worker cache keying

- Status: Accepted
- Date: 2026-11-15
- Extends: ADRs 0009, 0012 and 0053

## Context

A wall trace of v0.19.4 on a large single-package application (recorded
in the v0.19.4 reporter reports) shows the first resolver action on each
worker spending about 3 s before builder code runs:

- `cycle_graph_walk_us` about 1.1 s over 7,158 dep loads. The
  content-keyed `AssetDepsCache` already serves the directive parse for
  warm files, but the loader must still fetch, decode and hash every
  file's content through `readPhased` to form the cache key and build
  the phased values.
- `resolver_reads_digest_us` about 0.8 s over 6,582 assets with
  `resolver_reads_digest_reuses = 0`. `collectResolverReads` reads every
  observed asset and computes its content digest in the worker to key
  the conditional-directive caches, even when the persistent store is
  warm.

Both costs repeat per worker and per build, and each additional worker
pays them again, which is most of why `--jobs` scales poorly on
whole-graph builders. The frontend already reads and hashes every
source file for its build snapshot, but its digests cannot key the
worker's caches: the frontend hashes with BLAKE3 and the worker's
content-keyed caches use SHA-256.

## Decision

Unify on BLAKE3. The frontend's internal digest (`digest_bytes`) is
unchanged. The worker's content-keyed caches switch their digest from
SHA-256 to BLAKE3, so the frontend's snapshot digest of a file is
identical to the digest keying the worker's resolver-read and
directive-parse caches. Both stores are disposable caches, so the
switch is a generation bump, not a migration: the `AssetDepsCache`
packed store moves from `v3` to `v4` and the conditional-directive
store from `conditional-v1` to `conditional-v2`, and entries written
under SHA-256 keys are never read again. SHA-256 stays where it is an
external contract (release artifact checksums) or an independent
identity that never has to match a frontend digest (the Analyzer
byte-store fingerprint, probe cache keys).

`package:crypto` has no BLAKE3, so the worker carries the unkeyed hash
in `lib/src/blake3.dart`, implemented from the specification and
pinned by reference test vectors across block, chunk and tree
boundaries. Pure-Dart BLAKE3 measures faster than `package:crypto`
SHA-256 on source-file-sized inputs, so the digests the worker still
computes itself do not get slower either.

The alternative of moving the frontend to SHA-256 was implemented and
rejected on measurement: the frontend hashes tens of megabytes per
build across its scans, dependency closures and AOT validation, and
SHA-256 throughput made warm builds about 2 s slower on the benchmark
host while removing the same worker cost. Unifying on the faster hash
avoids paying that cost on either side.

Advertise `asset-digests-v1`. When the worker advertises it,
`build_batch` messages may carry `asset_digests`, a delta of the
frontend's current source digests:

- The frontend stages one digest map per build: every snapshot asset
  that exists and is not a declared output of any action in the build,
  keyed by asset id, with the bare BLAKE3 hex as the value. Declared
  outputs are excluded because their current content is overlay state,
  not snapshot state. Placeholder and glob snapshot keys are not real
  assets and are excluded.
- The client diffs the staged map against the digests this connection
  has already received and attaches only the delta: updates as
  id-to-digest entries and removals as id-to-null entries. In interned
  messages the keys are dictionary indexes in decimal string form, as
  with the overlay blob index; otherwise they are asset ids. The delta
  is computed while the message is encoded, and if the send fails the
  client's sent-digest state rolls back together with the asset
  dictionary (the discipline of ADR 0053), so the two sides cannot
  diverge on a live connection.
- The worker mirrors the map next to its asset dictionary.
  Initialization clears it; builds and resolver resets leave it intact
  except for the deltas messages carry.

Workers use a frontend digest as a lookup key only. Cache entries are
stored exclusively under digests the worker computed itself from the
bytes it read, so an entry can never be bound to content the worker did
not hash. A lookup hit therefore means: some worker hashed exactly
these bytes and recorded the result, and the frontend asserts the
current snapshot hashes to the same value.

- `collectResolverReads`: for an asset with a frontend digest and no
  committed or worker-produced content in the current build, the
  conditional-dependency caches are consulted under that digest before
  the asset is read. On a hit the read is skipped: the asset is already
  in the action's observed reads, and discovered dependencies are
  recorded exactly as the read path records them. On a miss the
  current read/scan path runs and stores under the worker-computed
  digest.
- Cycle-graph dep loads: for an asset with a frontend digest,
  `AssetDepsCache` is consulted under the `asset id + digest` key
  before `readPhased`. On a hit the load still performs `readPhased`,
  because that call is also the Analyzer's content feed: skipping it
  leaves the driver without the library's content after a resolver
  reset, and annotations in it stop resolving. The hit only skips
  forming the key from the content and parsing it, returning the
  cached deps as a fixed phased value and prefetching the revealed
  frontier exactly as the read path does. On a miss the current path
  runs; when the BLAKE3 the worker computes over the content it read
  equals the frontend digest, the parsed deps are also stored under
  the digest key, which is what warms it.

Single `build` messages and asset RPC traffic carry no digests, the
same scoping as ADR 0053. Assets without a frontend digest (generated
assets, workers without the capability) keep the current paths
unchanged.

## Snapshot semantics

Digests describe the frontend's build snapshot, the same source of
truth as dirty checking, and sources are already assumed stable while
a build runs. If a source file is edited mid-build, a digest lookup
can serve the snapshot's dep entry for an asset whose bytes the
Analyzer later reads in their newer form, the same skew stock
build_runner has between its dep parse and its analysis reads. The
skew is confined to that build: the next build's snapshot hashes the
changed file, its digest differs from the graph's recorded digest, and
its actions re-run with fresh entries. Publication remains gated by
the frontend's graph, whose source digests are these same values.

## Expected effect

On the traced application, most of the per-worker first-action hashing
(about 0.8 s) and the cycle walk's content reads for cache-warm files
(about 1.1 s) disappear from every build, and additional workers stop
re-paying them. The frontend pays nothing new: the digests are the
ones its snapshot already computes, and the per-build transport cost
is one digest delta keyed by interned asset ids.
