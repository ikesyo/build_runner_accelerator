use super::asset_rpc::batch_asset_request_context;
use super::request::{
    BuildRequest, json_build_batch_result_frame_size, json_build_result_frame_size,
};
use super::wire::{
    ApiUnitEvidence, AssetInterner, BlockedAssetsCache, PlainAssetIds, batch_shared_fields,
    compute_asset_digest_delta, decode_api_unit_evidence, intern_asset_list, intern_overlay_blob,
    rollback_asset_dictionary, write_batch_frame,
};
use crate::protocol::{
    BINARY_BUILD_RESULT_MAGIC, BuildBatchResultCollector, BuildResult, IncomingFrame,
    decode_build_batch_result_frame, read_message_with_size, write_binary_frame, write_frame,
    write_frame_buffered,
};
use crate::visibility::AssetVisibility;
use crate::worker_kernel::WorkerArtifact;
use crate::workspace::Workspace;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{self, BufReader, BufWriter};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Arc;
use std::time::Instant;

const BINARY_READ_CAPABILITY: &str = "asset-rpc-binary-read-v1";
const BINARY_BUILD_RESULT_CAPABILITY: &str = "build-result-binary-v1";
const OPTIONAL_BUILD_CAPABILITY: &str = "optional-builder-demand-v1";
const OVERLAY_BLOB_CAPABILITY: &str = "reset-overlay-blob-v1";
const SHARED_BLOCKED_ASSETS_CAPABILITY: &str = "shared-blocked-assets-v1";
const BATCH_SHARED_FIELDS_CAPABILITY: &str = "batch-shared-fields-v1";
const ASSET_ID_INTERNING_CAPABILITY: &str = "asset-id-interning-v1";
const ASSET_DIGESTS_CAPABILITY: &str = "asset-digests-v1";
const API_FINGERPRINTS_CAPABILITY: &str = "api-fingerprints-v1";

/// Distinguishes a path to a Dart source script from a package executable name
/// so the launcher can select the correct Dart invocation form.
pub(super) fn is_worker_script(worker_executable: &str) -> bool {
    let path = Path::new(worker_executable);
    path.is_absolute() || path.extension().and_then(|extension| extension.to_str()) == Some("dart")
}

/// Owns one child process and its framed stdin/stdout streams. The protocol
/// reserves stdout for IPC; worker diagnostics are inherited from stderr.
pub struct WorkerClient {
    pub(super) shared_parts_capable: bool,
    pub(super) batch_shared_fields_capable: bool,
    pub(super) asset_interning_capable: bool,
    /// Per-connection asset-id dictionary for `asset-id-interning-v1`; the
    /// worker mirrors it by appending each message's `asset_dict_add` list.
    /// Initialization starts a fresh dictionary on both sides.
    pub(super) asset_dictionary: Vec<String>,
    pub(super) asset_dictionary_index: HashMap<String, u32>,
    pub(super) asset_digests_capable: bool,
    /// Digests the worker on this connection has been sent, asset id to bare
    /// SHA-256 hex (`asset-digests-v1`, ADR 0054). Batch messages carry only
    /// the delta against this map; initialization clears it.
    pub(super) sent_asset_digests: HashMap<String, String>,
    /// The current build's full digest map, staged by the pool. The next
    /// batch computes its delta from this map; staging a newer build's map
    /// replaces it wholesale.
    pub(super) staged_asset_digests: Option<std::sync::Arc<BTreeMap<String, String>>>,
    pub(super) blocked_assets_cache: BlockedAssetsCache,
    /// Reusable serialization buffer for typed build messages.
    pub(super) send_buffer: Vec<u8>,
    child: Child,
    input: BufWriter<ChildStdin>,
    output: BufReader<ChildStdout>,
    pub(super) next_id: u64,
    pub(super) metrics: WorkerClientMetrics,
    /// Resolver dependency edges reported with this client's batch or single results.
    pub(super) dep_graph: BTreeMap<String, Vec<String>>,
    pub(super) api_fingerprints_capable: bool,
    /// Unit API fingerprints reported with this client's results
    /// (ADR 0056); a `None` value marks a unit whose fingerprint is
    /// unavailable.
    pub(super) api_fingerprints: BTreeMap<String, Option<crate::protocol::ApiFingerprintRecord>>,
}

