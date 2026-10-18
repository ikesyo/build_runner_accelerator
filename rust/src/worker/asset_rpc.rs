use super::WorkerClient;
use super::lazy::{FilteredSourceContent, FilteredSourceObservation, FilteredSourceSpool};
use super::request::{BuildRequest, build_request_kind};
use crate::builder::{BuildTo, BuilderKind};
use crate::plan::BuildSpec;
use crate::protocol::{BINARY_ASSET_RESPONSE_MAGIC, MAX_FRAME_LENGTH};
use crate::visibility::AssetVisibility;
use crate::worker::LazyBuildState;
use crate::workspace::{Workspace, glob_candidates, matches_glob};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

pub(super) struct FilteredAssetEvidence<'a> {
    pub(super) lazy: &'a mut LazyBuildState,
    pub(super) lazy_specs: &'a BTreeMap<String, BuildSpec>,
}

impl WorkerClient {
    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub(super) fn handle_asset_request(
        &mut self,
        workspace: &Workspace,
        request: &Value,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
        active_request: &BuildRequest,
        expected_build_id: u64,
        mut filtered_evidence: Option<FilteredAssetEvidence<'_>>,
    ) -> io::Result<()> {
        validate_asset_request_context(request, active_request, expected_build_id)?;
        let _wall = self.wall_span("asset_rpc", None);
        let started = Instant::now();
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("asset request has no id"))?;
        let operation = request
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let phase = active_request.phase;
        let kind = build_request_kind(active_request);
        self.metrics.asset_requests += 1;
        let response = match operation {
            "read" => {
                self.metrics.read_requests += 1;
                let asset = request
                    .get("asset")
                    .and_then(Value::as_str)
                    .ok_or_else(|| io::Error::other("read request has no asset"))?;
                // Assets served from the filesystem are answered with their
                // absolute path so the worker reads the bytes itself; the
                // visibility and overlay decisions stay on the frontend. Only
                // in-memory overlay values travel as binary payloads.
                let read_result = if visibility.is_blocked(asset, phase, kind, deleted_overlay) {
                    Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        format!("asset not found: {asset}"),
                    ))
                } else {
                    if let Some(bytes) = overlay.get(asset) {
                        Ok(ReadResult::Bytes(Arc::clone(bytes)))
                    } else if let Some(evidence) = filtered_evidence.as_mut()
                        && evidence
                            .lazy
                            .is_untracked_filtered_source(asset, evidence.lazy_specs)
                    {
                        match observe_filtered_source(workspace, asset, visibility, evidence.lazy)?
                            .content
                        {
                            FilteredSourceContent::Bytes(bytes) => Ok(ReadResult::Bytes(bytes)),
                            FilteredSourceContent::Spool(spool) => {
                                Ok(ReadResult::Path(spool.path().to_path_buf()))
                            }
                            FilteredSourceContent::Missing => Err(io::Error::new(
                                io::ErrorKind::NotFound,
                                format!("asset not found: {asset}"),
                            )),
                        }
                    } else {
                        asset_disk_path(workspace, asset, visibility).map(ReadResult::Path)
                    }
                };
                match read_result {
                    Ok(ReadResult::Bytes(bytes)) => {
                        self.metrics.read_bytes += bytes.len() as u64;
                        self.metrics.binary_read_responses += 1;
                        let result = self.send_binary(
                            &json!({
                                "v": 1,
                                "type": "asset_response",
                                "id": id,
                                "ok": true,
                                "encoding": "raw",
                                "length": bytes.len(),
                            }),
                            bytes.as_ref(),
                        );
                        self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
                        return result;
                    }
                    Ok(ReadResult::Path(path)) => {
                        self.metrics.path_read_responses += 1;
                        json!({
                            "v": 1,
                            "type": "asset_response",
                            "id": id,
                            "ok": true,
                            "path": path.to_string_lossy(),
                        })
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        missing_asset_response(id, asset)
                    }
                    Err(error) => return Err(error),
                }
            }
            "resolve_assets" => {
                self.metrics.resolve_assets_requests += 1;
                let assets = request
                    .get("assets")
                    .and_then(Value::as_array)
                    .ok_or_else(|| io::Error::other("resolve_assets request has no assets"))?;
                // Batch form of `read`: each entry reports whether a single
                // `read` would answer with a filesystem path, in-memory
                // overlay bytes, or `not found`. `path`/`bytes` entries
                // therefore double as `can_read == true` for the batch,
                // letting the worker warm its read caches in one round-trip.
                let mut resolved = Vec::with_capacity(assets.len());
                let mut payload = Vec::new();
                for raw in assets {
                    let asset = raw.as_str().unwrap_or_default();
                    if asset.is_empty()
                        || visibility.is_blocked(asset, phase, kind, deleted_overlay)
                    {
                        resolved.push(json!({"status": "not_found"}));
                        continue;
                    }
                    if let Some(bytes) = overlay.get(asset) {
                        let offset = payload.len();
                        if !append_overlay_bytes(&mut payload, bytes, MAX_FRAME_LENGTH) {
                            let result = self.send(&oversized_resolve_assets_response(json!(id)));
                            self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
                            return result;
                        }
                        self.metrics.read_bytes += bytes.len() as u64;
                        resolved.push(json!({
                            "status": "bytes",
                            "offset": offset,
                            "length": bytes.len(),
                        }));
                        continue;
                    }
                    match asset_disk_path(workspace, asset, visibility) {
                        Ok(path) => resolved.push(json!({
                            "status": "path",
                            "path": path.to_string_lossy(),
                        })),
                        Err(error) if error.kind() == io::ErrorKind::NotFound => {
                            resolved.push(json!({"status": "not_found"}));
                        }
                        Err(error) => return Err(error),
                    }
                }
                self.metrics.resolve_assets_results += resolved.len() as u64;
                let mut response = json!({
                    "v": 1,
                    "type": "asset_response",
                    "id": id,
                    "ok": true,
                    "assets": resolved,
                });
                if !payload.is_empty() {
                    response["encoding"] = json!("raw");
                    response["length"] = json!(payload.len());
                }
                let response =
                    bounded_resolve_assets_response(response, payload.len(), MAX_FRAME_LENGTH)?;
                if payload.is_empty() || response["ok"] == false {
                    response
                } else {
                    self.metrics.binary_read_responses += 1;
                    let result = self.send_binary(&response, &payload);
                    self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
                    return result;
                }
            }
            "can_read" => {
                self.metrics.can_read_requests += 1;
                let asset = request
                    .get("asset")
                    .and_then(Value::as_str)
                    .ok_or_else(|| io::Error::other("can_read request has no asset"))?;
                let blocked = visibility.is_blocked(asset, phase, kind, deleted_overlay);
                let value = if blocked {
                    false
                } else if overlay.contains_key(asset) {
                    true
                } else if let Some(evidence) = filtered_evidence.as_mut()
                    && evidence
                        .lazy
                        .is_untracked_filtered_source(asset, evidence.lazy_specs)
                {
                    !matches!(
                        observe_filtered_source(workspace, asset, visibility, evidence.lazy)?
                            .content,
                        FilteredSourceContent::Missing
                    )
                } else {
                    asset_exists(workspace, asset, overlay, visibility)?
                };
                json!({ "v": 1, "type": "asset_response", "id": id, "ok": true, "value": value })
            }
            "find_assets" => {
                self.metrics.find_assets_requests += 1;
                let package = request
                    .get("package")
                    .and_then(Value::as_str)
                    .unwrap_or(&workspace.root_package);
                let pattern = request
                    .get("pattern")
                    .and_then(Value::as_str)
                    .unwrap_or("**");
                let mut assets = Vec::new();
                let candidates = workspace.find_assets(package, pattern)?;
                for asset in candidates.into_iter().chain(
                    visibility
                        .generated_assets(package, pattern)
                        .filter(|asset| {
                            asset.split_once('|').is_some_and(|(p, path)| {
                                p == package && matches_glob(pattern, path)
                            })
                        })
                        .cloned(),
                ) {
                    if visibility.is_blocked(asset.as_str(), phase, kind, deleted_overlay)
                        || !asset_exists(workspace, &asset, overlay, visibility)?
                    {
                        continue;
                    }
                    assets.push(asset);
                }
                for asset in glob_candidates(overlay, package, pattern) {
                    if !visibility.is_blocked(asset, phase, kind, deleted_overlay)
                        && let Some((asset_package, asset_path)) = asset.split_once('|')
                        && asset_package == package
                        && matches_glob(pattern, asset_path)
                    {
                        assets.push(asset.clone());
                    }
                }
                // Preserve stock glob membership order in ordinary results as
                // well, so an unfiltered -> filtered build can reuse them.
                assets.sort_by(|a, b| {
                    visibility
                        .location(a)
                        .is_some()
                        .cmp(&visibility.location(b).is_some())
                        .then_with(|| a.encode_utf16().cmp(b.encode_utf16()))
                });
                assets.dedup();
                self.metrics.find_assets_results += assets.len() as u64;
                json!({ "v": 1, "type": "asset_response", "id": id, "ok": true, "assets": assets })
            }
            _ => {
                json!({ "v": 1, "type": "asset_response", "id": id, "ok": false, "error": format!("unsupported asset operation: {operation}") })
            }
        };
        let result = self.send(&response);
        self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
        result
    }
}

