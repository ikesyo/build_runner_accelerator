use crate::protocol::{
    BINARY_BUILD_RESULT_MAGIC, BuildResult, IncomingFrame, decode_build_batch_result_frame,
    decode_build_result_frame, read_message_with_size, write_binary_frame, write_frame,
};
use crate::worker_kernel::resolve_worker_kernel;
use crate::workspace::{Workspace, matches_glob};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::io::{self, BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const BINARY_READ_CAPABILITY: &str = "asset-rpc-binary-read-v1";
const BINARY_BUILD_RESULT_CAPABILITY: &str = "build-result-binary-v1";

fn is_worker_script(worker_executable: &str) -> bool {
    let path = Path::new(worker_executable);
    path.is_absolute()
        || path.extension().and_then(|extension| extension.to_str()) == Some("dart")
}

pub struct WorkerClient {
    child: Child,
    input: BufWriter<ChildStdin>,
    output: BufReader<ChildStdout>,
    next_id: u64,
    metrics: WorkerClientMetrics,
}

#[derive(Clone, Copy, Default)]
struct WorkerClientMetrics {
    worker_start_us: u64,
    worker_initialize_us: u64,
    worker_reset_us: u64,
    resolver_reset_us: u64,
    build_us: u64,
    asset_rpc_us: u64,
    ipc_frames_sent: u64,
    ipc_frames_received: u64,
    ipc_bytes_sent: u64,
    ipc_bytes_received: u64,
    build_result_frames: u64,
    build_result_bytes: u64,
    build_result_json_bytes: u64,
    asset_requests: u64,
    read_requests: u64,
    read_bytes: u64,
    binary_read_responses: u64,
    can_read_requests: u64,
    find_assets_requests: u64,
    find_assets_results: u64,
}

impl WorkerClientMetrics {
    fn add(&mut self, other: Self) {
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
        self.can_read_requests += other.can_read_requests;
        self.find_assets_requests += other.find_assets_requests;
        self.find_assets_results += other.find_assets_results;
    }
}

impl WorkerClient {
    pub fn start(
        root: &Path,
        dart_binary: &str,
        worker_executable: &str,
        worker_kernel: Option<&Path>,
    ) -> io::Result<Self> {
        let started = Instant::now();
        let mut command = Command::new(dart_binary);
        if let Some(worker_kernel) = worker_kernel {
            let package_config = root.join(".dart_tool/package_config.json");
            command
                .arg(format!("--packages={}", package_config.display()))
                .arg(worker_kernel);
        } else if is_worker_script(worker_executable) {
            command
                .arg(format!(
                    "--packages={}",
                    root.join(".dart_tool/package_config.json").display()
                ))
                .arg(worker_executable);
        } else {
            command.args(["--suppress-analytics", "run", worker_executable]);
        }
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
        })
    }

    pub fn initialize(
        &mut self,
        root: &Path,
        package: &str,
        phase_count: usize,
    ) -> io::Result<()> {
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
        self.metrics.worker_initialize_us += started.elapsed().as_micros() as u64;
        Ok(())
    }

    pub fn reset(&mut self) -> io::Result<()> {
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

    pub fn reset_resolver(&mut self) -> io::Result<()> {
        let started = Instant::now();
        let id = self.next_id();
        self.send(&json!({
            "v": 1,
            "type": "reset_resolver",
            "id": id,
        }))?;
        let response = self.receive_json()?;
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
    ) -> io::Result<BuildResult> {
        let started = Instant::now();
        let id = self.next_id();
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
        }))?;

        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => {
                        self.handle_asset_request(workspace, &response, overlay, deleted_overlay)?
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
    ) -> io::Result<Vec<BuildResult>> {
        let started = Instant::now();
        let id = self.next_id();
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
                })
            })
            .collect::<Vec<_>>();
        self.send(&json!({
            "v": 1,
            "type": "build_batch",
            "id": id,
            "requests": batch_requests,
        }))?;

        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => {
                        self.handle_asset_request(workspace, &response, overlay, deleted_overlay)?
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
                    let decoded = decode_build_batch_result_frame(frame)?;
                    self.record_json_build_batch_result_size(decoded.id, &decoded.results)?;
                    if decoded.id != id {
                        return Err(io::Error::other("worker batch response id mismatch"));
                    }
                    let results = decoded.results;
                    if results.len() != requests.len() {
                        return Err(io::Error::other("worker batch result count mismatch"));
                    }
                    self.metrics.build_us += started.elapsed().as_micros() as u64;
                    return Ok(results);
                }
            }
        }
    }

    fn handle_asset_request(
        &mut self,
        workspace: &Workspace,
        request: &Value,
        overlay: &BTreeMap<String, Vec<u8>>,
        deleted_overlay: &BTreeSet<String>,
    ) -> io::Result<()> {
        let started = Instant::now();
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("asset request has no id"))?;
        let operation = request
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or_default();
        self.metrics.asset_requests += 1;
        let response = match operation {
            "read" => {
                self.metrics.read_requests += 1;
                let asset = request
                    .get("asset")
                    .and_then(Value::as_str)
                    .ok_or_else(|| io::Error::other("read request has no asset"))?;
                let read_result = if deleted_overlay.contains(asset) {
                    Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        format!("asset not found: {asset}"),
                    ))
                } else {
                    overlay
                        .get(asset)
                        .cloned()
                        .map(Arc::new)
                        .map(Ok)
                        .unwrap_or_else(|| workspace.read_asset_or_cache_shared(asset))
                };
                match read_result {
                    Ok(bytes) => {
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
                            bytes.as_slice(),
                        );
                        self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
                        return result;
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        json!({ "v": 1, "type": "asset_response", "id": id, "ok": false, "error": error.to_string() })
                    }
                    Err(error) => return Err(error),
                }
            }
            "can_read" => {
                self.metrics.can_read_requests += 1;
                let asset = request
                    .get("asset")
                    .and_then(Value::as_str)
                    .ok_or_else(|| io::Error::other("can_read request has no asset"))?;
                let value = !deleted_overlay.contains(asset)
                    && (overlay.contains_key(asset) || workspace.asset_exists_or_cache(asset)?);
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
                let mut assets = workspace
                    .find_assets(package, pattern)?
                    .into_iter()
                    .filter(|asset| !deleted_overlay.contains(asset))
                    .collect::<Vec<_>>();
                for asset in overlay.keys() {
                    if !deleted_overlay.contains(asset) {
                        if let Some((asset_package, asset_path)) = asset.split_once('|') {
                            if asset_package == package && matches_glob(pattern, asset_path) {
                                assets.push(asset.clone());
                            }
                        }
                    }
                }
                assets.sort();
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

    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    fn send(&mut self, message: &Value) -> io::Result<()> {
        let frame_size = write_frame(&mut self.input, message)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    fn send_binary(&mut self, metadata: &Value, bytes: &[u8]) -> io::Result<()> {
        let frame_size = write_binary_frame(&mut self.input, metadata, bytes)?;
        self.metrics.ipc_frames_sent += 1;
        self.metrics.ipc_bytes_sent += frame_size as u64;
        Ok(())
    }

    fn receive(&mut self) -> io::Result<IncomingFrame> {
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

    fn receive_json(&mut self) -> io::Result<Value> {
        match self.receive()? {
            IncomingFrame::Json(message) => Ok(message),
            IncomingFrame::Binary(_) => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unexpected binary IPC frame",
            )),
        }
    }

    fn record_json_build_result_size(&mut self, result: &BuildResult) -> io::Result<()> {
        if metrics_enabled() {
            self.metrics.build_result_json_bytes += json_build_result_frame_size(result)?;
        }
        Ok(())
    }

    fn record_json_build_batch_result_size(
        &mut self,
        id: u64,
        results: &[BuildResult],
    ) -> io::Result<()> {
        if metrics_enabled() {
            self.metrics.build_result_json_bytes +=
                json_build_batch_result_frame_size(id, results)?;
        }
        Ok(())
    }

    fn metrics(&self) -> WorkerClientMetrics {
        self.metrics
    }
}

