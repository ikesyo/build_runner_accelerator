use super::client::{WorkerClient, WorkerClientMetrics};
use super::lazy::LazyBuildState;
use super::request::BuildRequest;
use crate::plan::BuildSpec;
use crate::protocol::BuildResult;
use crate::worker_kernel::{
    WorkerArtifact, background_worker_aot_if_ready, pinned_worker_artifact_is_current,
    resolve_worker_artifact,
};
use crate::visibility::AssetVisibility;
use crate::workspace::Workspace;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::thread;

/// Workspace-relative directory where committed overlay contents are spooled
/// for multi-worker incremental resolver resets. The Dart worker resolves
/// `<spool>/<package>/<asset path>` relative to its working directory.
const OVERLAY_SPOOL_DIR: &str = ".dart_tool/build_runner_accelerator/overlay";

pub struct WorkerPool {
    workers: Vec<WorkerClient>,
    dart_binary: String,
    worker_executable: String,
    worker_artifact: WorkerArtifact,
    auto_worker_artifact: bool,
    allow_worker_artifact_upgrade: bool,
    max_jobs: usize,
    initialized: Option<(PathBuf, String, String, usize, bool)>,
    initialized_workers: usize,
    resolver_usage: BTreeMap<(String, String), bool>,
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
    pub path_read_responses: u64,
    pub can_read_requests: u64,
    pub find_assets_requests: u64,
    pub find_assets_results: u64,
    pub resolve_assets_requests: u64,
    pub resolve_assets_results: u64,
}

impl WorkerPool {
    pub fn start(
        root: &Path,
        dart_binary: &str,
        worker_executable: &str,
        jobs: usize,
        auto_worker_artifact: bool,
    ) -> io::Result<Self> {
        let _wall = crate::wall::Span::new("pool_start");
        let dart_binary = dart_binary.to_owned();
        let worker_executable = worker_executable.to_owned();
        let worker_artifact = resolve_worker_artifact(
            root,
            &dart_binary,
            &worker_executable,
            auto_worker_artifact,
        )?;
        let max_jobs = jobs.max(1);
        // Keep the initial pool small. Additional workers are started only when
        // a phase actually has enough independent actions to use them.
        let workers = vec![WorkerClient::start(
            root,
            &dart_binary,
            &worker_executable,
            &worker_artifact,
        )?];
        Ok(Self {
            workers,
            dart_binary,
            worker_executable,
            worker_artifact,
            auto_worker_artifact,
            allow_worker_artifact_upgrade: true,
            max_jobs,
            initialized: None,
            initialized_workers: 0,
            resolver_usage: BTreeMap::new(),
            retired_metrics: WorkerClientMetrics::default(),
            worker_starts: 1,
            worker_initializes: 0,
            worker_resets: 0,
            resolver_resets: 0,
        })
    }

    /// Resolver dependency edges reported by every worker in the pool.
    pub fn take_dep_graph(&mut self) -> BTreeMap<String, Vec<String>> {
        let mut dep_graph = BTreeMap::new();
        for worker in &mut self.workers {
            dep_graph.append(&mut worker.dep_graph);
        }
        dep_graph
    }

    /// Keep the initial worker artifact for the lifetime of a long-running
    /// session such as `watch`. A background AOT compile may finish mid-session,
    /// but replacing the resident worker would reset its state and counters.
    pub fn pin_worker_artifact(&mut self) {
        self.allow_worker_artifact_upgrade = false;
    }