/// Record the transaction's first observation of a source outside the
/// build-start snapshot. `can_read` and `read` across workers share this
/// observation, matching stock build-step source caching; filesystem I/O stays
/// outside the coordinator lock.
fn observe_filtered_source(
    workspace: &Workspace,
    asset: &str,
    visibility: &AssetVisibility,
    lazy: &mut LazyBuildState,
) -> io::Result<FilteredSourceObservation> {
    if let Some(observed) = lazy.shared_source_observation(asset) {
        return Ok(lazy.publish_source_observation(asset, observed));
    }
    let observed = match asset_disk_path(workspace, asset, visibility) {
        Ok(path) => {
            let bytes = match fs::read(path) {
                Ok(bytes) => bytes,
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    return Ok(lazy.publish_source_observation(asset, missing_source_observation()));
                }
                Err(error) => return Err(error),
            };
            let snapshot = crate::snapshot::AssetSnapshot {
                exists: true,
                digest: crate::digest::digest_bytes(&bytes),
                size: bytes.len() as u64,
            };
            let content = if asset_response_fits(bytes.len())? {
                FilteredSourceContent::Bytes(Arc::from(bytes))
            } else {
                FilteredSourceContent::Spool(spool_source_bytes(&bytes)?)
            };
            FilteredSourceObservation { content, snapshot }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => missing_source_observation(),
        Err(error) => return Err(error),
    };
    Ok(lazy.publish_source_observation(asset, observed))
}