impl Drop for WorkerClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Clone)]
pub struct BuildRequest {
    pub builder: String,
    pub input: String,
    pub outputs: Vec<String>,
    pub options: BTreeMap<String, Value>,
    pub phase: u32,
    pub instance_key: String,
    pub post_process: bool,
}

pub struct WorkerPool {
    workers: Vec<WorkerClient>,
    dart_binary: String,
    worker_executable: String,
    worker_kernel: Option<PathBuf>,
    auto_worker_kernel: bool,
    max_jobs: usize,
    initialized: Option<(PathBuf, String, String, usize)>,
    initialized_workers: usize,
    retired_metrics: WorkerClientMetrics,
    worker_starts: u64,
    worker_initializes: u64,
    worker_resets: u64,
    resolver_resets: u64,
}

#[derive(Clone, Copy, Default)]
pub struct PoolMetrics {
    pub active_workers: usize,
    pub worker_starts: u64,
    pub worker_initializes: u64,
    pub worker_resets: u64,
    pub resolver_resets: u64,
    pub worker_start_us: u64,
    pub worker_initialize_us: u64,
    pub worker_reset_us: u64,
    pub resolver_reset_us: u64,
    pub build_us: u64,
    pub asset_rpc_us: u64,
    pub ipc_frames_sent: u64,
    pub ipc_frames_received: u64,
    pub ipc_bytes_sent: u64,
    pub ipc_bytes_received: u64,
    pub build_result_frames: u64,
    pub build_result_bytes: u64,
    pub build_result_json_bytes: u64,
    pub asset_requests: u64,
    pub read_requests: u64,
    pub read_bytes: u64,
    pub binary_read_responses: u64,
    pub can_read_requests: u64,
    pub find_assets_requests: u64,
    pub find_assets_results: u64,
}