    pub fn initialize(
        &mut self,
        root: &Path,
        package: &str,
        config_digest: &str,
        phase_count: usize,
        requires_optional_builder: bool,
    ) -> io::Result<()> {
        let signature = (
            root.to_path_buf(),
            package.to_owned(),
            config_digest.to_owned(),
            phase_count,
            requires_optional_builder,
        );
        if self.initialized.as_ref() == Some(&signature) {
            if self.auto_worker_artifact && self.allow_worker_artifact_upgrade {
                match background_worker_aot_if_ready(
                    root,
                    &self.dart_binary,
                    &self.worker_executable,
                ) {
                    Ok(Some(aot)) => {
                        let artifact = WorkerArtifact::Aot(aot);
                        if self.worker_artifact != artifact {
                            self.restart_workers(root, artifact)?;
                            self.initialize_pending_workers(
                                root,
                                package,
                                phase_count,
                                requires_optional_builder,
                            )?;
                            return Ok(());
                        }
                    }
                    Ok(None) => {}
                    Err(error) => eprintln!(
                        "Rust worker background AOT is not ready; keeping the current worker ({error})"
                    ),
                }
            }
            let reset_count = self.initialized_workers.min(self.workers.len());
            for worker in self.workers.iter_mut().take(reset_count) {
                worker.reset()?;
            }
            self.worker_resets += reset_count as u64;
            self.initialize_pending_workers(
                root,
                package,
                phase_count,
                requires_optional_builder,
            )?;
            return Ok(());
        }

        if self.initialized.is_some() {
            self.resolver_usage.clear();
            let worker_artifact = if self.allow_worker_artifact_upgrade {
                resolve_worker_artifact(
                    root,
                    &self.dart_binary,
                    &self.worker_executable,
                    self.auto_worker_artifact,
                )?
            } else if pinned_worker_artifact_is_current(
                root,
                &self.dart_binary,
                &self.worker_executable,
                &self.worker_artifact,
            )
            .unwrap_or_else(|error| {
                eprintln!(
                    "Rust pinned worker artifact could not be validated; resolving it again ({error})"
                );
                false
            }) {
                self.worker_artifact.clone()
            } else {
                resolve_worker_artifact(
                    root,
                    &self.dart_binary,
                    &self.worker_executable,
                    self.auto_worker_artifact,
                )?
            };
            self.restart_workers(root, worker_artifact)?;
        }
        self.initialized_workers = 0;
        self.initialize_pending_workers(
            root,
            package,
            phase_count,
            requires_optional_builder,
        )?;
        self.initialized = Some(signature);
        Ok(())
    }

    fn restart_workers(&mut self, root: &Path, worker_artifact: WorkerArtifact) -> io::Result<()> {
        let worker_count = self.workers.len().max(1);
        self.retire_workers(0);
        self.workers = (0..worker_count)
            .map(|_| {
                WorkerClient::start(
                    root,
                    &self.dart_binary,
                    &self.worker_executable,
                    &worker_artifact,
                )
            })
            .collect::<io::Result<Vec<_>>>()?;
        self.worker_starts += worker_count as u64;
        self.worker_artifact = worker_artifact;
        self.initialized_workers = 0;
        Ok(())
    }

