use super::asset_rpc::batch_asset_request_context;
use super::request::{
    BuildRequest, batch_blocked_assets, batch_context, json_build_batch_result_frame_size,
    json_build_result_frame_size,
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
use std::collections::{BTreeMap, BTreeSet};
use std::env;
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
}

/// Transport state belongs to one worker connection. Resets and single builds
/// do not replace the last batch list; initialization starts a fresh context.
#[derive(Default)]
pub(super) struct BlockedAssetsCache {
    pub(super) capable: bool,
    last: Option<Vec<String>>,
}

impl BlockedAssetsCache {
    pub(super) fn new(capable: bool) -> Self {
        Self {
            capable,
            last: None,
        }
    }

    pub(super) fn forget_last(&mut self) {
        self.last = None;
    }

    /// Decides the visibility hint for one batch. When the candidate equals
    /// the list last sent on this connection, the equality is verified
    /// against the cached list without rebuilding the candidate
    /// ([`AssetVisibility::blocked_assets_eq`]) and the reuse form is sent.
    pub(super) fn prepare(
        &mut self,
        requests: &[BuildRequest],
        visibility: &AssetVisibility,
        deleted_overlay: &BTreeSet<String>,
    ) -> io::Result<(Vec<String>, bool)> {
        let Some((phase, kind)) = batch_context(requests)? else {
            return Ok(self.prepare_list(Vec::new()));
        };
        let reuse = self.capable
            && self.last.as_ref().is_some_and(|last| {
                visibility.blocked_assets_eq(phase, kind, deleted_overlay, last)
            });
        if reuse {
            return Ok((Vec::new(), true));
        }
        let assets = batch_blocked_assets(requests, visibility, deleted_overlay)?;
        Ok(self.prepare_list(assets))
    }

    pub(super) fn prepare_list(&mut self, assets: Vec<String>) -> (Vec<String>, bool) {
        if !self.capable {
            return (assets, false);
        }
        if self.last.as_ref() == Some(&assets) {
            return (Vec::new(), true);
        }
        self.last = Some(assets.clone());
        (assets, false)
    }
}

/// One build request in a batch, serialized directly from the borrowed
/// [`BuildRequest`] fields instead of an intermediate JSON value tree.
/// Field order matches the JSON shape the worker has always received;
/// telemetry fields appear only while a telemetry context is active,
/// exactly as the generic send path used to inject them.
#[derive(serde::Serialize)]
pub(super) struct BatchRequestWire<'a> {
    id: u64,
    builder: &'a str,
    input: &'a str,
    kind: &'a str,
    allowed_outputs: &'a [String],
    options: &'a serde_json::Map<String, Value>,
    phase: u32,
    part_phase_index: Option<u32>,
    instance_key: &'a str,
    is_root: bool,
    triggers: &'a [crate::builder::BuilderTrigger],
    #[serde(skip_serializing_if = "Option::is_none")]
    traceparent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    otel_report_id: Option<u64>,
}

/// Batch-level fields shared by every request in a batch, sent once under
/// `shared` when the worker advertises `batch-shared-fields-v1` and the
/// batch is uniform in them. The worker merges them into each child
/// request before decoding it; see ADR 0052.
#[derive(serde::Serialize)]
pub(super) struct BatchSharedWire<'a> {
    builder: &'a str,
    phase: u32,
    kind: &'a str,
    part_phase_index: Option<u32>,
    instance_key: &'a str,
    is_root: bool,
}

/// A batch request in shared-fields form: the fields that
/// [`BatchSharedWire`] does not carry. See [`BatchRequestWire`].
#[derive(serde::Serialize)]
pub(super) struct BatchSharedRequestWire<'a> {
    id: u64,
    input: &'a str,
    allowed_outputs: &'a [String],
    options: &'a serde_json::Map<String, Value>,
    triggers: &'a [crate::builder::BuilderTrigger],
    #[serde(skip_serializing_if = "Option::is_none")]
    traceparent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    otel_report_id: Option<u64>,
}

/// The `build_batch` envelope. See [`BatchRequestWire`].
#[derive(serde::Serialize)]
pub(super) struct BatchWire<'a, R> {
    pub(super) v: u32,
    #[serde(rename = "type")]
    pub(super) message_type: &'a str,
    pub(super) id: u64,
    pub(super) blocked_assets: &'a [String],
    pub(super) blocked_assets_reuse: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) shared: Option<BatchSharedWire<'a>>,
    pub(super) requests: &'a [R],
}

