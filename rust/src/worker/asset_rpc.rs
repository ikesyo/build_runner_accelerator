use super::WorkerClient;
use super::demand::{FilteredSourceContent, FilteredSourceObservation, FilteredSourceSpool};
use super::request::{BuildRequest, build_request_kind};
use crate::builder::{BuildTo, BuilderKind};
use crate::plan::BuildSpec;
use crate::protocol::{BINARY_ASSET_RESPONSE_MAGIC, MAX_FRAME_LENGTH};
use crate::visibility::AssetVisibility;
use crate::worker::LazyBuildState;
use crate::workspace::{Workspace, asset_matches_glob, glob_candidates};
use serde::Serialize;
use serde_json::Value;
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

const ASSET_RESPONSE_TYPE: &str = "asset_response";
const OVERSIZED_RESOLVE_ASSETS_ERROR: &str = "resolve_assets response exceeds frame limit";
const OVERSIZED_LIST_VISIBLE_ASSETS_ERROR: &str =
    "list_visible_assets response exceeds frame limit";

#[derive(Serialize)]
struct BinaryReadResponse {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    encoding: &'static str,
    length: usize,
}

#[derive(Serialize)]
struct PathReadResponse<'a> {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    path: Cow<'a, str>,
}

#[derive(Serialize)]
struct CanReadResponse<'a> {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    value: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<Cow<'a, str>>,
}

#[derive(Serialize)]
struct FindAssetsResponse<'a> {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    assets: &'a [String],
}

#[derive(Serialize)]
struct ListVisibleAssetsResponse<'a> {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    sources: &'a [String],
    generated: &'a [String],
}

#[derive(Serialize)]
struct AssetErrorResponse<'a> {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    error: &'a str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum ResolvedAssetEntry {
    Path { path: String },
    Bytes { offset: usize, length: usize },
    NotFound,
}

#[derive(Serialize)]
struct ResolveAssetsResponse<'a> {
    v: u32,
    #[serde(rename = "type")]
    message_type: &'static str,
    id: u64,
    ok: bool,
    assets: &'a [ResolvedAssetEntry],
    #[serde(skip_serializing_if = "Option::is_none")]
    encoding: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    length: Option<usize>,
}

fn binary_read_response(id: u64, length: usize) -> BinaryReadResponse {
    BinaryReadResponse {
        v: 1,
        message_type: ASSET_RESPONSE_TYPE,
        id,
        ok: true,
        encoding: "raw",
        length,
    }
}

fn asset_error_response(id: u64, error: &str) -> AssetErrorResponse<'_> {
    AssetErrorResponse {
        v: 1,
        message_type: ASSET_RESPONSE_TYPE,
        id,
        ok: false,
        error,
    }
}

