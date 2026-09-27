# ADR 0010: Path-based asset reads

- Status: Accepted
- Date: 2026-09-26

## Context

Worker asset reads are served by the Rust frontend over framed IPC. Before
this decision every successful `read` returned the asset bytes in a `BRAB`
binary frame: the frontend resolved the asset to a filesystem path, read the
bytes itself, then copied them through the IPC pipe into the worker. On a
large workspace this makes the read path serialize hundreds of megabytes per
build (encoding, frame writes, pipe copies) even though worker and frontend
share the same filesystem.

## Decision

- A successful `read` response now takes two forms. When the asset's current
  bytes live on the filesystem — a package source file or the artifact-tree
  cache — the frontend replies with a JSON `asset_response` carrying the
  absolute `path`, and the worker reads the bytes directly. Only values held
  exclusively in the in-memory overlay continue to use the `BRAB` binary
  frame.
- The frontend keeps the entire authority over which physical path serves a
  logical ID: blocked-asset checks, overlay lookups, and the
  source-vs-artifact-tree `build_to` resolution are unchanged and happen
  before any path is returned. The worker never resolves locations itself; it
  only opens the path it was given.
- The path is resolved at request time against the transaction state, exactly
  where the previous byte read happened, so stale-path races are no wider
  than the previous read-then-send window. A `FileSystemException` on the
  worker side maps to `AssetNotFoundException`, matching the not-found
  response of the binary path.
- The per-Workspace shared `asset_read_cache` is no longer populated by
  worker reads; it remains in place for the frontend's own internal reads
  (digest and commit paths).

## Consequences

- IPC traffic for reads drops to small JSON frames (~243 MB of byte transport
  removed on the benchmark workspace); `asset_rpc_us` collapses to near zero
  and worker-side read cost becomes a direct filesystem read.
- Output compatibility is unchanged: the same bytes are returned, only the
  transport differs. Byte-identical output vs stock is preserved.
- Workers now require filesystem access to workspace paths. This is already
  true — workers run locally and read overlay spool files — but the protocol
  now states it explicitly in protocol/v1.md.
- `can_read`, `find_assets`, and error responses are unchanged.

## Alternatives considered

- Keep the binary read and add a negotiation capability so old workers keep
  byte frames: rejected; the protocol is still a PoC under active development
  and maintaining both transports doubles the read path for no consumer.
- Memory-map or FD-passing designs: rejected as needless complexity; a plain
  path + `File.readAsBytes` already removes the serialization cost.