fn missing_source_observation() -> FilteredSourceObservation {
    FilteredSourceObservation {
        content: FilteredSourceContent::Missing,
        snapshot: crate::snapshot::AssetSnapshot {
            exists: false,
            digest: crate::digest::digest_bytes(b"<missing>"),
            size: 0,
        },
    }
}

fn asset_response_fits(byte_length: usize) -> io::Result<bool> {
    let metadata = json!({
        "v": 1,
        "type": "asset_response",
        // The first observation is shared across workers and RPC ids. Budget
        // for the largest serialized id so its transport remains valid for
        // every request using this publication.
        "id": u64::MAX,
        "ok": true,
        "encoding": "raw",
        "length": byte_length,
    });
    let metadata_length = serde_json::to_vec(&metadata)
        .map_err(io::Error::other)?
        .len();
    Ok(BINARY_ASSET_RESPONSE_MAGIC
        .len()
        .checked_add(4)
        .and_then(|length| length.checked_add(metadata_length))
        .and_then(|length| length.checked_add(byte_length))
        .is_some_and(|length| length <= MAX_FRAME_LENGTH))
}

static NEXT_SOURCE_SPOOL: AtomicU64 = AtomicU64::new(0);

/// Stores a filtered-source snapshot on disk when its binary response exceeds
/// the IPC frame limit. Unix files are owner-only from their initial creation.
fn spool_source_bytes(bytes: &[u8]) -> io::Result<Arc<FilteredSourceSpool>> {
    let directory = std::env::temp_dir();
    for _ in 0..16 {
        let id = NEXT_SOURCE_SPOOL.fetch_add(1, Ordering::Relaxed);
        let path = directory.join(format!(
            "build-runner-accelerator-source-{}-{id}.tmp",
            std::process::id()
        ));
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = match options.open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        };
        if let Err(error) = file.write_all(bytes) {
            drop(file);
            let _ = fs::remove_file(&path);
            return Err(error);
        }
        return Ok(Arc::new(FilteredSourceSpool::new(path)));
    }
    Err(io::Error::other(
        "could not allocate a source snapshot spool",
    ))
}