fn resolve_assets_response(
    id: u64,
    assets: &[ResolvedAssetEntry],
    payload_length: usize,
) -> ResolveAssetsResponse<'_> {
    ResolveAssetsResponse {
        v: 1,
        message_type: ASSET_RESPONSE_TYPE,
        id,
        ok: true,
        assets,
        encoding: (payload_length > 0).then_some("raw"),
        length: (payload_length > 0).then_some(payload_length),
    }
}

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
        let result = match operation {
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
                } else if let Some(bytes) = overlay.get(asset) {
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
                };
                match read_result {
                    Ok(ReadResult::Bytes(bytes)) => {
                        self.metrics.read_bytes += bytes.len() as u64;
                        self.metrics.binary_read_responses += 1;
                        let metadata = binary_read_response(id, bytes.len());
                        self.send_binary(&metadata, bytes.as_ref())
                    }
                    Ok(ReadResult::Path(path)) => {
                        self.metrics.path_read_responses += 1;
                        let response = PathReadResponse {
                            v: 1,
                            message_type: ASSET_RESPONSE_TYPE,
                            id,
                            ok: true,
                            path: path.to_string_lossy(),
                        };
                        self.send_serialized(&response)
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        let message = format!("asset not found: {asset}");
                        self.send_serialized(&asset_error_response(id, &message))
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
                let mut oversized = false;
                for raw in assets {
                    let asset = raw.as_str().unwrap_or_default();
                    if asset.is_empty()
                        || visibility.is_blocked(asset, phase, kind, deleted_overlay)
                    {
                        resolved.push(ResolvedAssetEntry::NotFound);
                        continue;
                    }
                    if let Some(bytes) = overlay.get(asset) {
                        let offset = payload.len();
                        if !append_overlay_bytes(&mut payload, bytes, MAX_FRAME_LENGTH) {
                            oversized = true;
                            break;
                        }
                        self.metrics.read_bytes += bytes.len() as u64;
                        resolved.push(ResolvedAssetEntry::Bytes {
                            offset,
                            length: bytes.len(),
                        });
                        continue;
                    }
                    match asset_disk_path(workspace, asset, visibility) {
                        Ok(path) => resolved.push(ResolvedAssetEntry::Path {
                            path: path.to_string_lossy().into_owned(),
                        }),
                        Err(error) if error.kind() == io::ErrorKind::NotFound => {
                            resolved.push(ResolvedAssetEntry::NotFound);
                        }
                        Err(error) => return Err(error),
                    }
                }
                if oversized {
                    self.send_serialized(&asset_error_response(id, OVERSIZED_RESOLVE_ASSETS_ERROR))
                } else {
                    self.metrics.resolve_assets_results += resolved.len() as u64;
                    let response = resolve_assets_response(id, &resolved, payload.len());
                    if !resolve_assets_response_fits(&response, payload.len(), MAX_FRAME_LENGTH)? {
                        self.send_serialized(&asset_error_response(
                            id,
                            OVERSIZED_RESOLVE_ASSETS_ERROR,
                        ))
                    } else if payload.is_empty() {
                        self.send_serialized(&response)
                    } else {
                        self.metrics.binary_read_responses += 1;
                        self.send_binary(&response, &payload)
                    }
                }
            }
            "can_read" => {
                self.metrics.can_read_requests += 1;
                let asset = request
                    .get("asset")
                    .and_then(Value::as_str)
                    .ok_or_else(|| io::Error::other("can_read request has no asset"))?;
                let resolved = resolve_can_read(
                    workspace,
                    asset,
                    overlay,
                    deleted_overlay,
                    visibility,
                    phase,
                    kind,
                    filtered_evidence,
                )?;
                let response = can_read_response(id, &resolved);
                self.send_serialized(&response)
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
                // Preserve stock glob membership order in ordinary results as
                // well, so an unfiltered -> filtered build can reuse them.
                let assets = collect_glob_members(
                    workspace,
                    package,
                    pattern,
                    overlay,
                    deleted_overlay,
                    visibility,
                    phase,
                    kind,
                    |asset| visibility.location(asset).is_some(),
                    |asset| asset_exists(workspace, asset, overlay, visibility),
                )?;
                self.metrics.find_assets_results += assets.len() as u64;
                self.send_serialized(&FindAssetsResponse {
                    v: 1,
                    message_type: ASSET_RESPONSE_TYPE,
                    id,
                    ok: true,
                    assets: &assets,
                })
            }
            "list_visible_assets" => {
                self.metrics.list_visible_assets_requests += 1;
                let package = request
                    .get("package")
                    .and_then(Value::as_str)
                    .unwrap_or(&workspace.root_package);
                let (sources, generated) = collect_visible_package_paths(
                    workspace,
                    package,
                    overlay,
                    deleted_overlay,
                    visibility,
                    phase,
                    kind,
                )?;
                let response = ListVisibleAssetsResponse {
                    v: 1,
                    message_type: ASSET_RESPONSE_TYPE,
                    id,
                    ok: true,
                    sources: &sources,
                    generated: &generated,
                };
                if !list_visible_assets_response_fits(&response, MAX_FRAME_LENGTH)? {
                    self.send_serialized(&asset_error_response(
                        id,
                        OVERSIZED_LIST_VISIBLE_ASSETS_ERROR,
                    ))
                } else {
                    self.metrics.list_visible_assets_results +=
                        (sources.len() + generated.len()) as u64;
                    self.send_serialized(&response)
                }
            }
            _ => {
                let message = format!("unsupported asset operation: {operation}");
                self.send_serialized(&asset_error_response(id, &message))
            }
        };
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

struct CountingWriter(usize);

impl Write for CountingWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0 += buf.len();
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn serialized_json_len<T: Serialize>(value: &T) -> io::Result<usize> {
    let mut counter = CountingWriter(0);
    serde_json::to_writer(&mut counter, value).map_err(io::Error::other)?;
    Ok(counter.0)
}