impl WorkerPool {
    pub fn start(
        root: &Path,
        dart_binary: &str,
        worker_executable: &str,
        jobs: usize,
        auto_worker_kernel: bool,
    ) -> io::Result<Self> {
        let dart_binary = dart_binary.to_owned();
        let worker_executable = worker_executable.to_owned();
        let worker_kernel = resolve_worker_kernel(
            root,
            &dart_binary,
            &worker_executable,
            auto_worker_kernel,
        )?;
        let max_jobs = jobs.max(1);
        // Keep the initial pool small. Additional workers are started only when
        // a phase actually has enough independent actions to use them.
        let workers = vec![WorkerClient::start(
            root,
            &dart_binary,
            &worker_executable,
            worker_kernel.as_deref(),
        )?];
        Ok(Self {
            workers,
            dart_binary,
            worker_executable,
            worker_kernel,
            auto_worker_kernel,
            max_jobs,
            initialized: None,
            initialized_workers: 0,
            retired_metrics: WorkerClientMetrics::default(),
            worker_starts: 1,
            worker_initializes: 0,
            worker_resets: 0,
            resolver_resets: 0,
        })
    }

    pub fn initialize(
        &mut self,
        root: &Path,
        package: &str,
        config_digest: &str,
        phase_count: usize,
    ) -> io::Result<()> {
        let signature = (
            root.to_path_buf(),
            package.to_owned(),
            config_digest.to_owned(),
            phase_count,
        );
        if self.initialized.as_ref() == Some(&signature) {
            let reset_count = self.initialized_workers.min(self.workers.len());
            for worker in self.workers.iter_mut().take(reset_count) {
                worker.reset()?;
            }
            self.worker_resets += reset_count as u64;
            self.initialize_pending_workers(root, package, phase_count)?;
            return Ok(());
        }

        if self.initialized.is_some() {
            self.worker_kernel = resolve_worker_kernel(
                root,
                &self.dart_binary,
                &self.worker_executable,
                self.auto_worker_kernel,
            )?;
            let worker_count = self.workers.len().max(1);
            self.retire_workers(0);
            self.workers = (0..worker_count)
                .map(|_| {
                    WorkerClient::start(
                        root,
                        &self.dart_binary,
                        &self.worker_executable,
                        self.worker_kernel.as_deref(),
                    )
                })
                .collect::<io::Result<Vec<_>>>()?;
            self.worker_starts += worker_count as u64;
        }
        self.initialized_workers = 0;
        self.initialize_pending_workers(root, package, phase_count)?;
        self.initialized = Some(signature);
        Ok(())
    }

    pub fn prepare_for_requests(&mut self, root: &Path, request_count: usize) -> io::Result<()> {
        let target = target_worker_count(self.max_jobs, request_count);
        if self.workers.len() > target {
            self.retire_workers(target);
            self.initialized_workers = self.initialized_workers.min(target);
        }
        while self.workers.len() < target {
            self.workers.push(WorkerClient::start(
                root,
                &self.dart_binary,
                &self.worker_executable,
                self.worker_kernel.as_deref(),
            )?);
            self.worker_starts += 1;
        }
        Ok(())
    }