#[derive(Clone, Copy, Default)]
pub(crate) struct WorkerClientMetrics {
    pub(crate) worker_start_us: u64,
    pub(crate) worker_initialize_us: u64,
    pub(crate) worker_reset_us: u64,
    pub(crate) resolver_reset_us: u64,
    pub(crate) build_us: u64,
    pub(crate) asset_rpc_us: u64,
    pub(crate) ipc_frames_sent: u64,
    pub(crate) ipc_frames_received: u64,
    pub(crate) ipc_bytes_sent: u64,
    pub(crate) ipc_bytes_received: u64,
    pub(crate) build_result_frames: u64,
    pub(crate) build_result_bytes: u64,
    pub(crate) build_result_json_bytes: u64,
    pub(crate) asset_requests: u64,
    pub(crate) read_requests: u64,
    pub(crate) read_bytes: u64,
    pub(crate) binary_read_responses: u64,
    pub(crate) path_read_responses: u64,
    pub(crate) can_read_requests: u64,
    pub(crate) find_assets_requests: u64,
    pub(crate) find_assets_results: u64,
    pub(crate) resolve_assets_requests: u64,
    pub(crate) resolve_assets_results: u64,
}

impl WorkerClientMetrics {
    pub(super) fn add(&mut self, other: Self) {
        self.worker_start_us += other.worker_start_us;
        self.worker_initialize_us += other.worker_initialize_us;
        self.worker_reset_us += other.worker_reset_us;
        self.resolver_reset_us += other.resolver_reset_us;
        self.build_us += other.build_us;
        self.asset_rpc_us += other.asset_rpc_us;
        self.ipc_frames_sent += other.ipc_frames_sent;
        self.ipc_frames_received += other.ipc_frames_received;
        self.ipc_bytes_sent += other.ipc_bytes_sent;
        self.ipc_bytes_received += other.ipc_bytes_received;
        self.build_result_frames += other.build_result_frames;
        self.build_result_bytes += other.build_result_bytes;
        self.build_result_json_bytes += other.build_result_json_bytes;
        self.asset_requests += other.asset_requests;
        self.read_requests += other.read_requests;
        self.read_bytes += other.read_bytes;
        self.binary_read_responses += other.binary_read_responses;
        self.path_read_responses += other.path_read_responses;
        self.can_read_requests += other.can_read_requests;
        self.find_assets_requests += other.find_assets_requests;
        self.find_assets_results += other.find_assets_results;
        self.resolve_assets_requests += other.resolve_assets_requests;
        self.resolve_assets_results += other.resolve_assets_results;
    }
}

impl WorkerClient {
    /// Starts one worker in the workspace root with piped IPC and inherited
    /// diagnostics. Spawn and pipe setup errors propagate before a client is
    /// returned; dropping a returned client terminates and reaps its child.
    pub fn start(
        root: &Path,
        dart_binary: &str,
        worker_executable: &str,
        worker_artifact: &WorkerArtifact,
    ) -> io::Result<Self> {
        let _wall = crate::wall::Span::new("worker_spawn");
        let started = Instant::now();
        let mut command = match worker_artifact {
            WorkerArtifact::Aot(executable) => Command::new(executable),
            WorkerArtifact::Kernel(kernel) => {
                let mut command = Command::new(dart_binary);
                let package_config = crate::runner_compatibility::package_config(root)?;
                command
                    .arg(format!("--packages={}", package_config.display()))
                    .arg(kernel);
                command
            }
            WorkerArtifact::Script => {
                let mut command = Command::new(dart_binary);
                if is_worker_script(worker_executable) {
                    command
                        .arg(format!(
                            "--packages={}",
                            crate::runner_compatibility::package_config(root)?.display()
                        ))
                        .arg(worker_executable);
                } else {
                    command.args(["--suppress-analytics", "run", worker_executable]);
                }
                command
            }
        };
        let mut child = command
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let input = BufWriter::new(
            child
                .stdin
                .take()
                .ok_or_else(|| io::Error::other("worker stdin unavailable"))?,
        );
        let output = BufReader::new(
            child
                .stdout
                .take()
                .ok_or_else(|| io::Error::other("worker stdout unavailable"))?,
        );
        Ok(Self {
            child,
            input,
            output,
            next_id: 1,
            metrics: WorkerClientMetrics {
                worker_start_us: started.elapsed().as_micros() as u64,
                ..WorkerClientMetrics::default()
            },
            dep_graph: BTreeMap::new(),
            api_fingerprints_capable: false,
            api_fingerprints: BTreeMap::new(),
            shared_parts_capable: false,
            batch_shared_fields_capable: false,
            asset_interning_capable: false,
            asset_dictionary: Vec::new(),
            asset_dictionary_index: HashMap::new(),
            asset_digests_capable: false,
            sent_asset_digests: HashMap::new(),
            staged_asset_digests: None,
            blocked_assets_cache: BlockedAssetsCache::default(),
            send_buffer: Vec::new(),
        })
    }