// Reject an oversized optional prefetch before writing any frame bytes. Dart
// can then fall back to individual reads instead of losing its RPC session.
// Metadata-only responses need the same guard as overlay byte responses.
fn bounded_resolve_assets_response(
    response: Value,
    payload_length: usize,
    frame_limit: usize,
) -> io::Result<Value> {
    let metadata_length = serde_json::to_vec(&response)
        .map_err(io::Error::other)?
        .len();
    let overhead = if payload_length == 0 {
        0
    } else {
        BINARY_ASSET_RESPONSE_MAGIC.len() + 4
    };
    let length = metadata_length
        .checked_add(overhead)
        .and_then(|n| n.checked_add(payload_length));
    if length.is_none_or(|n| n > frame_limit) {
        Ok(oversized_resolve_assets_response(response["id"].clone()))
    } else {
        Ok(response)
    }
}

fn oversized_resolve_assets_response(id: Value) -> Value {
    json!({
        "v": 1,
        "type": "asset_response",
        "id": id,
        "ok": false,
        "error": "resolve_assets response exceeds frame limit",
    })
}

// Check before copying or growing the allocation. The final response check
// still accounts for metadata and binary framing overhead.
fn append_overlay_bytes(payload: &mut Vec<u8>, bytes: &[u8], limit: usize) -> bool {
    if payload
        .len()
        .checked_add(bytes.len())
        .is_none_or(|n| n > limit)
    {
        return false;
    }
    payload.extend_from_slice(bytes);
    true
}

fn asset_exists(
    workspace: &Workspace,
    asset: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    visibility: &AssetVisibility,
) -> io::Result<bool> {
    if overlay.contains_key(asset) {
        return Ok(true);
    }
    match visibility.location(asset) {
        Some(build_to) => workspace.asset_exists_at(asset, build_to),
        None => match workspace.source_path_for_asset(asset) {
            Ok(path) => Ok(path.is_file()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error),
        },
    }
}

fn asset_request_build_id(request: &Value) -> io::Result<u64> {
    request
        .get("build_id")
        .and_then(Value::as_u64)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "asset request has no build_id"))
}

pub(super) fn batch_asset_request_context<'a>(
    request: &Value,
    requests: &'a [BuildRequest],
) -> io::Result<(u64, &'a BuildRequest)> {
    let build_id = asset_request_build_id(request)?;
    let index = usize::try_from(build_id).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("asset request build_id is too large: {build_id}"),
        )
    })?;
    let active_request = requests.get(index).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("asset request build_id is out of range: {build_id}"),
        )
    })?;
    Ok((build_id, active_request))
}

pub(super) fn validate_asset_request_context(
    request: &Value,
    active_request: &BuildRequest,
    expected_build_id: u64,
) -> io::Result<()> {
    let build_id = asset_request_build_id(request)?;
    if build_id != expected_build_id {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "asset request build_id mismatch: expected {expected_build_id}, got {build_id}"
            ),
        ));
    }

    let phase = request
        .get("phase")
        .and_then(Value::as_u64)
        .and_then(|phase| u32::try_from(phase).ok())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "asset request has invalid phase",
            )
        })?;
    if phase != active_request.phase {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "asset request phase mismatch: expected {}, got {phase}",
                active_request.phase
            ),
        ));
    }

    let kind = match request.get("kind").and_then(Value::as_str) {
        Some("normal") => BuilderKind::Normal,
        Some("post_process") => BuilderKind::PostProcess,
        Some(kind) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("asset request has invalid kind: {kind}"),
            ));
        }
        None => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "asset request has no kind",
            ));
        }
    };
    let expected_kind = build_request_kind(active_request);
    if kind != expected_kind {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "asset request kind mismatch: expected {}, got {}",
                if expected_kind == BuilderKind::PostProcess {
                    "post_process"
                } else {
                    "normal"
                },
                if kind == BuilderKind::PostProcess {
                    "post_process"
                } else {
                    "normal"
                }
            ),
        ));
    }
    Ok(())
}

enum ReadResult {
    /// Bytes held only in the in-memory overlay; still sent as a binary frame.
    Bytes(Arc<[u8]>),
    /// Current bytes live at this absolute filesystem path; the worker reads
    /// them directly.
    Path(PathBuf),
}

