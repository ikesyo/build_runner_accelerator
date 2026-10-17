use super::client::{WorkerClient, WorkerClientMetrics};
use super::lazy::{FilteredDemandCoordinator, LazyBuildState};
use super::request::BuildRequest;
use crate::plan::BuildSpec;
use crate::protocol::BuildResult;
use crate::visibility::AssetVisibility;
use crate::worker_kernel::{
    WorkerArtifact, background_worker_aot_if_ready, pinned_worker_artifact_is_current,
    resolve_worker_artifact,
};
use crate::workspace::Workspace;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

/// Owns resident Dart processes and their initialization/analysis state for a
/// native build or watch session. Workers are kept alive when a later phase
/// needs fewer of them; restart occurs only when the artifact or initialization
/// signature changes, and dropping the pool kills and waits for every child.
pub struct WorkerPool {
    workers: Vec<WorkerClient>,
    dart_binary: String,
    worker_executable: String,
    worker_artifact: Option<WorkerArtifact>,
    auto_worker_artifact: bool,
    allow_worker_artifact_upgrade: bool,
    max_jobs: usize,
    initialized: Option<(PathBuf, String, String, usize, bool, bool)>,
    retained_output_guard: bool,
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
        Self::start_with_initial_worker(
            root,
            dart_binary,
            worker_executable,
            jobs,
            auto_worker_artifact,
            true,
        )
    }

    /// Creates a pool descriptor without starting a Dart process. Filtered
    /// watch uses this so an initial no-op can avoid worker startup entirely.
    pub fn start_deferred(
        root: &Path,
        dart_binary: &str,
        worker_executable: &str,
        jobs: usize,
        auto_worker_artifact: bool,
    ) -> io::Result<Self> {
        Self::start_with_initial_worker(
            root,
            dart_binary,
            worker_executable,
            jobs,
            auto_worker_artifact,
            false,
        )
    }

    fn start_with_initial_worker(
        root: &Path,
        dart_binary: &str,
        worker_executable: &str,
        jobs: usize,
        auto_worker_artifact: bool,
        start_worker: bool,
    ) -> io::Result<Self> {
        let _wall = crate::wall::Span::new("pool_start");
        let dart_binary = dart_binary.to_owned();
        let worker_executable = worker_executable.to_owned();
        let worker_artifact = if start_worker {
            Some(resolve_worker_artifact(
                root,
                &dart_binary,
                &worker_executable,
                auto_worker_artifact,
            )?)
        } else {
            None
        };
        let max_jobs = jobs.max(1);
        // Keep the initial pool small. Additional workers are started only when
        // a phase actually has enough independent actions to use them.
        let workers = if start_worker {
            vec![WorkerClient::start(
                root,
                &dart_binary,
                &worker_executable,
                worker_artifact
                    .as_ref()
                    .expect("eager pool resolves its worker artifact"),
            )?]
        } else {
            Vec::new()
        };
        let worker_starts = workers.len() as u64;
        Ok(Self {
            workers,
            dart_binary,
            worker_executable,
            worker_artifact,
            auto_worker_artifact,
            allow_worker_artifact_upgrade: true,
            max_jobs,
            initialized: None,
            retained_output_guard: false,
            initialized_workers: 0,
            resolver_usage: BTreeMap::new(),
            retired_metrics: WorkerClientMetrics::default(),
            worker_starts,
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

    pub(crate) fn set_retained_output_guard(&mut self, enabled: bool) {
        self.retained_output_guard = enabled;
    }

    /// Reuses workers only for an identical workspace/configuration signature.
    /// A changed signature clears resolver-use hints and restarts the resident
    /// processes; each newly admitted process must pass worker IPC checks.
    pub fn initialize(
        &mut self,
        root: &Path,
        package: &str,
        config_digest: &str,
        phase_count: usize,
        requires_optional_builder: bool,
    ) -> io::Result<()> {
        // Deferred filtered-watch pools materialize only when a build actually
        // reaches worker initialization. Ordinary callers retain eager start.
        if self.workers.is_empty() {
            self.prepare_for_requests(root, 1)?;
        }
        let signature = (
            root.to_path_buf(),
            package.to_owned(),
            config_digest.to_owned(),
            phase_count,
            requires_optional_builder,
            self.retained_output_guard,
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
                        if self.worker_artifact.as_ref() != Some(&artifact) {
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
            self.initialize_pending_workers(root, package, phase_count, requires_optional_builder)?;
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
                self.worker_artifact
                    .as_ref()
                    .expect("initialized pool has a worker artifact"),
            )
            .unwrap_or_else(|error| {
                eprintln!(
                    "Rust pinned worker artifact could not be validated; resolving it again ({error})"
                );
                false
            }) {
                self.worker_artifact
                    .as_ref()
                    .expect("initialized pool has a worker artifact")
                    .clone()
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
        self.initialize_pending_workers(root, package, phase_count, requires_optional_builder)?;
        self.initialized = Some(signature);
        Ok(())
    }

    /// Replaces the resident process set while preserving its current width.
    /// Old worker metrics are collected before their children are dropped.
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
        self.worker_artifact = Some(worker_artifact);
        self.initialized_workers = 0;
        Ok(())
    }

    /// Expands to at most `min(max_jobs, request_count)` workers and never
    /// shrinks a resident pool during ordinary request preparation.
    pub fn prepare_for_requests(&mut self, root: &Path, request_count: usize) -> io::Result<()> {
        let _wall = crate::wall::Span::new("pool_expand");
        let target = target_worker_count(self.max_jobs, request_count);
        if target > self.workers.len() && self.worker_artifact.is_none() {
            self.worker_artifact = Some(resolve_worker_artifact(
                root,
                &self.dart_binary,
                &self.worker_executable,
                self.auto_worker_artifact,
            )?);
        }
        let Some(worker_artifact) = self.worker_artifact.as_ref() else {
            return Ok(());
        };
        // Never shrink the pool here: an idle worker that is retired now has to
        // be restarted and re-initialized by the next wider phase, which costs
        // far more than keeping it resident. Retirement only happens on a full
        // restart (artifact upgrade or signature change).
        while self.workers.len() < target {
            self.workers.push(WorkerClient::start(
                root,
                &self.dart_binary,
                &self.worker_executable,
                worker_artifact,
            )?);
            self.worker_starts += 1;
        }
        Ok(())
    }

    /// Chooses the number of filtered root workers from shared-store evidence.
    /// Without the shared Analyzer byte store, roots stay on one process because
    /// resolver state may otherwise be process-local.
    pub(crate) fn prepare_for_filtered_roots(
        &mut self,
        root: &Path,
        root_count: usize,
    ) -> io::Result<()> {
        // When the shared analyzer byte store is disabled, a resolver may
        // retain process-local state. Unknown filtered roots therefore stay
        // on one worker; with the shared store, each worker can resolve from
        // the transaction's reset overlay and on-demand producer RPCs.
        let request_count = if shared_analysis_cache_enabled() {
            root_count
        } else {
            root_count.min(1)
        };
        self.prepare_for_requests(root, request_count)
    }

    /// Initializes only workers added since the last pool initialization.
    /// The worker protocol and any requested optional-demand capability are
    /// checked before the caller dispatches actions to those processes.
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
            worker.initialize(
                root,
                package,
                phase_count,
                requires_optional_builder,
                self.retained_output_guard,
            )?;
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

    /// Dispatches one same-phase request set and returns results in request
    /// order. Resolver-worker limits use prior successful reports when the
    /// shared byte store is enabled; without it, an unclassified homogeneous
    /// batch starts on one worker before the pool trusts any resolver-use hint.
    pub fn build_parallel(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &BTreeSet<String>,
        visibility: &AssetVisibility,
    ) -> io::Result<Vec<BuildResult>> {
        if requests.is_empty() {
            return Ok(Vec::new());
        }
        let (root, package) = match &self.initialized {
            Some((root, package, _, _, _, _)) => (root.clone(), package.clone()),
            None => {
                return Err(io::Error::other(
                    "worker pool must be initialized before building",
                ));
            }
        };
        let phase_count = self
            .initialized
            .as_ref()
            .map(|(_, _, _, phase_count, _, _)| *phase_count)
            .unwrap_or(1);

        // Serializing resolver-backed batches on one resident worker only pays
        // off while each worker's analysis state is process-local. With the
        // shared on-disk byte store, an independent AnalysisDriver reuses the
        // same cache, so homogeneous batches fan out like any other.
        if !shared_analysis_cache_enabled()
            && let Some(key) = homogeneous_resolver_usage_key(requests)
        {
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

    /// Splits requests into contiguous balanced ranges, joins every dispatched
    /// worker, and combines results in range order. Worker errors and panics
    /// return an error; callers must not commit any staged output on that path.
    fn build_parallel_on_current_workers(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &BTreeMap<String, Arc<[u8]>>,
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

    /// Records only successful results; a later `resolver_used = true` keeps
    /// the instance classified as resolver-backed for the rest of this session.
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
    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    /// Runs demand-enabled actions on one worker so nested asset RPCs share a
    /// single mutable overlay and recursive request stack. Any nested demand
    /// failure returns to the transaction owner, which must abort publication.
    pub fn build_parallel_lazy(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
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
            Some((root, package, _, _, _, _)) => (root.clone(), package.clone()),
            None => {
                return Err(io::Error::other(
                    "worker pool must be initialized before building",
                ));
            }
        };
        let phase_count = self
            .initialized
            .as_ref()
            .map(|(_, _, _, phase_count, _, _)| *phase_count)
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

    #[expect(
        clippy::too_many_arguments,
        reason = "Demand execution shares transaction and visibility state with nested IPC"
    )]
    /// Runs independent filtered roots across workers while a shared coordinator
    /// claims each action once and publishes its complete sibling set to peers.
    /// Each worker keeps its own nested RPC stack and starts from a copy of the
    /// transaction overlay. On any latched failure all workers are joined and
    /// the error propagates; staged memory may have changed, so the caller must
    /// discard the transaction instead of calling filesystem commit.
    pub(crate) fn build_filtered(
        &mut self,
        workspace: &Workspace,
        roots: &[String],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        if roots.is_empty() {
            return Ok(());
        }
        self.prepare_for_filtered_roots(&workspace.root, roots.len())?;
        let (root, package, _, phase_count, _, _) = self
            .initialized
            .clone()
            .ok_or_else(|| io::Error::other("worker pool must be initialized"))?;
        self.initialize_pending_workers(&root, &package, phase_count, true)?;
        let worker_count = self.workers.len().min(if shared_analysis_cache_enabled() {
            roots.len()
        } else {
            roots.len().min(1)
        });
        let coordinator = FilteredDemandCoordinator::default();
        let next_root = AtomicUsize::new(0);
        let initial_overlay = overlay.clone();
        let initial_deleted = deleted_overlay.clone();
        let worker_states = (0..worker_count)
            .map(|index| lazy.worker_state(index, coordinator.clone()))
            .collect::<Vec<_>>();

        let outcomes = thread::scope(|scope| {
            let mut worker_states = worker_states.into_iter();
            let handles = self
                .workers
                .iter_mut()
                .take(worker_count)
                .map(|worker| {
                    let mut worker_lazy = worker_states
                        .next()
                        .expect("worker state count matches worker count");
                    let mut worker_overlay = initial_overlay.clone();
                    let mut worker_deleted = initial_deleted.clone();
                    let coordinator = coordinator.clone();
                    let next_root = &next_root;
                    scope.spawn(move || {
                        let result = (|| {
                            loop {
                                if let Some(error) = coordinator.failure() {
                                    return Err(io::Error::other(error));
                                }
                                let index = next_root.fetch_add(1, Ordering::Relaxed);
                                let Some(output) = roots.get(index) else {
                                    break;
                                };
                                if let Err(error) = worker.ensure_optional_output(
                                    workspace,
                                    output,
                                    &mut worker_overlay,
                                    &mut worker_deleted,
                                    visibility,
                                    u32::MAX,
                                    crate::builder::BuilderKind::Normal,
                                    specs,
                                    &mut worker_lazy,
                                ) {
                                    coordinator.fail_worker(error.to_string());
                                    return Err(error);
                                }
                                if let Some(error) = worker_lazy.failed_demand() {
                                    coordinator.fail_worker(error.to_owned());
                                    return Err(io::Error::other(format!(
                                        "filtered dependency build failed: {error}"
                                    )));
                                }
                            }
                            Ok(())
                        })();
                        if result.is_err() {
                            coordinator.fail_worker("filtered worker failed".to_owned());
                        }
                        (result, worker_lazy)
                    })
                })
                .collect::<Vec<_>>();

            let mut outcomes = Vec::with_capacity(handles.len());
            let mut first_error = None;
            for handle in handles {
                match handle.join() {
                    Ok((result, worker_lazy)) => {
                        if let Err(error) = result {
                            first_error.get_or_insert(error);
                        }
                        outcomes.push(worker_lazy);
                    }
                    Err(_) => {
                        coordinator.fail_worker("filtered worker thread panicked".to_owned());
                        first_error.get_or_insert_with(|| {
                            io::Error::other("filtered worker thread panicked")
                        });
                    }
                }
            }
            (outcomes, first_error)
        });

        for worker_state in outcomes.0 {
            lazy.merge_worker_state(worker_state);
        }
        coordinator.apply_outputs(overlay, deleted_overlay);
        if let Some(error) = outcomes.1 {
            return Err(error);
        }
        if let Some(error) = coordinator.failure() {
            return Err(io::Error::other(format!(
                "filtered dependency build failed: {error}"
            )));
        }
        if let Some(error) = lazy.failed_demand() {
            return Err(io::Error::other(format!(
                "filtered dependency build failed: {error}"
            )));
        }
        Ok(())
    }

    /// Applies one phase's source/cache delta to every initialized resolver and
    /// joins all reset replies before releasing the shared blob. A single worker
    /// uses memory after validating every updated ID; multi-worker data is held
    /// until all RPCs finish. Any validation, write, RPC, or join error aborts
    /// the caller's build even if some worker already reset successfully.
    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub fn reset_resolver(
        &mut self,
        root: &Path,
        overlay: &BTreeMap<String, Arc<[u8]>>,
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
        if count == 1 {
            validate_memory_overlay(overlay, &updated_sources, &updated_cache)?;
        }
        let spool = crate::wall::Span::new("reset_overlay_spool");
        let blob = if count > 1 {
            let updated_assets = updated_sources.union(&updated_cache).cloned().collect();
            Some(super::overlay_blob::OverlayBlob::create(
                root,
                overlay,
                &updated_assets,
            )?)
        } else {
            None
        };
        // null means single-worker memory transport; legacy spool is never read.
        let blob_metadata = blob
            .as_ref()
            .map(|blob| &blob.metadata)
            .unwrap_or(&serde_json::Value::Null);
        drop(spool);
        let delta = crate::wall::Span::new("reset_delta_encode");
        let updated = json!(updated_sources);
        let deleted = json!(deleted_sources);
        let updated_cache = json!(updated_cache);
        let deleted_cache = json!(deleted_cache);
        drop(delta);
        if count == 1 {
            self.workers[0].reset_resolver(
                &updated,
                &deleted,
                &updated_cache,
                &deleted_cache,
                incremental,
                blob_metadata,
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
                                blob_metadata,
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

/// Null transport is safe only when every updated value belongs to the
/// current overlay; otherwise a worker could retain an older produced value.
pub(super) fn validate_memory_overlay(
    overlay: &BTreeMap<String, Arc<[u8]>>,
    updated_sources: &BTreeSet<String>,
    updated_cache: &BTreeSet<String>,
) -> io::Result<()> {
    for asset in updated_sources.iter().chain(updated_cache) {
        if !overlay.contains_key(asset) {
            return Err(io::Error::other(format!(
                "single-worker reset missing overlay value for updated asset: {asset}"
            )));
        }
    }
    Ok(())
}

/// Returns an instance key only when every request is the same normal builder
/// instance; mixed or post-process requests cannot share resolver-use evidence.
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
            !request.post_process && request.builder == key.0 && request.instance_key == key.1
        })
        .then_some(key)
}

/// Merges successful observations monotonically: one resolver-backed input is
/// enough to classify the builder instance as resolver-backed for this session.
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
            eprintln!("BUILD_RUNNER_ACCELERATOR_RESOLVER_CAP must be an integer; ignoring {value}");
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
