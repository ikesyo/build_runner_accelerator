use super::asset_rpc::batch_asset_request_context;
use super::request::{
    batch_blocked_assets, build_request_kind, json_build_batch_result_frame_size,
    json_build_result_frame_size, BuildRequest,
};
use crate::protocol::{
    BINARY_BUILD_RESULT_MAGIC, BuildResult, IncomingFrame, decode_build_batch_result_frame,
    decode_build_result_frame, read_message_with_size, write_binary_frame, write_frame,
};
use crate::worker_kernel::WorkerArtifact;
use crate::visibility::AssetVisibility;
use crate::workspace::Workspace;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::io::{self, BufReader, BufWriter};
use std::path::Path;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::Instant;

const BINARY_READ_CAPABILITY: &str = "asset-rpc-binary-read-v1";
const BINARY_BUILD_RESULT_CAPABILITY: &str = "build-result-binary-v1";
const OPTIONAL_BUILD_CAPABILITY: &str = "optional-builder-demand-v1";
const SHARED_BLOCKED_ASSETS_CAPABILITY: &str = "shared-blocked-assets-v1";

pub(super) fn is_worker_script(worker_executable: &str) -> bool {
    let path = Path::new(worker_executable);
    path.is_absolute()
        || path.extension().and_then(|extension| extension.to_str()) == Some("dart")
}

pub struct WorkerClient {
    child: Child,
    input: BufWriter<ChildStdin>,
    output: BufReader<ChildStdout>,
    pub(super) next_id: u64,
    pub(super) metrics: WorkerClientMetrics,
    /// Resolver dependency edges reported with this client's batch results.
    pub(super) dep_graph: BTreeMap<String, Vec<String>>,
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
                let package_config = root.join(".dart_tool/package_config.json");
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
                            root.join(".dart_tool/package_config.json").display()
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
        })
    }

    pub fn initialize(
        &mut self,
        root: &Path,
        package: &str,
        phase_count: usize,
        requires_optional_builder: bool,
    ) -> io::Result<()> {
        let _wall = self.wall_span("worker_initialize", None);
        let started = Instant::now();
        let id = self.next_id();
        self.send(&json!({
            "v": 1,
            "type": "initialize",
            "id": id,
            "root": root,
            "package": package,
            "phase_count": phase_count,
            "resolver_mode": "dart_local"
        }))?;
        let response = self.receive_json()?;
        if response.get("type").and_then(Value::as_str) != Some("initialized") {
            return Err(protocol_error("worker initialization failed", &response));
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
        self.metrics.worker_initialize_us += started.elapsed().as_micros() as u64;
        Ok(())
    }

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

    pub fn reset_resolver(
        &mut self,
        updated_sources: &Value,
        deleted_sources: &Value,
        updated_cache: &Value,
        deleted_cache: &Value,
        incremental: bool,
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

    pub fn build(
        &mut self,
        workspace: &Workspace,
        request: &BuildRequest,
        overlay: &BTreeMap<String, Vec<u8>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
    ) -> io::Result<BuildResult> {
        let started = Instant::now();
        let id = self.next_id();
        let blocked_assets = visibility.blocked_assets(
            request.phase,
            build_request_kind(request),
            deleted_overlay,
        );
        self.send(&json!({
            "v": 1,
            "type": "build",
            "id": id,
            "builder": request.builder,
            "input": request.input,
            "kind": if request.post_process { "post_process" } else { "normal" },
            "allowed_outputs": request.outputs,
            "options": request.options,
            "phase": request.phase,
            "instance_key": request.instance_key,
            "is_root": request.is_root,
            "blocked_assets": blocked_assets,
            "triggers": request.triggers,
        }))?;

        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => {
                        self.handle_asset_request(
                            workspace,
                            &response,
                            overlay,
                            deleted_overlay,
                            visibility,
                            request,
                            id,
                        )?
                    }
                    Some("build_result") => {
                        return Err(io::Error::other(
                            "worker sent JSON build result; binary capability is required",
                        ));
                    }
                    Some("error") => return Err(protocol_error("worker error", &response)),
                    _ => return Err(protocol_error("unexpected worker message", &response)),
                },
                IncomingFrame::Binary(frame) => {
                    let result = decode_build_result_frame(frame)?;
                    self.record_json_build_result_size(&result)?;
                    if result.id != id {
                        return Err(io::Error::other("worker response id mismatch"));
                    }
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    return Ok(result);
                }
            }
        }
    }

    pub fn build_batch(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Vec<u8>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
    ) -> io::Result<Vec<BuildResult>> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_batch", Some(id));
        let encoding = self.wall_span("request_encode_send", Some(id));
        // Every request in this batch has the same phase and kind. Keep the
        // visibility hint at the batch level instead of copying the full
        // blocked-asset list into every request.
        let blocked_assets = batch_blocked_assets(requests, visibility, deleted_overlay)?;
        let batch_requests = requests
            .iter()
            .enumerate()
            .map(|(index, request)| {
                json!({
                    "id": index as u64,
                    "builder": request.builder,
                    "input": request.input,
                    "kind": if request.post_process { "post_process" } else { "normal" },
                    "allowed_outputs": request.outputs,
                    "options": request.options,
                    "phase": request.phase,
                    "instance_key": request.instance_key,
                    "is_root": request.is_root,
                    "triggers": request.triggers,
                })
            })
            .collect::<Vec<_>>();
        self.send(&json!({
            "v": 1,
            "type": "build_batch",
            "id": id,
            "blocked_assets": blocked_assets,
            "requests": batch_requests,
        }))?;

        drop(encoding);
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
                        )?
                    }
                    Some("build_batch_result") => {
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
                    if decoded.id != id {
                        return Err(io::Error::other("worker batch response id mismatch"));
                    }
                    self.dep_graph.extend(decoded.dep_graph);
                    let results = decoded.results;
                    if results.len() != requests.len() {
                        return Err(io::Error::other("worker batch result count mismatch"));
                    }
                    if results
                        .iter()
                        .enumerate()
                        .any(|(index, result)| result.id != index as u64)
                    {
                        return Err(io::Error::other("worker batch result id mismatch"));
                    }
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    return Ok(results);
                }
            }
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
        let frame_size = write_frame(&mut self.input, message)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    pub(super) fn send_binary(&mut self, metadata: &Value, bytes: &[u8]) -> io::Result<()> {
        let frame_size = write_binary_frame(&mut self.input, metadata, bytes)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    pub(super) fn receive(&mut self) -> io::Result<IncomingFrame> {
        let _receive = self.wall_span("receive_frame", None);
        let (message, frame_size) = read_message_with_size(&mut self.output)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "Dart worker exited"))?;
        self.metrics.ipc_frames_received += 1;
        self.metrics.ipc_bytes_received += frame_size as u64;
        if matches!(
            &message,
            IncomingFrame::Binary(frame) if frame.magic == *BINARY_BUILD_RESULT_MAGIC
        ) {
            self.metrics.build_result_frames += 1;
            self.metrics.build_result_bytes += frame_size as u64;
        }
        Ok(message)
    }

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

pub(super) fn protocol_error(prefix: &str, value: &Value) -> io::Error {
    let detail = value
        .get("error")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string());
    let stack = value.get("stack").and_then(Value::as_str);
    match stack {
        Some(stack) if !stack.is_empty() => io::Error::other(format!(
            "{prefix}: {detail}\n{stack}"
        )),
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