/// Resolve a declared generated asset or an eligible package source.
fn asset_disk_path(
    workspace: &Workspace,
    asset: &str,
    visibility: &AssetVisibility,
) -> io::Result<PathBuf> {
    let path = match visibility.location(asset) {
        Some(BuildTo::Cache) => workspace.cache_path_for_asset(asset)?,
        Some(BuildTo::Source) => workspace.path_for_asset(asset)?,
        None => workspace.source_path_for_asset(asset)?,
    };
    if path.is_file() {
        Ok(path)
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("asset not found: {asset}"),
        ))
    }
}

pub(super) fn missing_asset_response(id: u64, asset: &str) -> Value {
    json!({
        "v": 1,
        "type": "asset_response",
        "id": id,
        "ok": false,
        "error": format!("asset not found: {asset}"),
    })
}

#[cfg(test)]
mod batch_response_tests {
    use super::*;

    #[test]
    fn overlay_batch_stops_before_allocating_or_copying_past_the_limit() {
        let mut payload = Vec::new();
        assert!(append_overlay_bytes(&mut payload, &[1, 2], 4));
        assert!(append_overlay_bytes(&mut payload, &[3, 4], 4));
        let capacity = payload.capacity();
        for bytes in [&[5][..], &[5, 6, 7, 8, 9][..]] {
            assert!(!append_overlay_bytes(&mut payload, bytes, 4));
            assert_eq!(payload, [1, 2, 3, 4]);
            assert_eq!(payload.capacity(), capacity);
        }
        let mut empty = Vec::new();
        assert!(!append_overlay_bytes(&mut empty, &[1, 2, 3, 4, 5], 4));
        assert!(empty.is_empty());
        assert_eq!(empty.capacity(), 0);
    }

    #[test]
    fn resolve_assets_checks_metadata_and_binary_overhead_at_the_limit() {
        let response = json!({"v": 1, "type": "asset_response", "id": 7, "ok": true,
            "assets": [{"status": "path", "path": "/app/lib/a.dart"}]});
        let metadata_length = serde_json::to_vec(&response).unwrap().len();
        for payload_length in [0, 32] {
            let length = metadata_length + payload_length + if payload_length == 0 { 0 } else { 8 };
            assert_eq!(
                bounded_resolve_assets_response(response.clone(), payload_length, length).unwrap(),
                response
            );
            let declined =
                bounded_resolve_assets_response(response.clone(), payload_length, length - 1)
                    .unwrap();
            assert_eq!(declined["ok"], false);
            assert_eq!(declined["id"], 7);
            assert_eq!(declined["type"], "asset_response");
            assert!(declined.get("assets").is_none());
        }
    }

    #[test]
    fn resolve_assets_declines_oversized_overlay_without_allocating_it() {
        let response = json!({"id": 9, "ok": true, "encoding": "raw"});
        for payload_length in [MAX_FRAME_LENGTH, usize::MAX] {
            let declined =
                bounded_resolve_assets_response(response.clone(), payload_length, MAX_FRAME_LENGTH)
                    .unwrap();
            assert_eq!(declined["ok"], false);
            assert_eq!(declined["id"], 9);
        }
    }

    #[test]
    fn filtered_source_read_accounts_for_binary_metadata_at_the_frame_limit() {
        let metadata = json!({
            "v": 1,
            "type": "asset_response",
            "id": u64::MAX,
            "ok": true,
            "encoding": "raw",
            // Use the maximum frame length's nine digits when measuring the
            // metadata overhead. The boundary payload length has the same
            // number of digits.
            "length": MAX_FRAME_LENGTH,
        });
        let overhead =
            BINARY_ASSET_RESPONSE_MAGIC.len() + 4 + serde_json::to_vec(&metadata).unwrap().len();
        let largest_payload = MAX_FRAME_LENGTH - overhead;
        assert!(asset_response_fits(largest_payload).unwrap());
        assert!(!asset_response_fits(largest_payload + 1).unwrap());
    }

    #[test]
    fn source_spool_lives_until_its_shared_observation_is_dropped() {
        let spool = spool_source_bytes(b"pinned source bytes").unwrap();
        let path = spool.path().to_path_buf();
        assert_eq!(fs::read(&path).unwrap(), b"pinned source bytes");
        drop(spool);
        assert!(!path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn source_spool_is_owner_only_when_created() {
        use std::os::unix::fs::PermissionsExt;

        let spool = spool_source_bytes(b"private source bytes").unwrap();
        let mode = fs::metadata(spool.path()).unwrap().permissions().mode();
        assert_eq!(mode & 0o077, 0);
    }
}