    fn initialize_pending_workers(
        &mut self,
        root: &Path,
        package: &str,
        phase_count: usize,
    ) -> io::Result<()> {
        let pending = self.workers.len().saturating_sub(self.initialized_workers);
        for worker in self.workers.iter_mut().skip(self.initialized_workers) {
            worker.initialize(root, package, phase_count)?;
        }
        self.worker_initializes += pending as u64;
        self.initialized_workers = self.workers.len();
        Ok(())
    }

    fn retire_workers(&mut self, keep: usize) {
        if self.workers.len() <= keep {
            return;
        }
        for worker in self.workers.split_off(keep) {
            self.retired_metrics.add(worker.metrics());
        }
    }

    pub fn metrics(&self) -> PoolMetrics {
        let mut worker_metrics = self.retired_metrics;
        for worker in &self.workers {
            worker_metrics.add(worker.metrics());
        }
        PoolMetrics {
            active_workers: self.workers.len(),
            worker_starts: self.worker_starts,
            worker_initializes: self.worker_initializes,
            worker_resets: self.worker_resets,
            resolver_resets: self.resolver_resets,
            worker_start_us: worker_metrics.worker_start_us,
            worker_initialize_us: worker_metrics.worker_initialize_us,
            worker_reset_us: worker_metrics.worker_reset_us,
            resolver_reset_us: worker_metrics.resolver_reset_us,
            build_us: worker_metrics.build_us,
            asset_rpc_us: worker_metrics.asset_rpc_us,
            ipc_frames_sent: worker_metrics.ipc_frames_sent,
            ipc_frames_received: worker_metrics.ipc_frames_received,
            ipc_bytes_sent: worker_metrics.ipc_bytes_sent,
            ipc_bytes_received: worker_metrics.ipc_bytes_received,
            build_result_frames: worker_metrics.build_result_frames,
            build_result_bytes: worker_metrics.build_result_bytes,
            build_result_json_bytes: worker_metrics.build_result_json_bytes,
            asset_requests: worker_metrics.asset_requests,
            read_requests: worker_metrics.read_requests,
            read_bytes: worker_metrics.read_bytes,
            binary_read_responses: worker_metrics.binary_read_responses,
            can_read_requests: worker_metrics.can_read_requests,
            find_assets_requests: worker_metrics.find_assets_requests,
            find_assets_results: worker_metrics.find_assets_results,
        }
    }

    pub fn build_parallel(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Vec<u8>>,
        deleted_overlay: &BTreeSet<String>,
    ) -> io::Result<Vec<BuildResult>> {
        if requests.is_empty() {
            return Ok(Vec::new());
        }
        self.prepare_for_requests(&workspace.root, requests.len())?;
        let (root, package) = match &self.initialized {
            Some((root, package, _, _)) => (root.clone(), package.clone()),
            None => {
                return Err(io::Error::other(
                    "worker pool must be initialized before building",
                ));
            }
        };
        let phase_count = self
            .initialized
            .as_ref()
            .map(|(_, _, _, phase_count)| *phase_count)
            .unwrap_or(1);
        self.initialize_pending_workers(&root, &package, phase_count)?;
        if self.workers.len() == 1 {
            return self.workers[0].build_batch(workspace, requests, overlay, deleted_overlay);
        }

        let worker_count = self.workers.len();
        let ranges = balanced_request_ranges(requests.len(), worker_count);
        let batches = ranges
            .iter()
            .map(|(start, end)| &requests[*start..*end])
            .collect::<Vec<_>>();
        let batch_results = thread::scope(|scope| {
            let handles = self
                .workers
                .iter_mut()
                .zip(batches)
                .map(|(worker, batch)| {
                    scope.spawn(move || {
                        worker.build_batch(workspace, batch, overlay, deleted_overlay)
                    })
                })
                .collect::<Vec<_>>();

            handles
                .into_iter()
                .map(|handle| {
                    handle
                        .join()
                        .map_err(|_| io::Error::other("worker thread panicked"))?
                })
                .collect::<io::Result<Vec<_>>>()
        })?;

        let mut results = Vec::with_capacity(requests.len());
        for batch in batch_results {
            results.extend(batch);
        }
        Ok(results)
    }

    pub fn reset_resolver(&mut self) -> io::Result<()> {
        let count = self.initialized_workers.min(self.workers.len());
        for worker in self.workers.iter_mut().take(count) {
            worker.reset_resolver()?;
        }
        self.resolver_resets += count as u64;
        Ok(())
    }
}