fn asset_response_fits(byte_length: usize) -> io::Result<bool> {
    // The first observation is shared across workers and RPC ids. Budget
    // for the largest serialized id so its transport remains valid for
    // every request using this publication.
    let metadata_length = serialized_json_len(&binary_read_response(u64::MAX, byte_length))?;
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
fn resolve_assets_response_fits<T: Serialize>(
    response: &T,
    payload_length: usize,
    frame_limit: usize,
) -> io::Result<bool> {
    let metadata_length = serialized_json_len(response)?;
    let overhead = if payload_length == 0 {
        0
    } else {
        BINARY_ASSET_RESPONSE_MAGIC.len() + 4
    };
    let length = metadata_length
        .checked_add(overhead)
        .and_then(|n| n.checked_add(payload_length));
    Ok(length.is_some_and(|n| n <= frame_limit))
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

fn list_visible_assets_response_fits<T: Serialize>(
    response: &T,
    frame_limit: usize,
) -> io::Result<bool> {
    Ok(serialized_json_len(response)? <= frame_limit)
}

#[expect(
    clippy::too_many_arguments,
    reason = "Glob results use the same phase-aware transaction view as asset RPC"
)]
fn collect_glob_member_parts(
    workspace: &Workspace,
    package: &str,
    pattern: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    deleted: &BTreeSet<String>,
    visibility: &AssetVisibility,
    phase: u32,
    kind: BuilderKind,
    is_generated: impl Fn(&str) -> bool,
    exists: impl Fn(&str) -> io::Result<bool>,
) -> io::Result<(Vec<String>, Vec<String>)> {
    let mut candidates: BTreeSet<String> = workspace
        .find_assets(package, pattern)?
        .into_iter()
        .chain(visibility.generated_assets(package, pattern).cloned())
        .collect();
    candidates.extend(
        glob_candidates(overlay, package, pattern)
            .filter(|asset| asset_matches_glob(asset, package, pattern))
            .cloned(),
    );
    let mut sources = Vec::new();
    let mut generated = Vec::new();
    for asset in candidates {
        if visibility.is_blocked(&asset, phase, kind, deleted) || !exists(&asset)? {
            continue;
        }
        if is_generated(&asset) {
            generated.push(asset);
        } else {
            sources.push(asset);
        }
    }
    // AssetId.compareTo uses Dart String ordering (UTF-16 code units).
    sources.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    generated.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    Ok((sources, generated))
}

#[expect(
    clippy::too_many_arguments,
    reason = "Glob results use the same phase-aware transaction view as asset RPC"
)]
pub(super) fn collect_glob_members(
    workspace: &Workspace,
    package: &str,
    pattern: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    deleted: &BTreeSet<String>,
    visibility: &AssetVisibility,
    phase: u32,
    kind: BuilderKind,
    is_generated: impl Fn(&str) -> bool,
    exists: impl Fn(&str) -> io::Result<bool>,
) -> io::Result<Vec<String>> {
    let (mut sources, generated) = collect_glob_member_parts(
        workspace,
        package,
        pattern,
        overlay,
        deleted,
        visibility,
        phase,
        kind,
        is_generated,
        exists,
    )?;
    sources.extend(generated);
    Ok(sources)
}