    /// Performs the versioned handshake and enforces the capabilities required
    /// by this execution path. A stale or partial worker is rejected before
    /// build requests can rely on binary results, asset RPC, or reset blobs.
    pub fn initialize(
        &mut self,
        root: &Path,
        package: &str,
        phase_count: usize,
        requires_optional_builder: bool,
        input_restrictions: &BTreeMap<String, Vec<String>>,
        retained_output_guard: bool,
    ) -> io::Result<()> {
        let _wall = self.wall_span("worker_initialize", None);
        let started = Instant::now();
        let id = self.next_id();
        self.send(&json!({
            "v": 1,
            "type": "initialize",
            "accelerator_version": env!("CARGO_PKG_VERSION"),
            "id": id,
            "root": root,
            "package": package,
            "phase_count": phase_count,
            "input_restrictions": input_restrictions,
            "resolver_mode": "dart_local",
            "retained_output_guard": retained_output_guard
        }))?;
        let response = self.receive_json()?;
        if response.get("type").and_then(Value::as_str) != Some("initialized") {
            return Err(protocol_error("worker initialization failed", &response));
        }
        validate_initialized(&response, id)?;
        self.blocked_assets_cache =
            BlockedAssetsCache::new(has_capability(&response, "blocked-assets-reuse-v1"));
        self.shared_parts_capable = has_capability(&response, "shared-library-parts-v1");
        self.batch_shared_fields_capable =
            has_capability(&response, BATCH_SHARED_FIELDS_CAPABILITY);
        self.asset_interning_capable = has_capability(&response, ASSET_ID_INTERNING_CAPABILITY);
        self.asset_dictionary.clear();
        self.asset_dictionary_index.clear();
        self.asset_digests_capable = has_capability(&response, ASSET_DIGESTS_CAPABILITY);
        self.api_fingerprints_capable = has_capability(&response, API_FINGERPRINTS_CAPABILITY);
        self.sent_asset_digests.clear();
        if retained_output_guard && !has_capability(&response, "retained-output-guard-v1") {
            return Err(io::Error::other("worker lacks retained-output-guard-v1"));
        }
        if !has_capability(&response, BINARY_READ_CAPABILITY) {
            return Err(io::Error::other(format!(
                "worker does not support required capability: {BINARY_READ_CAPABILITY}"
            )));
        }
        if !has_capability(&response, BINARY_BUILD_RESULT_CAPABILITY) {
            return Err(io::Error::other(format!(
                "worker does not support required capability: {BINARY_BUILD_RESULT_CAPABILITY}"
            )));
        }
        if requires_optional_builder && !has_capability(&response, OPTIONAL_BUILD_CAPABILITY) {
            return Err(io::Error::other(format!(
                "worker does not support required capability: {OPTIONAL_BUILD_CAPABILITY}"
            )));
        }
        if !has_capability(&response, SHARED_BLOCKED_ASSETS_CAPABILITY) {
            return Err(io::Error::other(format!(
                "worker does not support required capability: {SHARED_BLOCKED_ASSETS_CAPABILITY}"
            )));
        }
        require_overlay_blob_capability(&response)?;
        self.metrics.worker_initialize_us += started.elapsed().as_micros() as u64;
        Ok(())
    }