/// The single `build` envelope used by the lazy/nested path, carrying its
/// own visibility hint. See [`BatchRequestWire`].
#[derive(serde::Serialize)]
pub(super) struct BuildWire<'a> {
    pub(super) v: u32,
    #[serde(rename = "type")]
    pub(super) message_type: &'a str,
    pub(super) id: u64,
    pub(super) builder: &'a str,
    pub(super) input: &'a str,
    pub(super) kind: &'a str,
    pub(super) allowed_outputs: &'a [String],
    pub(super) options: &'a serde_json::Map<String, Value>,
    pub(super) phase: u32,
    pub(super) part_phase_index: Option<u32>,
    pub(super) instance_key: &'a str,
    pub(super) is_root: bool,
    pub(super) blocked_assets: &'a [String],
    pub(super) triggers: &'a [crate::builder::BuilderTrigger],
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) traceparent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) otel_report_id: Option<u64>,
}

/// Per-request telemetry fields, mirroring the generic send path: one
/// message-level context, consumed by the first request; later requests
/// draw fresh contexts. All `None` when no session is active.
fn telemetry_contexts(count: usize) -> Vec<(Option<String>, Option<u64>)> {
    telemetry_contexts_with(count, crate::telemetry::request_context)
}

/// The provider-taking core of [`telemetry_contexts`], split out so tests
/// can script the contexts without a live telemetry session.
fn telemetry_contexts_with(
    count: usize,
    mut provider: impl FnMut() -> Option<(String, u64)>,
) -> Vec<(Option<String>, Option<u64>)> {
    let mut first_context = provider();
    let inject = first_context.is_some();
    (0..count)
        .map(|_| {
            if inject {
                match first_context.take().or_else(&mut provider) {
                    Some((parent, report_id)) => (Some(parent), Some(report_id)),
                    None => (None, None),
                }
            } else {
                (None, None)
            }
        })
        .collect()
}

pub(super) fn batch_request_wires(requests: &[BuildRequest]) -> Vec<BatchRequestWire<'_>> {
    batch_request_wires_with(requests, crate::telemetry::request_context)
}

pub(super) fn batch_request_wires_with(
    requests: &[BuildRequest],
    provider: impl FnMut() -> Option<(String, u64)>,
) -> Vec<BatchRequestWire<'_>> {
    let contexts = telemetry_contexts_with(requests.len(), provider);
    requests
        .iter()
        .enumerate()
        .zip(contexts)
        .map(
            |((index, request), (traceparent, otel_report_id))| BatchRequestWire {
                id: index as u64,
                builder: &request.builder,
                input: &request.input,
                kind: if request.post_process {
                    "post_process"
                } else {
                    "normal"
                },
                allowed_outputs: &request.outputs,
                options: &request.options,
                phase: request.phase,
                part_phase_index: request.part_phase_index,
                instance_key: &request.instance_key,
                is_root: request.is_root,
                triggers: &request.triggers,
                traceparent,
                otel_report_id,
            },
        )
        .collect()
}

pub(super) fn batch_shared_request_wires(
    requests: &[BuildRequest],
) -> Vec<BatchSharedRequestWire<'_>> {
    let contexts = telemetry_contexts(requests.len());
    requests
        .iter()
        .enumerate()
        .zip(contexts)
        .map(
            |((index, request), (traceparent, otel_report_id))| BatchSharedRequestWire {
                id: index as u64,
                input: &request.input,
                allowed_outputs: &request.outputs,
                options: &request.options,
                triggers: &request.triggers,
                traceparent,
                otel_report_id,
            },
        )
        .collect()
}

/// The shared-fields form of a batch, when every request agrees on the
/// fields it lifts. Single-request batches keep the full form: there is
/// nothing to deduplicate.
pub(super) fn batch_shared_fields(requests: &[BuildRequest]) -> Option<BatchSharedWire<'_>> {
    let first = requests.first()?;
    if requests.len() < 2 {
        return None;
    }
    let uniform = requests.iter().all(|request| {
        request.builder == first.builder
            && request.phase == first.phase
            && request.post_process == first.post_process
            && request.part_phase_index == first.part_phase_index
            && request.instance_key == first.instance_key
            && request.is_root == first.is_root
    });
    uniform.then(|| BatchSharedWire {
        builder: &first.builder,
        phase: first.phase,
        kind: if first.post_process {
            "post_process"
        } else {
            "normal"
        },
        part_phase_index: first.part_phase_index,
        instance_key: &first.instance_key,
        is_root: first.is_root,
    })
}

pub(super) fn build_wire<'a>(
    id: u64,
    request: &'a BuildRequest,
    blocked_assets: &'a [String],
) -> BuildWire<'a> {
    let (traceparent, otel_report_id) = match crate::telemetry::request_context() {
        Some((parent, report_id)) => (Some(parent), Some(report_id)),
        None => (None, None),
    };
    BuildWire {
        v: 1,
        message_type: "build",
        id,
        builder: &request.builder,
        input: &request.input,
        kind: if request.post_process {
            "post_process"
        } else {
            "normal"
        },
        allowed_outputs: &request.outputs,
        options: &request.options,
        phase: request.phase,
        part_phase_index: request.part_phase_index,
        instance_key: &request.instance_key,
        is_root: request.is_root,
        blocked_assets,
        triggers: &request.triggers,
        traceparent,
        otel_report_id,
    }
}