fn target_worker_count(max_jobs: usize, request_count: usize) -> usize {
    max_jobs.max(1).min(request_count.max(1))
}

fn balanced_request_ranges(request_count: usize, worker_count: usize) -> Vec<(usize, usize)> {
    let worker_count = worker_count.max(1).min(request_count.max(1));
    let base_size = request_count / worker_count;
    let remainder = request_count % worker_count;
    let mut start = 0;
    let mut ranges = Vec::with_capacity(worker_count);
    for worker_index in 0..worker_count {
        let size = base_size + if worker_index < remainder { 1 } else { 0 };
        let end = start + size;
        ranges.push((start, end));
        start = end;
    }
    ranges
}

fn metrics_enabled() -> bool {
    env::var("FAST_BUILD_RUNNER_METRICS")
        .map(|value| value == "1")
        .unwrap_or(false)
}

fn json_build_result_value(result: &BuildResult) -> io::Result<Value> {
    let mut value = serde_json::to_value(result).map_err(io::Error::other)?;
    let object = value.as_object_mut().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "build result did not serialize to an object",
        )
    })?;
    object.insert("v".to_owned(), json!(1));
    Ok(value)
}

fn json_build_result_frame_size(result: &BuildResult) -> io::Result<u64> {
    let value = json_build_result_value(result)?;
    let payload = serde_json::to_vec(&value).map_err(io::Error::other)?;
    Ok((payload.len() + 4) as u64)
}

fn json_build_batch_result_frame_size(id: u64, results: &[BuildResult]) -> io::Result<u64> {
    let results = results
        .iter()
        .map(json_build_result_value)
        .collect::<io::Result<Vec<_>>>()?;
    let value = json!({
        "v": 1,
        "type": "build_batch_result",
        "id": id,
        "results": results,
    });
    let payload = serde_json::to_vec(&value).map_err(io::Error::other)?;
    Ok((payload.len() + 4) as u64)
}

#[cfg(test)]
mod tests {
    use super::{balanced_request_ranges, has_capability, is_worker_script, target_worker_count};
    use serde_json::json;

    #[test]
    fn worker_count_follows_available_requests() {
        assert_eq!(target_worker_count(4, 0), 1);
        assert_eq!(target_worker_count(4, 1), 1);
        assert_eq!(target_worker_count(4, 3), 3);
        assert_eq!(target_worker_count(4, 8), 4);
        assert_eq!(target_worker_count(1, 8), 1);
    }

    #[test]
    fn requests_are_split_into_balanced_contiguous_batches() {
        assert_eq!(
            balanced_request_ranges(10, 3),
            vec![(0, 4), (4, 7), (7, 10)]
        );
        assert_eq!(balanced_request_ranges(3, 3), vec![(0, 1), (1, 2), (2, 3)]);
        assert_eq!(balanced_request_ranges(2, 4), vec![(0, 1), (1, 2)]);
    }

    #[test]
    fn binary_read_capability_is_required() {
        let response = json!({
            "capabilities": ["asset-rpc-v1", "asset-rpc-binary-read-v1"]
        });
        assert!(has_capability(&response, "asset-rpc-binary-read-v1"));
        assert!(!has_capability(&response, "other-capability"));
        assert!(!has_capability(&json!({}), "asset-rpc-binary-read-v1"));
    }

    #[test]
    fn dart_scripts_bypass_package_runner_and_kernel() {
        assert!(is_worker_script("/tmp/dynamic_worker.dart"));
        assert!(is_worker_script("relative_worker.dart"));
        assert!(!is_worker_script("example_builder:worker"));
    }
}

impl Drop for WorkerPool {
    fn drop(&mut self) {
        self.workers.clear();
    }
}

fn protocol_error(prefix: &str, value: &Value) -> io::Error {
    let detail = value
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or_else(|| value.to_string().leak());
    let stack = value.get("stack").and_then(Value::as_str);
    match stack {
        Some(stack) if !stack.is_empty() => io::Error::other(format!(
            "{prefix}: {detail}\n{stack}"
        )),
        _ => io::Error::other(format!("{prefix}: {detail}")),
    }
}

fn has_capability(response: &Value, required: &str) -> bool {
    response
        .get("capabilities")
        .and_then(Value::as_array)
        .is_some_and(|capabilities| {
            capabilities
                .iter()
                .any(|capability| capability.as_str() == Some(required))
        })
}
