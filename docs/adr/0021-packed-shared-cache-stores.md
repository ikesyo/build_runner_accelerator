# ADR 0021: Packed shared cache stores and digest-keyed dep lookups

- Status: Accepted
- Date: 2026-10-02

## Context

After ADR 0019 and ADR 0020, per-worker instrumentation of the riverpod
fixture (~880-file closure, warm caches) decomposes the first resolver action
roughly as:

- `cycle_graph_walk_us` ~0.53s: `dep_read_phased_us` ~0.29s (semantically
  required — see ADR 0019), `dep_parse_cache_us` ~0.17s, bookkeeping ~0.07s.
- `resolver_first_call_us.libraryFor` ~0.66s of which the walk is ~78%; the
  remainder is `libraryCycle`/`_loadBundle` (~0.11s): FileState refresh × 888
  dominated by unlinked-summary byte-store gets, then linked-bundle loads.
- Link work itself is zero warm — every `.linked`/`.unlinked2` byte-store key
  hits (ADR 0009).

Two residual costs share one shape: thousands of tiny per-key file operations.
The analyzer `FileByteStore` reads ~1250 keys per action (~62ms on this
machine — each get is an open/read/stat on a 6-20KB shard file), and the
ADR 0019 dep cache pays a sha256 over the full source text per looked-up file
(~0.1ms × ~880 ≈ ~90ms inside `dep_parse_cache_us`) plus a per-entry file
stat. Both are pure lookup overheads on content that is already in memory or
already hashed elsewhere.

## Decision

- Add `IndexedBlobStore` (`lib/src/indexed_blob_store.dart`): one append-only
  file per cache, records
  `[u32 keyLen][u32 valueLen][key][value][u16 fletcher16(value)]`. A reader
  holds one `RandomAccessFile` and an in-memory `key → (offset, len)` index
  built by a single sequential scan; a get is one seek+read plus a trailer
  checksum verify. A writer takes an exclusive file lock, re-parses bytes
  appended since its own scan (adopting complete records so two workers can
  append to the same pack), truncates a torn tail left by a killed writer,
  then appends. All failures degrade to the underlying per-key layout or to a
  cache miss — identical to stock behavior.
- The analyzer byte store uses `_PackedFileByteStore` in
  `lib/src/worker_resolvers.dart`: `get` probes the pack first and migrates a
  legacy `FileByteStore` hit into it, so existing ADR 0009 entries keep
  serving; `putGet` writes only to the pack. `FileByteStore` remains the
  fallback inside the same `<fingerprint>` directory.
- The ADR 0019 dep cache gets a `v2-<sdk>/store.bin` pack next to
  `v1-<sdk>/`; v1 entries are not migrated — a fresh v2 pack repopulates on
  first miss, which costs one cold reparse per SDK generation, same as the
  original v1 rollout.
- Dep-cache keys switch from `sha256("$assetId\n$content")` to
  `keyForDigest(id, contentHash)`: the md5 `contentHash` the analyzer's
  `FileContentCache` already paid for during `contentOf`. The loader reuses it
  only when the `FileContent` it finds is the *identical instance* whose
  `stringValue` it just read, which pins the hash to exactly the bytes being
  keyed; any absent, phantom, or non-identical content falls back to the
  sha256 key form. This eliminates the second full-text hash per dep file.
- `BUILD_RUNNER_ACCELERATOR_PACKED_STORE=0` restores both per-key layouts
  (v1 dep files + `FileByteStore`); `BUILD_RUNNER_ACCELERATOR_DEP_CACHE=0`
  still disables the dep cache entirely. Cache traffic splits further in
  metrics: `byte_store_gets_unlinked/linked/other` and `file_content_gets`
  report the `libraryFor`-internal shares on stderr only.

## Consequences

- On the fixture, warm steady state: `dep_parse_cache_us` ~170ms → ~10–17ms
  (sha256 eliminated), `byte_store_get_us` ~62–70ms → ~41–52ms,
  `cycle_graph_walk_us` ~530ms → ~350–390ms, `libraryFor` ~660ms →
  ~430–480ms; the riverpod action total drops ~1.47s → ~1.30s.
- The residual `libraryFor` cost is ~78% the dep walk (mostly required
  `readPhased` + content-hash bookkeeping) and ~0.11s of FileState refresh /
  bundle loads — analyzer-internal work with no remaining safe share.
- Concurrent appenders converge: records are self-validating by key and the
  checksum, a torn tail is truncated under the exclusive lock, and stale keys
  (different content hash / different byte-store key) are simply never read
  back — the pack is additive garbage only, same as the shard files.
- Cold builds append ~2k records (~18MB) under one lock each; the pack file
  is not part of the incremental graph and deleting the cache dir forfeits
  only warm benefit.
- Output compatibility is unchanged: packs change where cached bytes live,
  never what is resolved or emitted.