#[derive(Clone, Copy, Default)]
pub(super) struct WorkerClientMetrics {
    pub(super) worker_start_us: u64,
    pub(super) worker_initialize_us: u64,
    pub(super) worker_reset_us: u64,
    pub(super) resolver_reset_us: u64,
    pub(super) build_us: u64,
    pub(super) asset_rpc_us: u64,
    pub(super) ipc_frames_sent: u64,
    pub(super) ipc_frames_received: u64,
    pub(super) ipc_bytes_sent: u64,
    pub(super) ipc_bytes_received: u64,
    pub(super) build_result_frames: u64,
    pub(super) build_result_bytes: u64,
    pub(super) build_result_json_bytes: u64,
    pub(super) asset_requests: u64,
    pub(super) read_requests: u64,
    pub(super) read_bytes: u64,
    pub(super) binary_read_responses: u64,
    pub(super) path_read_responses: u64,
    pub(super) can_read_requests: u64,
    pub(super) find_assets_requests: u64,
    pub(super) find_assets_results: u64,
    pub(super) resolve_assets_requests: u64,
    pub(super) resolve_assets_results: u64,
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
                let package_config = crate::runner_compatibility::package_config(root);
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
                            crate::runner_compatibility::package_config(root).display()
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
            shared_parts_capable: false,
            batch_shared_fields_capable: false,
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
        let result =
            self.build_batch_inner(workspace, requests, overlay, deleted_overlay, visibility);
        // A worker can reject a batch before accepting its visibility hint.
        // Forget on every error so a retry cannot reuse an unaccepted list.
        if result.is_err() {
            self.blocked_assets_cache.forget_last();
        }
        result
    }

    fn build_batch_inner(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
    ) -> io::Result<Vec<BuildResult>> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_batch", Some(id));
        let metrics_before = self.metrics;
        let encoding = self.wall_span("request_encode_send", Some(id));
        // Every request in this batch has the same phase and kind. Keep the
        // visibility hint at the batch level instead of copying the full
        // blocked-asset list into every request.
        let (blocked_assets, blocked_assets_reuse) =
            self.blocked_assets_cache
                .prepare(requests, visibility, deleted_overlay)?;
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
                        self.handle_asset_request(
                            workspace,
                            &response,
                            overlay,
                            deleted_overlay,
                            visibility,
                            active_request,
                            build_id,
                            None,
                        )?
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
        let mut traced;
        let message = if matches!(
            message.get("type").and_then(Value::as_str),
            Some("build" | "build_batch")
        ) {
            if let Some((parent, report_id)) = crate::telemetry::request_context() {
                traced = message.clone();
                if let Some(requests) = traced.get_mut("requests").and_then(Value::as_array_mut) {
                    let mut first = Some((parent, report_id));
                    for request in requests {
                        if let Some((parent, report_id)) =
                            first.take().or_else(crate::telemetry::request_context)
                        {
                            request["traceparent"] = Value::String(parent);
                            request["otel_report_id"] = Value::from(report_id);
                        }
                    }
                } else {
                    traced["traceparent"] = Value::String(parent);
                    traced["otel_report_id"] = Value::from(report_id);
                }
                &traced
            } else {
                message
            }
        } else {
            message
        };
        let frame_size = write_frame(&mut self.input, message)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    /// Sends a typed build message, serializing it once into the reusable
    /// buffer instead of building an intermediate JSON value tree. Telemetry
    /// context fields are populated by the wire constructors, so unlike
    /// [`Self::send`] this path never clones the message.
    pub(super) fn send_serialized<T: serde::Serialize>(&mut self, message: &T) -> io::Result<()> {
        let frame_size = write_frame_buffered(&mut self.input, message, &mut self.send_buffer)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
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
        if self.batch_shared_fields_capable
            && let Some(shared) = batch_shared_fields(requests)
        {
            let wires = batch_shared_request_wires(requests);
            return self.send_serialized(&BatchWire {
                v: 1,
                message_type: "build_batch",
                id,
                blocked_assets,
                blocked_assets_reuse,
                shared: Some(shared),
                requests: &wires,
            });
        }
        let wires = batch_request_wires(requests);
        self.send_serialized(&BatchWire {
            v: 1,
            message_type: "build_batch",
            id,
            blocked_assets,
            blocked_assets_reuse,
            shared: None,
            requests: &wires,
        })
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
        if metrics_enabled() {
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
        if metrics_enabled() {
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

fn metrics_enabled() -> bool {
    env::var("BUILD_RUNNER_ACCELERATOR_METRICS")
        .map(|value| value == "1")
        .unwrap_or(false)
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