    pub fn prepare_for_requests(&mut self, root: &Path, request_count: usize) -> io::Result<()> {
        let _wall = crate::wall::Span::new("pool_expand");
        let target = target_worker_count(self.max_jobs, request_count);
        // Never shrink the pool here: an idle worker that is retired now has to
        // be restarted and re-initialized by the next wider phase, which costs
        // far more than keeping it resident. Retirement only happens on a full
        // restart (artifact upgrade or signature change).
        while self.workers.len() < target {
            self.workers.push(WorkerClient::start(
                root,
                &self.dart_binary,
                &self.worker_executable,
                &self.worker_artifact,
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
        requires_optional_builder: bool,
    ) -> io::Result<()> {
        let _wall = crate::wall::Span::new("pool_initialize_pending");
        let pending = self.workers.len().saturating_sub(self.initialized_workers);
        for worker in self.workers.iter_mut().skip(self.initialized_workers) {
            worker.initialize(root, package, phase_count, requires_optional_builder)?;
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
            path_read_responses: worker_metrics.path_read_responses,
            can_read_requests: worker_metrics.can_read_requests,
            find_assets_requests: worker_metrics.find_assets_requests,
            find_assets_results: worker_metrics.find_assets_results,
            resolve_assets_requests: worker_metrics.resolve_assets_requests,
            resolve_assets_results: worker_metrics.resolve_assets_results,
        }
    }

    pub fn build_parallel(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Vec<u8>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
    ) -> io::Result<Vec<BuildResult>> {
        if requests.is_empty() {
            return Ok(Vec::new());
        }
        let (root, package) = match &self.initialized {
            Some((root, package, _, _, _)) => (root.clone(), package.clone()),
            None => {
                return Err(io::Error::other(
                    "worker pool must be initialized before building",
                ));
            }
        };
        let phase_count = self
            .initialized
            .as_ref()
            .map(|(_, _, _, phase_count, _)| *phase_count)
            .unwrap_or(1);

        // Serializing resolver-backed batches on one resident worker only pays
        // off while each worker's analysis state is process-local. With the
        // shared on-disk byte store, an independent AnalysisDriver reuses the
        // same cache, so homogeneous batches fan out like any other.
        if !shared_analysis_cache_enabled() {
            if let Some(key) = homogeneous_resolver_usage_key(requests) {
                match self.resolver_usage.get(&key).copied() {
                    Some(true) => {
                        self.initialize_pending_workers(&root, &package, phase_count, false)?;
                        let results = self.workers[0].build_batch(
                            workspace,
                            requests,
                            overlay,
                            deleted_overlay,
                            visibility,
                        )?;
                        self.record_resolver_usage(requests, &results);
                        return Ok(results);
                    }
                    Some(false) => {}
                    None if requests.len() > 1 && self.max_jobs > 1 => {
                        // Keep an unclassified homogeneous batch on one worker:
                        // Resolver use may depend on the input, so the first
                        // action cannot safely classify the remaining actions.
                        self.initialize_pending_workers(&root, &package, phase_count, false)?;
                        let first_results = self.workers[0].build_batch(
                            workspace,
                            &requests[..1],
                            overlay,
                            deleted_overlay,
                            visibility,
                        )?;
                        self.record_resolver_usage(&requests[..1], &first_results);

                        let mut results = first_results;
                        let remaining_results = self.workers[0].build_batch(
                            workspace,
                            &requests[1..],
                            overlay,
                            deleted_overlay,
                            visibility,
                        )?;
                        self.record_resolver_usage(&requests[1..], &remaining_results);
                        results.extend(remaining_results);
                        return Ok(results);
                    }
                    None => {}
                }
            }
        }

        self.prepare_for_requests(&root, requests.len())?;
        self.initialize_pending_workers(&root, &package, phase_count, false)?;
        // Resolver-backed batches share the on-disk byte store, so extra
        // workers mostly duplicate each other's analysis warm-up instead of
        // splitting useful work. Roughly half the pool is the measured sweet
        // spot on the reference workspace; non-resolver batches keep the full
        // pool. The pool itself is not shrunk: worker processes stay resident
        // so a smaller limit does not discard their analysis state. The floor
        // is two workers: at --jobs 2 a one-worker limit would serialize the
        // resolver phase while the second worker idles, which is strictly
        // worse than a little duplicated warm-up.
        let worker_limit = if shared_analysis_cache_enabled()
            && homogeneous_resolver_usage_key(requests)
                .map(|key| self.resolver_usage.get(&key).copied().unwrap_or(true))
                .unwrap_or(false)
        {
            match resolver_worker_cap() {
                Some(cap) => cap.clamp(1, self.max_jobs),
                None => self.max_jobs.div_ceil(2).max(2.min(self.max_jobs)),
            }
        } else {
            usize::MAX
        };
        let results = self.build_parallel_on_current_workers(
            workspace,
            requests,
            overlay,
            deleted_overlay,
            visibility,
            worker_limit,
        )?;
        self.record_resolver_usage(requests, &results);
        Ok(results)
    }

    fn build_parallel_on_current_workers(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Vec<u8>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
        worker_limit: usize,
    ) -> io::Result<Vec<BuildResult>> {
        let _wall = crate::wall::Span::new("dispatch_join");
        if requests.is_empty() {
            return Ok(Vec::new());
        }
        if self.workers.len() == 1 || worker_limit == 1 {
            return self.workers[0].build_batch(
                workspace,
                requests,
                overlay,
                deleted_overlay,
                visibility,
            );
        }

        let worker_count = self.workers.len().min(requests.len()).min(worker_limit);
        let ranges = balanced_request_ranges(requests.len(), worker_count);
        let batches = ranges
            .iter()
            .map(|(start, end)| &requests[*start..*end])
            .collect::<Vec<_>>();
        let batch_results = thread::scope(|scope| {
            let handles = self
                .workers
                .iter_mut()
                .take(worker_count)
                .zip(batches)
                .map(|(worker, batch)| {
                    scope.spawn(move || {
                        worker.build_batch(workspace, batch, overlay, deleted_overlay, visibility)
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

    fn record_resolver_usage(&mut self, requests: &[BuildRequest], results: &[BuildResult]) {
        for (request, result) in requests.iter().zip(results) {
            if result.status != "success" {
                continue;
            }
            let key = (request.builder.clone(), request.instance_key.clone());
            remember_resolver_usage(&mut self.resolver_usage, key, result.resolver_used);
        }
    }

    /// Builds a batch on one resident worker with demand-driven optional
    /// actions enabled. Serializing this path keeps the mutable overlay and
    /// recursive lazy-build stack unambiguous.
    pub fn build_parallel_lazy(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &mut BTreeMap<String, Vec<u8>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<Vec<BuildResult>> {
        if requests.is_empty() {
            return Ok(Vec::new());
        }
        self.prepare_for_requests(&workspace.root, 1)?;
        let (root, package) = match &self.initialized {
            Some((root, package, _, _, _)) => (root.clone(), package.clone()),
            None => {
                return Err(io::Error::other(
                    "worker pool must be initialized before building",
                ));
            }
        };
        let phase_count = self
            .initialized
            .as_ref()
            .map(|(_, _, _, phase_count, _)| *phase_count)
            .unwrap_or(1);
        self.initialize_pending_workers(&root, &package, phase_count, true)?;
        self.workers[0].build_batch_lazy(
            workspace,
            requests,
            overlay,
            deleted_overlay,
            visibility,
            lazy_specs,
            lazy,
        )
    }

    pub fn reset_resolver(
        &mut self,
        root: &Path,
        overlay: &BTreeMap<String, Vec<u8>>,
        updated_sources: BTreeSet<String>,
        deleted_sources: BTreeSet<String>,
        updated_cache: BTreeSet<String>,
        deleted_cache: BTreeSet<String>,
        incremental: bool,
    ) -> io::Result<()> {
        let _wall = crate::wall::Span::new("pool_resolver_reset");
        let count = self.initialized_workers.min(self.workers.len());
        if count == 0 {
            return Ok(());
        }
        // Each worker serves updated contents from the outputs it produced
        // itself. With multiple workers, updated assets may come from another
        // producer, so spool them under the workspace overlay directory where
        // any worker can read them during its reset.
        if count > 1 {
            let spool_root = root.join(OVERLAY_SPOOL_DIR);
            for asset in updated_sources.iter().chain(updated_cache.iter()) {
                let spool_path = spool_root.join(asset.replacen('|', "/", 1));
                let Some(bytes) = overlay.get(asset) else {
                    // Do not let a leftover file from an earlier build be
                    // mistaken for the current overlay value.
                    let _ = fs::remove_file(&spool_path);
                    continue;
                };
                if let Some(parent) = spool_path.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::write(&spool_path, bytes)?;
            }
            for asset in deleted_sources.iter().chain(deleted_cache.iter()) {
                let _ = fs::remove_file(spool_root.join(asset.replacen('|', "/", 1)));
            }
        } else {
            // A previous multi-worker build may have left files for these
            // assets. A single worker serves its current outputs from memory,
            // so discard stale spool files before it receives the reset.
            let spool_root = root.join(OVERLAY_SPOOL_DIR);
            for asset in updated_sources
                .iter()
                .chain(deleted_sources.iter())
                .chain(updated_cache.iter())
                .chain(deleted_cache.iter())
            {
                let _ = fs::remove_file(spool_root.join(asset.replacen('|', "/", 1)));
            }
        }
        let updated = json!(updated_sources);
        let deleted = json!(deleted_sources);
        let updated_cache = json!(updated_cache);
        let deleted_cache = json!(deleted_cache);
        if count == 1 {
            self.workers[0].reset_resolver(
                &updated,
                &deleted,
                &updated_cache,
                &deleted_cache,
                incremental,
            )?;
        } else {
            // Workers reset their resolver independently; waiting on them one
            // at a time would make every phase boundary cost count × reset.
            thread::scope(|scope| {
                let handles = self
                    .workers
                    .iter_mut()
                    .take(count)
                    .map(|worker| {
                        let updated = &updated;
                        let deleted = &deleted;
                        let updated_cache = &updated_cache;
                        let deleted_cache = &deleted_cache;
                        scope.spawn(move || {
                            worker.reset_resolver(
                                updated,
                                deleted,
                                updated_cache,
                                deleted_cache,
                                incremental,
                            )
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
        }
        self.resolver_resets += count as u64;
        Ok(())
    }
}

pub(super) fn homogeneous_resolver_usage_key(
    requests: &[BuildRequest],
) -> Option<(String, String)> {
    let first = requests.first()?;
    if first.post_process {
        return None;
    }
    let key = (first.builder.clone(), first.instance_key.clone());
    requests
        .iter()
        .all(|request| {
            !request.post_process
                && request.builder == key.0
                && request.instance_key == key.1
        })
        .then_some(key)
}

pub(super) fn remember_resolver_usage(
    resolver_usage: &mut BTreeMap<(String, String), bool>,
    key: (String, String),
    used: bool,
) {
    resolver_usage
        .entry(key)
        .and_modify(|previous| *previous |= used)
        .or_insert(used);
}

/// Whether workers share the on-disk analyzer byte store. The Dart worker
/// reads the same variable for its driver setup; keep the disabled values in
/// sync with `lib/src/worker_resolvers.dart`.
pub(crate) fn shared_analysis_cache_enabled() -> bool {
    match std::env::var("BUILD_RUNNER_ACCELERATOR_BYTE_STORE") {
        Ok(value) => !matches!(value.to_lowercase().as_str(), "0" | "false" | "off"),
        Err(_) => true,
    }
}

/// `BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP` overrides how many workers may
/// join a resolver-backed batch: `1..=n` clamps the participants, `0` lifts
/// the cap entirely (every worker joins). Unset keeps the `max(jobs/2, 2)`
/// default. This exists to measure how per-worker analysis warm-up trades
/// against intra-builder parallelism on machines of different sizes.
fn resolver_worker_cap() -> Option<usize> {
    let value = env::var("BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP").ok()?;
    match value.parse::<usize>() {
        Ok(0) => Some(usize::MAX),
        Ok(cap) => Some(cap),
        Err(_) => {
            eprintln!(
                "BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP must be an integer; ignoring {value}"
            );
            None
        }
    }
}

pub(super) fn target_worker_count(max_jobs: usize, request_count: usize) -> usize {
    max_jobs.max(1).min(request_count.max(1))
}

pub(super) fn balanced_request_ranges(
    request_count: usize,
    worker_count: usize,
) -> Vec<(usize, usize)> {
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

impl Drop for WorkerPool {
    fn drop(&mut self) {
        self.workers.clear();
    }
}