    /// Resets worker-local build state and requires an acknowledgement carrying
    /// the request ID; a mismatched reply is a protocol error.
    pub fn reset(&mut self) -> io::Result<()> {
        let _wall = self.wall_span("worker_reset", None);
        let started = Instant::now();
        let id = self.next_id();
        self.send(&json!({
            "v": 1,
            "type": "reset",
            "id": id,
        }))?;
        let response = self.receive_json()?;
        if response.get("type").and_then(Value::as_str) != Some("reset")
            || response.get("id").and_then(Value::as_u64) != Some(id)
        {
            return Err(protocol_error("worker reset failed", &response));
        }
        self.metrics.worker_reset_us += started.elapsed().as_micros() as u64;
        Ok(())
    }

    /// Sends source/cache deltas and the overlay transport descriptor, then
    /// awaits the matching reset reply. The caller owns the descriptor's bytes
    /// until this method returns; transport and protocol failures propagate.
    pub fn reset_resolver(
        &mut self,
        updated_sources: &Value,
        deleted_sources: &Value,
        updated_cache: &Value,
        deleted_cache: &Value,
        incremental: bool,
        overlay_blob: &Value,
    ) -> io::Result<()> {
        let _wall = self.wall_span("worker_resolver_reset", None);
        let started = Instant::now();
        let id = self.next_id();
        let encoding = self.wall_span("reset_encode_send", Some(id));
        if self.asset_interning_capable {
            let checkpoint = self.asset_dictionary.len();
            let mut interner =
                AssetInterner::new(&mut self.asset_dictionary, &mut self.asset_dictionary_index);
            let updated_sources = intern_asset_list(updated_sources, &mut interner);
            let deleted_sources = intern_asset_list(deleted_sources, &mut interner);
            let updated_cache = intern_asset_list(updated_cache, &mut interner);
            let deleted_cache = intern_asset_list(deleted_cache, &mut interner);
            let overlay_blob = intern_overlay_blob(overlay_blob, &mut interner);
            let message = json!({
                "v": 1,
                "type": "reset_resolver",
                "id": id,
                "asset_dict_add": interner.additions,
                "updated_sources": updated_sources,
                "deleted_sources": deleted_sources,
                "updated_cache": updated_cache,
                "deleted_cache": deleted_cache,
                "incremental": incremental,
                "overlay_blob": overlay_blob,
            });
            if let Err(error) = self.send(&message) {
                rollback_asset_dictionary(
                    &mut self.asset_dictionary,
                    &mut self.asset_dictionary_index,
                    checkpoint,
                );
                return Err(error);
            }
        } else {
            self.send(&json!({
                "v": 1,
                "type": "reset_resolver",
                "id": id,
                "updated_sources": updated_sources,
                "deleted_sources": deleted_sources,
                "updated_cache": updated_cache,
                "deleted_cache": deleted_cache,
                "incremental": incremental,
                "overlay_blob": overlay_blob,
            }))?;
        }
        drop(encoding);
        let receive = self.wall_span("reset_receive", Some(id));
        let response = self.receive_json()?;
        drop(receive);
        if response.get("type").and_then(Value::as_str) != Some("reset_resolver")
            || response.get("id").and_then(Value::as_u64) != Some(id)
        {
            return Err(protocol_error("worker resolver reset failed", &response));
        }
        self.metrics.resolver_reset_us += started.elapsed().as_micros() as u64;
        Ok(())
    }