fn collect_visible_package_paths(
    workspace: &Workspace,
    package: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    deleted: &BTreeSet<String>,
    visibility: &AssetVisibility,
    phase: u32,
    kind: BuilderKind,
) -> io::Result<(Vec<String>, Vec<String>)> {
    let (sources, generated) = collect_glob_member_parts(
        workspace,
        package,
        "**",
        overlay,
        deleted,
        visibility,
        phase,
        kind,
        |asset| visibility.location(asset).is_some(),
        |asset| asset_exists(workspace, asset, overlay, visibility),
    )?;
    let prefix = format!("{package}|");
    let strip = |assets: Vec<String>| -> Vec<String> {
        assets
            .into_iter()
            .filter_map(|asset| asset.strip_prefix(&prefix).map(str::to_owned))
            .collect()
    };
    Ok((strip(sources), strip(generated)))
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

#[derive(Debug, PartialEq, Eq)]
enum CanReadResult {
    Missing,
    /// Readable, but current bytes are held only in memory (overlay or
    /// filtered snapshot bytes), so the worker must use `read` to fetch them.
    MemoryOnly,
    /// Readable and backed by this absolute filesystem path (source, cache, or
    /// spooled filtered snapshot); the worker may read it directly.
    Path(PathBuf),
}

#[expect(
    clippy::too_many_arguments,
    reason = "can_read checks the same phase-aware visibility and transaction state as read"
)]
fn resolve_can_read(
    workspace: &Workspace,
    asset: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    deleted_overlay: &BTreeSet<String>,
    visibility: &AssetVisibility,
    phase: u32,
    kind: BuilderKind,
    mut filtered_evidence: Option<FilteredAssetEvidence<'_>>,
) -> io::Result<CanReadResult> {
    if visibility.is_blocked(asset, phase, kind, deleted_overlay) {
        return Ok(CanReadResult::Missing);
    }
    if overlay.contains_key(asset) {
        return Ok(CanReadResult::MemoryOnly);
    }
    if let Some(evidence) = filtered_evidence.as_mut()
        && evidence
            .lazy
            .is_untracked_filtered_source(asset, evidence.lazy_specs)
    {
        return Ok(
            match observe_filtered_source(workspace, asset, visibility, evidence.lazy)?.content {
                FilteredSourceContent::Missing => CanReadResult::Missing,
                // Keep in-memory filtered snapshots on the binary read path so
                // the worker cannot bypass the frozen bytes via a live disk path.
                FilteredSourceContent::Bytes(_) => CanReadResult::MemoryOnly,
                FilteredSourceContent::Spool(spool) => {
                    CanReadResult::Path(spool.path().to_path_buf())
                }
            },
        );
    }
    match asset_disk_path(workspace, asset, visibility) {
        Ok(path) => Ok(CanReadResult::Path(path)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(CanReadResult::Missing),
        Err(error) => Err(error),
    }
}

fn can_read_response(id: u64, result: &CanReadResult) -> CanReadResponse<'_> {
    match result {
        CanReadResult::Missing => CanReadResponse {
            v: 1,
            message_type: ASSET_RESPONSE_TYPE,
            id,
            ok: true,
            value: false,
            path: None,
        },
        CanReadResult::MemoryOnly => CanReadResponse {
            v: 1,
            message_type: ASSET_RESPONSE_TYPE,
            id,
            ok: true,
            value: true,
            path: None,
        },
        CanReadResult::Path(path) => CanReadResponse {
            v: 1,
            message_type: ASSET_RESPONSE_TYPE,
            id,
            ok: true,
            value: true,
            path: Some(path.to_string_lossy()),
        },
    }
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

#[cfg(test)]
pub(super) fn missing_asset_response(id: u64, asset: &str) -> Value {
    let message = format!("asset not found: {asset}");
    serde_json::to_value(asset_error_response(id, &message)).expect("serialize missing response")
}

#[cfg(test)]
mod batch_response_tests {
    use super::*;
    use serde_json::json;

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
        let entries = [ResolvedAssetEntry::Path {
            path: "/app/lib/a.dart".to_string(),
        }];
        for payload_length in [0, 32] {
            let response = resolve_assets_response(7, &entries, payload_length);
            let metadata_length = serde_json::to_vec(&response).unwrap().len();
            let length = metadata_length + payload_length + if payload_length == 0 { 0 } else { 8 };
            assert!(resolve_assets_response_fits(&response, payload_length, length).unwrap());
            assert!(!resolve_assets_response_fits(&response, payload_length, length - 1).unwrap());
        }
        let declined =
            serde_json::to_value(asset_error_response(7, OVERSIZED_RESOLVE_ASSETS_ERROR)).unwrap();
        assert_eq!(declined["ok"], false);
        assert_eq!(declined["id"], 7);
        assert_eq!(declined["type"], "asset_response");
        assert!(declined.get("assets").is_none());
    }

    #[test]
    fn resolve_assets_declines_oversized_overlay_without_allocating_it() {
        let entries = [ResolvedAssetEntry::Bytes {
            offset: 0,
            length: MAX_FRAME_LENGTH,
        }];
        for payload_length in [MAX_FRAME_LENGTH, usize::MAX] {
            let response = resolve_assets_response(9, &entries, payload_length);
            assert!(
                !resolve_assets_response_fits(&response, payload_length, MAX_FRAME_LENGTH).unwrap()
            );
        }
    }

    #[test]
    fn typed_asset_responses_match_protocol_wire_schema() {
        assert_eq!(
            serde_json::to_value(binary_read_response(10, 123)).unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 10,
                "ok": true,
                "encoding": "raw",
                "length": 123,
            })
        );
        assert_eq!(
            serde_json::to_value(PathReadResponse {
                v: 1,
                message_type: ASSET_RESPONSE_TYPE,
                id: 11,
                ok: true,
                path: Cow::Borrowed("/app/lib/a.dart"),
            })
            .unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 11,
                "ok": true,
                "path": "/app/lib/a.dart",
            })
        );
        assert_eq!(
            serde_json::to_value(CanReadResponse {
                v: 1,
                message_type: ASSET_RESPONSE_TYPE,
                id: 12,
                ok: true,
                value: true,
                path: None,
            })
            .unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 12,
                "ok": true,
                "value": true,
            })
        );
        assert_eq!(
            serde_json::to_value(CanReadResponse {
                v: 1,
                message_type: ASSET_RESPONSE_TYPE,
                id: 120,
                ok: true,
                value: true,
                path: Some(Cow::Borrowed("/app/lib/a.dart")),
            })
            .unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 120,
                "ok": true,
                "value": true,
                "path": "/app/lib/a.dart",
            })
        );
        let found = vec!["app|lib/a.dart".to_string()];
        assert_eq!(
            serde_json::to_value(FindAssetsResponse {
                v: 1,
                message_type: ASSET_RESPONSE_TYPE,
                id: 13,
                ok: true,
                assets: &found,
            })
            .unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 13,
                "ok": true,
                "assets": ["app|lib/a.dart"],
            })
        );
        let entries = [
            ResolvedAssetEntry::Path {
                path: "/app/lib/a.dart".to_string(),
            },
            ResolvedAssetEntry::Bytes {
                offset: 0,
                length: 4,
            },
            ResolvedAssetEntry::NotFound,
        ];
        assert_eq!(
            serde_json::to_value(resolve_assets_response(14, &entries[..1], 0)).unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 14,
                "ok": true,
                "assets": [{"status": "path", "path": "/app/lib/a.dart"}],
            })
        );
        assert_eq!(
            serde_json::to_value(resolve_assets_response(15, &entries, 4)).unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 15,
                "ok": true,
                "assets": [
                    {"status": "path", "path": "/app/lib/a.dart"},
                    {"status": "bytes", "offset": 0, "length": 4},
                    {"status": "not_found"},
                ],
                "encoding": "raw",
                "length": 4,
            })
        );
        assert_eq!(
            serde_json::to_value(asset_error_response(16, "asset not found: app|lib/x.dart"))
                .unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 16,
                "ok": false,
                "error": "asset not found: app|lib/x.dart",
            })
        );
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

    struct TempWorkspace {
        root: PathBuf,
        workspace: Workspace,
    }

    impl TempWorkspace {
        fn new(name: &str) -> Self {
            static NEXT_DIR: AtomicU64 = AtomicU64::new(0);
            // Claim the root with create_dir so a stale directory left by an
            // earlier process with a recycled ID is never reused or removed.
            let root = loop {
                let candidate = std::env::temp_dir().join(format!(
                    "build-runner-accelerator-asset-rpc-{name}-{}-{}",
                    std::process::id(),
                    NEXT_DIR.fetch_add(1, Ordering::Relaxed),
                ));
                match fs::create_dir(&candidate) {
                    Ok(()) => break candidate,
                    Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                    Err(error) => panic!("failed to create {}: {error}", candidate.display()),
                }
            };
            fs::create_dir_all(root.join(".dart_tool")).unwrap();
            fs::create_dir_all(root.join("lib")).unwrap();
            fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
            fs::write(
                root.join(".dart_tool/package_config.json"),
                r#"{"configVersion":2,"packages":[{"name":"app","rootUri":"../"}]}"#,
            )
            .unwrap();
            let workspace = Workspace::load(root.clone()).unwrap();
            Self { root, workspace }
        }
    }

    impl Drop for TempWorkspace {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn test_builder_definition(
        id: &str,
        build_to: BuildTo,
        phase: u32,
    ) -> crate::builder::BuilderDefinition {
        crate::builder::BuilderDefinition {
            adds_to_library: false,
            id: id.to_owned(),
            kind: BuilderKind::Normal,
            extensions: vec![crate::builder::BuilderExtension {
                input_suffix: ".in".to_owned(),
                input_is_exact: false,
                input_is_capture: false,
                input_is_all: false,
                input_is_anchored: false,
                output_suffixes: vec![".txt".to_owned()],
            }],
            post_process_input_extensions: Vec::new(),
            build_to,
            phase,
            is_optional: false,
            output_is_optional: false,
            required_input_suffixes: Vec::new(),
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
            triggers: Vec::new(),
        }
    }

    fn test_build_spec(id: &str, build_to: BuildTo, phase: u32, output: &str) -> BuildSpec {
        Arc::new(crate::plan::BuildAction {
            instance: Arc::new(crate::plan::BuilderInstance {
                builder: Arc::new(test_builder_definition(id, build_to, phase)),
                target: "app:app".to_owned(),
                package: "app".to_owned(),
                is_root: true,
                phase,
                instance_key: id.to_owned(),
                options: serde_json::Map::new(),
                part_directive_suffix: None,
                api_cutoff: false,
            }),
            input: "app|lib/input.in".to_owned(),
            outputs: vec![output.to_owned()],
        })
    }

    #[test]
    fn collect_glob_members_orders_sources_before_generated_in_utf16_order() {
        let temp = TempWorkspace::new("utf16");
        fs::write(temp.root.join("lib/z_source.txt"), b"disk source").unwrap();

        let src_supp = "app|lib/\u{10000}_src.txt";
        let src_pua = "app|lib/\u{E000}_src.txt";
        let src_ascii = "app|lib/z_source.txt";
        let gen_ascii = "app|lib/a_gen.txt";
        let gen_supp = "app|lib/\u{10000}_gen.txt";
        let gen_pua = "app|lib/\u{E000}_gen.txt";

        // Confirm our chosen characters disagree between UTF-8 and UTF-16 order.
        assert!(src_pua < src_supp);
        assert!(src_supp.encode_utf16().cmp(src_pua.encode_utf16()).is_lt());

        let mut overlay = BTreeMap::new();
        for asset in [src_supp, src_pua, gen_ascii, gen_supp, gen_pua] {
            overlay.insert(asset.to_owned(), Arc::from(&b"data"[..]));
        }
        let generated_set = BTreeSet::from([gen_ascii, gen_supp, gen_pua]);
        let deleted = BTreeSet::new();
        let visibility = AssetVisibility::default();

        let members = collect_glob_members(
            &temp.workspace,
            "app",
            "lib/*.txt",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            |asset| generated_set.contains(asset),
            |asset| asset_exists(&temp.workspace, asset, &overlay, &visibility),
        )
        .unwrap();

        assert_eq!(
            members,
            vec![
                src_ascii.to_owned(),
                src_supp.to_owned(),
                src_pua.to_owned(),
                gen_ascii.to_owned(),
                gen_supp.to_owned(),
                gen_pua.to_owned(),
            ]
        );
    }

    #[test]
    fn collect_glob_members_distinguishes_location_vs_specs_predicates() {
        let temp = TempWorkspace::new("predicate");
        let prev_output = "app|lib/a_prev.txt";
        let curr_output = "app|lib/b_curr.txt";
        let plain_source = "app|lib/m_source.txt";

        fs::write(temp.root.join("lib/a_prev.txt"), b"previous output").unwrap();
        fs::write(temp.root.join("lib/m_source.txt"), b"plain source").unwrap();

        let curr_spec = test_build_spec("app:curr", BuildTo::Source, 0, curr_output);
        let specs = BTreeMap::from([(curr_output.to_owned(), curr_spec.clone())]);

        let mut prev_state = crate::graph::GraphState::default();
        prev_state.actions.insert(
            "app:app|app:prev|app|lib/old.in".to_owned(),
            crate::graph::ActionState {
                builder: "app:prev".to_owned(),
                outputs: vec![prev_output.to_owned()],
                ..crate::graph::ActionState::default()
            },
        );
        let mut definitions = BTreeMap::new();
        definitions.insert(
            "app:prev".to_owned(),
            Arc::new(test_builder_definition("app:prev", BuildTo::Source, 0)),
        );
        let config = crate::builder::RustBuildConfig {
            asset_sources: None,
            builders: Vec::new(),
            worker_entrypoint: None,
            manifest_signature: None,
            trigger_digest: None,
            definitions,
        };
        let visibility = AssetVisibility::from_specs(&[curr_spec], &prev_state, &config);
        assert_eq!(visibility.location(prev_output), Some(BuildTo::Source));
        assert_eq!(visibility.location(curr_output), Some(BuildTo::Source));
        assert_eq!(visibility.location(plain_source), None);

        let overlay = BTreeMap::from([(curr_output.to_owned(), Arc::from(&b"current"[..]))]);
        let deleted = BTreeSet::new();

        let by_location = collect_glob_members(
            &temp.workspace,
            "app",
            "lib/*.txt",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            |asset| visibility.location(asset).is_some(),
            |asset| asset_exists(&temp.workspace, asset, &overlay, &visibility),
        )
        .unwrap();
        assert_eq!(
            by_location,
            vec![
                plain_source.to_owned(),
                prev_output.to_owned(),
                curr_output.to_owned(),
            ]
        );

        let by_specs = collect_glob_members(
            &temp.workspace,
            "app",
            "lib/*.txt",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            |asset| specs.contains_key(asset),
            |asset| asset_exists(&temp.workspace, asset, &overlay, &visibility),
        )
        .unwrap();
        assert_eq!(
            by_specs,
            vec![
                prev_output.to_owned(),
                plain_source.to_owned(),
                curr_output.to_owned(),
            ]
        );
    }

    #[test]
    fn resolve_can_read_returns_disk_path_and_omits_path_for_memory_or_missing() {
        let temp = TempWorkspace::new("can-read-path");
        let source_path = temp.root.join("lib/model.dart");
        fs::write(&source_path, b"class Model {}").unwrap();
        let cache_asset = "app|lib/cached.g.part";
        let cache_path = temp.workspace.cache_path_for_asset(cache_asset).unwrap();
        fs::create_dir_all(cache_path.parent().unwrap()).unwrap();
        fs::write(&cache_path, b"// cached").unwrap();

        let cache_spec = test_build_spec("app:cache", BuildTo::Cache, 0, cache_asset);
        let config = crate::builder::RustBuildConfig {
            asset_sources: None,
            builders: Vec::new(),
            worker_entrypoint: None,
            manifest_signature: None,
            trigger_digest: None,
            definitions: BTreeMap::new(),
        };
        let visibility = AssetVisibility::from_specs(
            &[cache_spec],
            &crate::graph::GraphState::default(),
            &config,
        );
        let overlay = BTreeMap::from([(
            "app|lib/overlay.g.part".to_owned(),
            Arc::from(&b"// overlay"[..]),
        )]);
        let deleted = BTreeSet::from(["app|lib/deleted.dart".to_owned()]);
        fs::write(temp.root.join("lib/deleted.dart"), b"// deleted").unwrap();

        let disk = resolve_can_read(
            &temp.workspace,
            "app|lib/model.dart",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            None,
        )
        .unwrap();
        assert_eq!(disk, CanReadResult::Path(source_path.clone()));
        let disk_json = serde_json::to_value(can_read_response(1, &disk)).unwrap();
        assert_eq!(disk_json["value"], true);
        assert_eq!(disk_json["path"], source_path.to_string_lossy().as_ref());

        let cached = resolve_can_read(
            &temp.workspace,
            cache_asset,
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            None,
        )
        .unwrap();
        assert_eq!(cached, CanReadResult::Path(cache_path));

        // Same-phase generated output is blocked even though its cache file exists.
        let blocked = resolve_can_read(
            &temp.workspace,
            cache_asset,
            &overlay,
            &deleted,
            &visibility,
            0,
            BuilderKind::Normal,
            None,
        )
        .unwrap();
        assert_eq!(blocked, CanReadResult::Missing);
        let blocked_json = serde_json::to_value(can_read_response(2, &blocked)).unwrap();
        assert_eq!(blocked_json["value"], false);
        assert!(blocked_json.get("path").is_none());

        // Deleted overlay hides an existing disk file.
        let hidden = resolve_can_read(
            &temp.workspace,
            "app|lib/deleted.dart",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            None,
        )
        .unwrap();
        assert_eq!(hidden, CanReadResult::Missing);

        // In-memory overlay returns true without a filesystem path.
        let mem = resolve_can_read(
            &temp.workspace,
            "app|lib/overlay.g.part",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            None,
        )
        .unwrap();
        assert_eq!(mem, CanReadResult::MemoryOnly);
        let mem_json = serde_json::to_value(can_read_response(3, &mem)).unwrap();
        assert_eq!(mem_json["value"], true);
        assert!(mem_json.get("path").is_none());

        // Untracked filtered source pinned in memory omits path so reads fetch
        // the frozen bytes rather than live disk.
        let mut lazy = LazyBuildState::filtered(
            crate::graph::GraphState::default(),
            BTreeMap::new(),
            true,
            false,
        );
        let specs = BTreeMap::new();
        let filtered = resolve_can_read(
            &temp.workspace,
            "app|lib/model.dart",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            Some(FilteredAssetEvidence {
                lazy: &mut lazy,
                lazy_specs: &specs,
            }),
        )
        .unwrap();
        assert_eq!(filtered, CanReadResult::MemoryOnly);
    }

    #[test]
    fn list_visible_assets_response_schema_and_frame_limit_guard() {
        let sources = vec!["lib/a.dart".to_string()];
        let generated = vec!["lib/a.g.part".to_string()];
        let response = ListVisibleAssetsResponse {
            v: 1,
            message_type: ASSET_RESPONSE_TYPE,
            id: 16,
            ok: true,
            sources: &sources,
            generated: &generated,
        };
        assert_eq!(
            serde_json::to_value(&response).unwrap(),
            json!({
                "v": 1,
                "type": "asset_response",
                "id": 16,
                "ok": true,
                "sources": ["lib/a.dart"],
                "generated": ["lib/a.g.part"],
            })
        );
        let exact_length = serde_json::to_vec(&response).unwrap().len();
        assert!(list_visible_assets_response_fits(&response, exact_length).unwrap());
        assert!(!list_visible_assets_response_fits(&response, exact_length - 1).unwrap());
    }

    #[test]
    fn collect_visible_package_paths_partitions_and_orders_with_phase_visibility() {
        let temp = TempWorkspace::new("list-visible-assets");
        fs::write(temp.root.join("lib/z.dart"), b"class Z {}").unwrap();
        fs::write(temp.root.join("lib/a.dart"), b"class A {}").unwrap();
        fs::write(temp.root.join("lib/deleted.dart"), b"class Deleted {}").unwrap();

        let phase0_cache = "app|lib/a.g.part";
        let phase0_cache_path = temp.workspace.cache_path_for_asset(phase0_cache).unwrap();
        fs::create_dir_all(phase0_cache_path.parent().unwrap()).unwrap();
        fs::write(&phase0_cache_path, b"// part").unwrap();

        let phase0_overlay = "app|lib/b.freezed.dart";
        let phase1_future = "app|lib/a.g.dart";
        fs::write(temp.root.join("lib/a.g.dart"), b"// stale future output").unwrap();

        let specs = [
            test_build_spec("app:p0_cache", BuildTo::Cache, 0, phase0_cache),
            test_build_spec("app:p0_source", BuildTo::Source, 0, phase0_overlay),
            test_build_spec("app:p1_source", BuildTo::Source, 1, phase1_future),
        ];
        let config = crate::builder::RustBuildConfig {
            asset_sources: None,
            builders: Vec::new(),
            worker_entrypoint: None,
            manifest_signature: None,
            trigger_digest: None,
            definitions: BTreeMap::new(),
        };
        let visibility =
            AssetVisibility::from_specs(&specs, &crate::graph::GraphState::default(), &config);
        let overlay = BTreeMap::from([(phase0_overlay.to_owned(), Arc::from(&b"// freezed"[..]))]);
        let deleted = BTreeSet::from(["app|lib/deleted.dart".to_owned()]);

        // Phase 0 hides phase 0 and phase 1 generated outputs and deleted files.
        let (p0_sources, p0_generated) = collect_visible_package_paths(
            &temp.workspace,
            "app",
            &overlay,
            &deleted,
            &visibility,
            0,
            BuilderKind::Normal,
        )
        .unwrap();
        let p0_lib_sources: Vec<&str> = p0_sources
            .iter()
            .map(String::as_str)
            .filter(|path| !path.starts_with(".dart_tool/"))
            .collect();
        assert_eq!(
            p0_lib_sources,
            vec!["lib/a.dart", "lib/z.dart", "pubspec.yaml"]
        );
        assert!(p0_generated.is_empty());

        // Phase 1 exposes phase 0 outputs (cache + overlay) in UTF-16 order while
        // still hiding phase 1's own output (lib/a.g.dart).
        let (p1_sources, p1_generated) = collect_visible_package_paths(
            &temp.workspace,
            "app",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
        )
        .unwrap();
        let p1_lib_sources: Vec<&str> = p1_sources
            .iter()
            .map(String::as_str)
            .filter(|path| !path.starts_with(".dart_tool/"))
            .collect();
        assert_eq!(
            p1_lib_sources,
            vec!["lib/a.dart", "lib/z.dart", "pubspec.yaml"]
        );
        assert_eq!(p1_generated, vec!["lib/a.g.part", "lib/b.freezed.dart"]);

        // Combined sources + generated match collect_glob_members("**") exactly.
        let p1_expected = collect_glob_members(
            &temp.workspace,
            "app",
            "**",
            &overlay,
            &deleted,
            &visibility,
            1,
            BuilderKind::Normal,
            |asset| visibility.location(asset).is_some(),
            |asset| asset_exists(&temp.workspace, asset, &overlay, &visibility),
        )
        .unwrap();
        let p1_combined: Vec<String> = p1_sources
            .iter()
            .chain(p1_generated.iter())
            .map(|path| format!("app|{path}"))
            .collect();
        assert_eq!(p1_combined, p1_expected);

        // Phase 2 exposes phase 1's output as well.
        let (_, p2_generated) = collect_visible_package_paths(
            &temp.workspace,
            "app",
            &overlay,
            &deleted,
            &visibility,
            2,
            BuilderKind::Normal,
        )
        .unwrap();
        assert_eq!(
            p2_generated,
            vec!["lib/a.g.dart", "lib/a.g.part", "lib/b.freezed.dart"]
        );
    }
}