    /// ADR 0056 preflight: asks the worker for the current API
    /// fingerprint and direct resolver deps of changed units, keyed by
    /// the content digests the frontend's snapshot recorded. A unit
    /// the worker cannot answer for comes back with empty evidence.
    /// The worker reads the units through the asset RPC, so this
    /// services nested asset requests exactly like a build does, with
    /// an empty overlay and a synthetic request context at the last
    /// phase, where every committed source is visible.
    pub fn api_fingerprint_query(
        &mut self,
        workspace: &Workspace,
        entries: &[(String, String)],
        phase_count: u32,
        visibility: &AssetVisibility,
    ) -> io::Result<BTreeMap<String, ApiUnitEvidence>> {
        let _wall = self.wall_span("worker_api_fingerprint_query", None);
        let id = self.next_id();
        self.send(&json!({
            "v": 1,
            "type": "api_fingerprint_query",
            "id": id,
            "entries": entries
                .iter()
                .map(|(asset, digest)| json!({"asset": asset, "digest": digest}))
                .collect::<Vec<_>>(),
        }))?;
        let active_request = BuildRequest {
            part_phase_index: None,
            builder: String::new(),
            input: entries
                .first()
                .map(|(asset, _)| asset.clone())
                .unwrap_or_default(),
            outputs: Vec::new(),
            options: serde_json::Map::new(),
            phase: phase_count,
            instance_key: String::new(),
            is_root: false,
            api_cutoff: false,
            post_process: false,
            triggers: Vec::new(),
        };
        let empty_overlay = BTreeMap::new();
        let empty_deleted = BTreeSet::new();
        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => {
                    match response.get("type").and_then(Value::as_str) {
                        Some("asset_request") => {
                            self.handle_asset_request(
                                workspace,
                                &response,
                                &empty_overlay,
                                &empty_deleted,
                                visibility,
                                &active_request,
                                id,
                                None,
                            )?;
                        }
                        Some("api_fingerprints") => {
                            if response.get("id").and_then(Value::as_u64) != Some(id) {
                                return Err(protocol_error(
                                    "worker API fingerprint query failed",
                                    &response,
                                ));
                            }
                            let mut results = BTreeMap::new();
                            if let Some(reported) =
                                response.get("results").and_then(Value::as_object)
                            {
                                for (asset, value) in reported {
                                    results.insert(asset.clone(), decode_api_unit_evidence(value));
                                }
                            }
                            return Ok(results);
                        }
                        Some("error") => {
                            return Err(protocol_error("worker error", &response));
                        }
                        _ => {
                            return Err(protocol_error("unexpected worker message", &response));
                        }
                    }
                }
                IncomingFrame::Binary(_) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "unexpected binary IPC frame during API fingerprint query",
                    ));
                }
            }
        }
    }

    /// Sends one phase/kind batch and serves its nested asset RPCs until a
    /// validated binary result arrives. The blocked-asset hint is computed from
    /// Rust visibility plus pending deletions; JSON result fallback, wrong IDs,
    /// and result-count mismatches fail the request.
    pub fn build_batch(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
    ) -> io::Result<Vec<BuildResult>> {
        self.run_batch_rpc(
            "worker_batch",
            requests,
            visibility,
            deleted_overlay,
            |client, deleted_overlay, response, active_request, build_id| {
                client.handle_asset_request(
                    workspace,
                    response,
                    overlay,
                    deleted_overlay,
                    visibility,
                    active_request,
                    build_id,
                    None,
                )
            },
        )
    }

    pub(super) fn run_batch_rpc<D, F>(
        &mut self,
        wall_stage: &'static str,
        requests: &[BuildRequest],
        visibility: &AssetVisibility,
        deleted_overlay: D,
        on_asset_request: F,
    ) -> io::Result<Vec<BuildResult>>
    where
        D: std::ops::Deref<Target = BTreeSet<String>>,
        F: FnMut(&mut Self, &mut D, &Value, &BuildRequest, u64) -> io::Result<()>,
    {
        let result = self.run_batch_rpc_inner(
            wall_stage,
            requests,
            visibility,
            deleted_overlay,
            on_asset_request,
        );
        // A worker can reject a batch before accepting its visibility hint.
        // Forget on every error so a retry cannot reuse an unaccepted list.
        if result.is_err() {
            self.blocked_assets_cache.forget_last();
        }
        result
    }

    fn run_batch_rpc_inner<D, F>(
        &mut self,
        wall_stage: &'static str,
        requests: &[BuildRequest],
        visibility: &AssetVisibility,
        mut deleted_overlay: D,
        mut on_asset_request: F,
    ) -> io::Result<Vec<BuildResult>>
    where
        D: std::ops::Deref<Target = BTreeSet<String>>,
        F: FnMut(&mut Self, &mut D, &Value, &BuildRequest, u64) -> io::Result<()>,
    {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span(wall_stage, Some(id));
        let metrics_before = self.metrics;
        let encoding = self.wall_span("request_encode_send", Some(id));
        // Every request in this batch has the same phase and kind. Keep the
        // visibility hint at the batch level instead of copying the full
        // blocked-asset list into every request.
        let (blocked_assets, blocked_assets_reuse) =
            self.blocked_assets_cache
                .prepare(requests, visibility, &deleted_overlay)?;
        self.send_batch(id, requests, &blocked_assets, blocked_assets_reuse)?;
        drop(encoding);

        let mut batch_results = BuildBatchResultCollector::new(id, requests.len());
        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => {
                        let (build_id, active_request) =
                            batch_asset_request_context(&response, requests)?;
                        on_asset_request(
                            self,
                            &mut deleted_overlay,
                            &response,
                            active_request,
                            build_id,
                        )?;
                    }
                    Some("build_batch_result" | "build_batch_chunk") => {
                        return Err(io::Error::other(
                            "worker sent JSON build batch result; binary capability is required",
                        ));
                    }
                    Some("error") => return Err(protocol_error("worker error", &response)),
                    _ => return Err(protocol_error("unexpected worker message", &response)),
                },
                IncomingFrame::Binary(frame) => {
                    let _decode = self.wall_span("result_decode_validate", Some(id));
                    let decoded = decode_build_batch_result_frame(frame)?;
                    self.record_json_build_batch_result_size(decoded.id, &decoded.results)?;
                    let Some(decoded) = batch_results.accept(decoded)? else {
                        continue;
                    };
                    self.dep_graph.extend(decoded.dep_graph);
                    crate::protocol::merge_fingerprint_reports(
                        &mut self.api_fingerprints,
                        decoded.api_fingerprints,
                    );
                    let results = decoded.results;
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    self.trace_metrics(&_wall, metrics_before);
                    return Ok(results);
                }
            }
        }
    }

    pub(super) fn trace_metrics(&self, span: &crate::wall::Span, before: WorkerClientMetrics) {
        for (key, after, before) in [
            (
                "ipc.sent.bytes",
                self.metrics.ipc_bytes_sent,
                before.ipc_bytes_sent,
            ),
            (
                "ipc.received.bytes",
                self.metrics.ipc_bytes_received,
                before.ipc_bytes_received,
            ),
            (
                "asset.read.bytes",
                self.metrics.read_bytes,
                before.read_bytes,
            ),
            (
                "asset.requests",
                self.metrics.asset_requests,
                before.asset_requests,
            ),
            (
                "asset.rpc.us",
                self.metrics.asset_rpc_us,
                before.asset_rpc_us,
            ),
        ] {
            span.attribute(key, after.saturating_sub(before));
        }
    }

    pub(super) fn wall_span(&self, stage: &'static str, id: Option<u64>) -> crate::wall::Span {
        crate::wall::Span::new(stage).worker(self.child.id(), id)
    }

    pub(super) fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    pub(super) fn send(&mut self, message: &Value) -> io::Result<()> {
        debug_assert!(
            !matches!(
                message.get("type").and_then(Value::as_str),
                Some("build" | "build_batch")
            ),
            "build messages must use typed wire serialization"
        );
        let frame_size = write_frame(&mut self.input, message)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    /// Sends a typed build message, serializing it once into the reusable
    /// buffer instead of building an intermediate JSON value tree. Telemetry
    /// context fields are populated by the wire constructors.
    pub(super) fn send_serialized<T: serde::Serialize>(&mut self, message: &T) -> io::Result<()> {
        let frame_size = write_frame_buffered(&mut self.input, message, &mut self.send_buffer)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    /// Stages the current build's digest map for `asset-digests-v1`. The
    /// next batch on this connection carries the delta against what the
    /// worker already has; staging a newer build's map replaces this one
    /// wholesale. See ADR 0054.
    pub(super) fn stage_asset_digests(
        &mut self,
        digests: Option<std::sync::Arc<BTreeMap<String, String>>>,
    ) {
        self.staged_asset_digests = digests;
    }

    /// The digest delta to attach to the next batch: updates and removals
    /// (as `None`) keyed by asset id, against the digests this connection
    /// has already sent. Empty when the capability is off, nothing is
    /// staged, or the worker is already current.
    fn asset_digest_delta(&self) -> Vec<(String, Option<String>)> {
        compute_asset_digest_delta(
            self.asset_digests_capable,
            &self.sent_asset_digests,
            self.staged_asset_digests.as_deref(),
        )
    }

    /// Applies a delta a batch send has delivered, so this connection's
    /// record mirrors the worker's digest map. A failed send applies
    /// nothing, exactly like the asset dictionary rollback.
    fn apply_asset_digest_delta(&mut self, delta: &[(String, Option<String>)]) {
        for (asset, digest) in delta {
            match digest {
                Some(digest) => {
                    self.sent_asset_digests
                        .insert(asset.clone(), digest.clone());
                }
                None => {
                    self.sent_asset_digests.remove(asset);
                }
            }
        }
    }

    /// Sends one `build_batch` envelope, using the shared-fields form when
    /// this connection's worker advertised the capability and the batch is
    /// uniform in the lifted fields.
    pub(super) fn send_batch(
        &mut self,
        id: u64,
        requests: &[BuildRequest],
        blocked_assets: &[String],
        blocked_assets_reuse: bool,
    ) -> io::Result<()> {
        let digest_delta = self.asset_digest_delta();
        let shared = self
            .batch_shared_fields_capable
            .then(|| batch_shared_fields(requests))
            .flatten();
        let result = if self.asset_interning_capable {
            let checkpoint = self.asset_dictionary.len();
            let mut interner =
                AssetInterner::new(&mut self.asset_dictionary, &mut self.asset_dictionary_index);
            let result = write_batch_frame(
                &mut self.input,
                &mut self.send_buffer,
                id,
                requests,
                blocked_assets,
                blocked_assets_reuse,
                &digest_delta,
                shared,
                &mut interner,
            );
            if result.is_err() {
                rollback_asset_dictionary(
                    &mut self.asset_dictionary,
                    &mut self.asset_dictionary_index,
                    checkpoint,
                );
            }
            result
        } else {
            write_batch_frame(
                &mut self.input,
                &mut self.send_buffer,
                id,
                requests,
                blocked_assets,
                blocked_assets_reuse,
                &digest_delta,
                shared,
                &mut PlainAssetIds,
            )
        };
        let frame_size = result?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        self.apply_asset_digest_delta(&digest_delta);
        Ok(())
    }

    pub(super) fn send_binary(&mut self, metadata: &Value, bytes: &[u8]) -> io::Result<()> {
        let frame_size = write_binary_frame(&mut self.input, metadata, bytes)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    /// Reads one complete frame and rejects EOF or any protocol version other
    /// than v1 before dispatching the message to a build/reset handler.
    pub(super) fn receive(&mut self) -> io::Result<IncomingFrame> {
        let _receive = self.wall_span("receive_frame", None);
        loop {
            let (message, frame_size) =
                read_message_with_size(&mut self.output)?.ok_or_else(|| {
                    io::Error::new(io::ErrorKind::UnexpectedEof, "Dart worker exited")
                })?;
            let metadata = match &message {
                IncomingFrame::Json(value) => value,
                IncomingFrame::Binary(frame) => &frame.metadata,
            };
            if metadata.get("v").and_then(Value::as_u64) != Some(1) {
                return Err(protocol_error(
                    "unsupported or missing IPC protocol version",
                    metadata,
                ));
            }
            if metadata.get("type").and_then(Value::as_str) == Some("otel_action") {
                crate::telemetry::worker_report(metadata);
                continue;
            }
            self.metrics.ipc_frames_received += 1;
            self.metrics.ipc_bytes_received += frame_size as u64;
            if matches!(
                &message,
                IncomingFrame::Binary(frame) if frame.magic == *BINARY_BUILD_RESULT_MAGIC
            ) {
                self.metrics.build_result_frames += 1;
                self.metrics.build_result_bytes += frame_size as u64;
            }
            return Ok(message);
        }
    }

    /// Requires a JSON control frame; binary input is invalid at handshake and
    /// reset boundaries.
    pub(super) fn receive_json(&mut self) -> io::Result<Value> {
        match self.receive()? {
            IncomingFrame::Json(message) => Ok(message),
            IncomingFrame::Binary(_) => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unexpected binary IPC frame",
            )),
        }
    }

    pub(super) fn record_json_build_result_size(&mut self, result: &BuildResult) -> io::Result<()> {
        if crate::metrics::runtime_metrics_enabled() {
            let _wall = self.wall_span("diagnostic_json_size", None);
            self.metrics.build_result_json_bytes += json_build_result_frame_size(result)?;
        }
        Ok(())
    }

    pub(super) fn record_json_build_batch_result_size(
        &mut self,
        id: u64,
        results: &[BuildResult],
    ) -> io::Result<()> {
        if crate::metrics::runtime_metrics_enabled() {
            let _wall = self.wall_span("diagnostic_json_size", None);
            self.metrics.build_result_json_bytes +=
                json_build_batch_result_frame_size(id, results)?;
        }
        Ok(())
    }

    pub(super) fn metrics(&self) -> WorkerClientMetrics {
        self.metrics
    }
}

impl Drop for WorkerClient {
    /// Ensure the subprocess cannot outlive its owning pool, even after a
    /// protocol or worker error. The exit status is intentionally best effort.
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Converts a worker error frame into an I/O error while retaining its detail
/// and optional stack for the command's diagnostic path.
pub(super) fn protocol_error(prefix: &str, value: &Value) -> io::Error {
    let detail = value
        .get("error")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string());
    let stack = value.get("stack").and_then(Value::as_str);
    match stack {
        Some(stack) if !stack.is_empty() => {
            io::Error::other(format!("{prefix}: {detail}\n{stack}"))
        }
        _ => io::Error::other(format!("{prefix}: {detail}")),
    }
}

pub(super) fn has_capability(response: &Value, required: &str) -> bool {
    response
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|capabilities| {
            capabilities
                .iter()
                .any(|capability| capability.as_str() == Some(required))
        })
}

/// Reject old workers before they can silently ignore the reset transport.
pub(super) fn require_overlay_blob_capability(response: &Value) -> io::Result<()> {
    if has_capability(response, OVERLAY_BLOB_CAPABILITY) {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "worker does not support required capability: {OVERLAY_BLOB_CAPABILITY}"
        )))
    }
}

/// Requires the handshake reply to match both the request ID and this exact
/// package build; protocol version alone does not establish worker compatibility.
fn validate_initialized(response: &Value, id: u64) -> io::Result<()> {
    if response.get("id").and_then(Value::as_u64) != Some(id) {
        return Err(protocol_error(
            "worker initialization id mismatch",
            response,
        ));
    }
    if response.get("accelerator_version").and_then(Value::as_str)
        != Some(env!("CARGO_PKG_VERSION"))
    {
        return Err(protocol_error(
            "worker accelerator_version mismatch",
            response,
        ));
    }
    Ok(())
}

#[cfg(test)]
mod version_tests {
    use super::*;

    #[test]
    fn initialization_requires_matching_version_and_id() {
        let valid = json!({"id": 1, "accelerator_version": env!("CARGO_PKG_VERSION")});
        assert!(validate_initialized(&valid, 1).is_ok());
        for invalid in [
            json!({"id": 1}),
            json!({"id": 1, "accelerator_version": "0.0.0"}),
            json!({"id": 2, "accelerator_version": env!("CARGO_PKG_VERSION")}),
        ] {
            assert!(validate_initialized(&invalid, 1).is_err());
        }
    }
}
