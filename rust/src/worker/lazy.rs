use super::WorkerClient;
use super::asset_rpc::{
    FilteredAssetEvidence, batch_asset_request_context, validate_asset_request_context,
};
use super::client::protocol_error;
use super::request::{BuildRequest, batch_blocked_assets, build_request_kind};
use crate::builder::BuilderKind;
use crate::plan::BuildSpec;
use crate::protocol::{
    BuildResult, IncomingFrame, decode_build_batch_result_frame, decode_build_result_frame,
};
use crate::visibility::AssetVisibility;
use crate::workspace::{Workspace, glob_candidates, matches_glob};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Instant;

#[expect(
    clippy::too_many_arguments,
    reason = "Glob results use the same phase-aware transaction view as asset RPC"
)]
fn filtered_glob_members(
    workspace: &Workspace,
    package: &str,
    pattern: &str,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    deleted: &BTreeSet<String>,
    visibility: &AssetVisibility,
    phase: u32,
    kind: BuilderKind,
    specs: &BTreeMap<String, BuildSpec>,
) -> io::Result<Vec<String>> {
    let mut candidates: BTreeSet<String> = workspace
        .find_assets(package, pattern)?
        .into_iter()
        .collect();
    candidates.extend(visibility.generated_assets(package, pattern).cloned());
    candidates.extend(
        glob_candidates(overlay, package, pattern)
            .filter(|asset| {
                asset
                    .split_once('|')
                    .is_some_and(|(pkg, path)| pkg == package && matches_glob(pattern, path))
            })
            .cloned(),
    );
    let mut sources = Vec::new();
    let mut generated = Vec::new();
    for asset in candidates {
        if visibility.is_hidden(&asset, phase, kind, deleted) {
            continue;
        }
        if !overlay.contains_key(&asset)
            && !workspace.asset_exists_at(
                &asset,
                visibility
                    .location(&asset)
                    .unwrap_or(crate::builder::BuildTo::Source),
            )?
        {
            continue;
        }
        if specs.contains_key(&asset) {
            generated.push(asset);
        } else {
            sources.push(asset);
        }
    }
    // AssetId.compareTo uses Dart String ordering (UTF-16 code units).
    sources.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    generated.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    sources.extend(generated);
    Ok(sources)
}

/// A successful optional action that was requested while another action was
/// suspended in the resident Dart worker. The build frontend commits these
/// results together with the outer transaction.
pub struct LazyBuildResult {
    pub spec: BuildSpec,
    pub result: BuildResult,
}

#[derive(Clone)]
enum PublishedOutput {
    Bytes(Arc<[u8]>),
    Missing,
    OnDisk,
}

#[derive(Clone)]
pub(crate) enum FilteredSourceContent {
    Bytes(Arc<[u8]>),
    Spool(Arc<FilteredSourceSpool>),
    Missing,
}

#[derive(Clone)]
pub(crate) struct FilteredSourceObservation {
    pub(crate) content: FilteredSourceContent,
    pub(crate) snapshot: crate::snapshot::AssetSnapshot,
}

/// Keeps a large filtered-source snapshot available to the worker by path.
/// Dropping the guard removes the temporary file during normal cleanup; an
/// abrupt process exit can leave an orphan in the temporary directory.
pub(crate) struct FilteredSourceSpool {
    path: PathBuf,
}

impl FilteredSourceSpool {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub(crate) fn path(&self) -> &std::path::Path {
        &self.path
    }
}

impl Drop for FilteredSourceSpool {
    fn drop(&mut self) {
        // Best-effort lifecycle cleanup; crash-orphan reclamation is outside
        // this guard's scope.
        let _ = std::fs::remove_file(&self.path);
    }
}

#[derive(Clone, Default)]
struct ActionPublication {
    outputs: BTreeMap<String, PublishedOutput>,
    snapshots: BTreeMap<String, crate::snapshot::AssetSnapshot>,
}

#[derive(Clone)]
enum DemandActionState {
    Running { worker: usize },
    Complete(ActionPublication),
    Failed(String),
}

#[derive(Default)]
struct DemandCoordinatorState {
    actions: HashMap<String, DemandActionState>,
    dependencies: HashMap<String, String>,
    published_outputs: BTreeMap<String, PublishedOutput>,
    // Stock's filesystem content cache stabilizes external source bytes across
    // build steps in one transaction. Share the first unknown-source
    // observation across native workers to preserve that behavior.
    source_observations: BTreeMap<String, FilteredSourceObservation>,
    failed: Option<String>,
}

#[derive(Default)]
struct DemandCoordinatorInner {
    state: Mutex<DemandCoordinatorState>,
    changed: Condvar,
}

/// Coordinates filtered actions across worker RPC stacks. The lock protects
/// only claims and immutable completion publications; no worker IPC or file
/// access is performed while it is held.
#[derive(Clone, Default)]
pub(crate) struct FilteredDemandCoordinator {
    inner: Arc<DemandCoordinatorInner>,
}

enum DemandClaim {
    Owner(ActionClaimGuard),
    Complete(ActionPublication),
}

struct ActionClaimGuard {
    coordinator: FilteredDemandCoordinator,
    key: String,
    parent: Option<String>,
    worker: usize,
    settled: bool,
}

impl ActionClaimGuard {
    fn complete(&mut self, publication: ActionPublication) {
        let mut state = self.coordinator.lock();
        state.published_outputs.extend(
            publication
                .outputs
                .iter()
                .map(|(asset, output)| (asset.clone(), output.clone())),
        );
        state
            .actions
            .insert(self.key.clone(), DemandActionState::Complete(publication));
        if let Some(parent) = &self.parent
            && state.dependencies.get(parent) == Some(&self.key)
        {
            state.dependencies.remove(parent);
        }
        state.dependencies.remove(&self.key);
        self.settled = true;
        self.coordinator.inner.changed.notify_all();
    }

    fn fail(&mut self, error: impl Into<String>) {
        self.coordinator
            .fail_action(&self.key, self.parent.as_deref(), self.worker, error.into());
        self.settled = true;
    }
}

impl Drop for ActionClaimGuard {
    fn drop(&mut self) {
        if !self.settled {
            self.coordinator.fail_action(
                &self.key,
                self.parent.as_deref(),
                self.worker,
                "filtered demand owner exited without publishing a result".to_owned(),
            );
        }
    }
}

impl FilteredDemandCoordinator {
    fn lock(&self) -> MutexGuard<'_, DemandCoordinatorState> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn claim(&self, key: &str, parent: Option<&str>, worker: usize) -> io::Result<DemandClaim> {
        let mut state = self.lock();
        loop {
            if let Some(error) = &state.failed {
                return Err(io::Error::other(error.clone()));
            }
            match state.actions.get(key).cloned() {
                Some(DemandActionState::Complete(publication)) => {
                    return Ok(DemandClaim::Complete(publication));
                }
                Some(DemandActionState::Failed(error)) => {
                    return Err(io::Error::other(error.clone()));
                }
                Some(DemandActionState::Running { worker: _owner }) => {
                    if let Some(parent) = parent {
                        state.dependencies.insert(parent.to_owned(), key.to_owned());
                        let mut next = key;
                        let mut visited = BTreeSet::new();
                        while let Some(waiting_on) = state.dependencies.get(next) {
                            if waiting_on == parent {
                                let error = format!(
                                    "filtered dependency wait cycle: {parent} waits for {key}"
                                );
                                latch_demand_failure(&mut state, error.clone());
                                self.inner.changed.notify_all();
                                state.dependencies.remove(parent);
                                return Err(io::Error::other(error));
                            }
                            if !visited.insert(waiting_on.clone()) {
                                break;
                            }
                            next = waiting_on;
                        }
                    }
                    // Do not retain the shared lock while sleeping. Producers
                    // publish and wake all waiters after the entire sibling set.
                    state = self
                        .inner
                        .changed
                        .wait(state)
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    if let Some(parent) = parent {
                        state.dependencies.remove(parent);
                    }
                }
                None => {
                    if let Some(parent) = parent {
                        state.dependencies.insert(parent.to_owned(), key.to_owned());
                    }
                    state
                        .actions
                        .insert(key.to_owned(), DemandActionState::Running { worker });
                    return Ok(DemandClaim::Owner(ActionClaimGuard {
                        coordinator: self.clone(),
                        key: key.to_owned(),
                        parent: parent.map(str::to_owned),
                        worker,
                        settled: false,
                    }));
                }
            }
        }
    }

    fn source_observation(&self, asset: &str) -> Option<FilteredSourceObservation> {
        self.lock().source_observations.get(asset).cloned()
    }

    fn publish_source_observation(
        &self,
        asset: &str,
        observed: FilteredSourceObservation,
    ) -> FilteredSourceObservation {
        let published = {
            let mut state = self.lock();
            state
                .source_observations
                .entry(asset.to_owned())
                .or_insert_with(|| observed.clone())
                .clone()
        };
        // A losing spool candidate may unlink its temporary file on drop.
        // Keep the original outside the guard so that cleanup never performs
        // filesystem I/O while holding the coordinator mutex.
        published
    }

    fn fail_action(&self, key: &str, parent: Option<&str>, worker: usize, error: String) {
        let mut state = self.lock();
        if matches!(
            state.actions.get(key),
            Some(DemandActionState::Running { worker: owner }) if *owner == worker
        ) {
            state
                .actions
                .insert(key.to_owned(), DemandActionState::Failed(error.clone()));
        }
        if let Some(parent) = parent
            && state
                .dependencies
                .get(parent)
                .is_some_and(|child| child == key)
        {
            state.dependencies.remove(parent);
        }
        state.dependencies.remove(key);
        latch_demand_failure(&mut state, error);
        self.inner.changed.notify_all();
    }

    pub(crate) fn fail_worker(&self, error: impl Into<String>) {
        let mut state = self.lock();
        latch_demand_failure(&mut state, error.into());
        self.inner.changed.notify_all();
    }

    pub(crate) fn failure(&self) -> Option<String> {
        self.lock().failed.clone()
    }

    pub(crate) fn apply_outputs(
        &self,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted: &mut BTreeSet<String>,
    ) {
        for (asset, output) in &self.lock().published_outputs {
            apply_published_output(asset, output, overlay, deleted);
        }
    }
}

fn latch_demand_failure(state: &mut DemandCoordinatorState, error: String) {
    state.failed.get_or_insert(error);
}

fn apply_published_output(
    asset: &str,
    output: &PublishedOutput,
    overlay: &mut BTreeMap<String, Arc<[u8]>>,
    deleted: &mut BTreeSet<String>,
) {
    match output {
        PublishedOutput::Bytes(bytes) => {
            overlay.insert(asset.to_owned(), Arc::clone(bytes));
            deleted.remove(asset);
        }
        PublishedOutput::Missing => {
            overlay.remove(asset);
            deleted.insert(asset.to_owned());
        }
        PublishedOutput::OnDisk => {
            overlay.remove(asset);
            deleted.remove(asset);
        }
    }
}

/// State shared by optional builds and filtered normal demand in one transaction.
/// Filtered demand workers share immutable action publications and retain
/// worker-local RPC stacks and mutable transaction views.
pub struct LazyBuildState {
    force_keys: BTreeSet<String>,
    built_keys: BTreeSet<String>,
    building_keys: BTreeSet<String>,
    building_stack: Vec<String>,
    results: Vec<LazyBuildResult>,
    failed_demand: Option<String>,
    filtered_previous: Option<Arc<crate::graph::GraphState>>,
    demanded_keys: BTreeSet<String>,
    filtered_snapshot: Arc<crate::snapshot::Snapshot>,
    filtered_snapshot_delta: BTreeMap<String, crate::snapshot::AssetSnapshot>,
    filtered_unconfirmed_outputs: BTreeSet<String>,
    filtered_dirty_keys: BTreeSet<String>,
    filtered_probe_root_dirty: bool,
    filtered_compatible: bool,
    pub(crate) keep_modified_outputs: bool,
    filtered_coordinator: Option<FilteredDemandCoordinator>,
    filtered_worker: usize,
}

enum FilteredExecution<'a> {
    Worker(&'a mut WorkerClient),
    Probe,
}

impl LazyBuildState {
    /// Whether an ordinary optional action is invalidated but has no result
    /// from a normal consumer in this transaction.
    pub(crate) fn is_undemanded(&self, spec: &BuildSpec) -> bool {
        let key = spec.action_key();
        self.force_keys.contains(&key) && !self.built_keys.contains(&key)
    }

    /// Whether this transaction has evaluated the optional action, including
    /// a successful result with no outputs.
    pub(crate) fn has_built(&self, spec: &BuildSpec) -> bool {
        self.built_keys.contains(&spec.action_key())
    }

    pub fn new(force_keys: BTreeSet<String>) -> Self {
        Self {
            force_keys,
            built_keys: BTreeSet::new(),
            building_keys: BTreeSet::new(),
            building_stack: Vec::new(),
            results: Vec::new(),
            failed_demand: None,
            filtered_previous: None,
            demanded_keys: BTreeSet::new(),
            filtered_snapshot: Arc::new(BTreeMap::new()),
            filtered_snapshot_delta: BTreeMap::new(),
            filtered_unconfirmed_outputs: BTreeSet::new(),
            filtered_dirty_keys: BTreeSet::new(),
            filtered_probe_root_dirty: false,
            filtered_compatible: false,
            keep_modified_outputs: false,
            filtered_coordinator: None,
            filtered_worker: 0,
        }
    }

    pub(crate) fn filtered(
        previous: crate::graph::GraphState,
        current: crate::snapshot::Snapshot,
        compatible: bool,
    ) -> Self {
        let mut state = Self::new(BTreeSet::new());
        state.filtered_previous = Some(Arc::new(previous));
        state.filtered_snapshot = Arc::new(current);
        state.filtered_compatible = compatible;
        state
    }

    fn asset_changed(&self, asset: &str) -> bool {
        if self.filtered_unconfirmed_outputs.contains(asset) {
            return true;
        }
        let current = self
            .filtered_snapshot_delta
            .get(asset)
            .or_else(|| self.filtered_snapshot.get(asset));
        let previous = self
            .filtered_previous
            .as_ref()
            .and_then(|s| s.assets.get(asset));
        match (previous, current) {
            (Some(previous), Some(current)) => {
                previous.exists != current.exists || previous.digest != current.digest
            }
            (None, None) => false,
            _ => true,
        }
    }

    pub(super) fn is_untracked_filtered_source(
        &self,
        asset: &str,
        lazy_specs: &BTreeMap<String, BuildSpec>,
    ) -> bool {
        if self.filtered_previous.is_none() || self.filtered_snapshot.contains_key(asset) {
            return false;
        }
        if lazy_specs.contains_key(asset) {
            return false;
        }
        let Some(previous) = &self.filtered_previous else {
            return false;
        };
        !previous.output_locations.contains_key(asset)
            && !previous.watch_generated_sources.contains(asset)
            && !previous
                .actions
                .values()
                .any(|action| action.outputs.iter().any(|output| output == asset))
    }

    pub(super) fn shared_source_observation(
        &self,
        asset: &str,
    ) -> Option<FilteredSourceObservation> {
        self.filtered_coordinator
            .as_ref()?
            .source_observation(asset)
    }

    pub(super) fn publish_source_observation(
        &mut self,
        asset: &str,
        observed: FilteredSourceObservation,
    ) -> FilteredSourceObservation {
        let published = if let Some(coordinator) = &self.filtered_coordinator {
            coordinator.publish_source_observation(asset, observed)
        } else {
            observed
        };
        self.filtered_snapshot_delta
            .insert(asset.to_owned(), published.snapshot.clone());
        published
    }

    pub(crate) fn filtered_snapshot_delta(
        &self,
    ) -> &BTreeMap<String, crate::snapshot::AssetSnapshot> {
        &self.filtered_snapshot_delta
    }

    fn update_outputs(
        &mut self,
        spec: &BuildSpec,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
    ) {
        if self.filtered_previous.is_none() {
            return;
        }
        for output in &spec.outputs {
            self.filtered_unconfirmed_outputs.remove(output);
            let entry = if let Some(bytes) = overlay.get(output) {
                Some(crate::snapshot::AssetSnapshot {
                    exists: true,
                    digest: crate::digest::digest_bytes(bytes),
                    size: bytes.len() as u64,
                })
            } else if deleted.contains(output) {
                Some(crate::snapshot::AssetSnapshot {
                    exists: false,
                    digest: crate::digest::digest_bytes(b"<missing>"),
                    size: 0,
                })
            } else {
                None
            };
            if let Some(entry) = entry {
                self.filtered_snapshot_delta.insert(output.clone(), entry);
            }
        }
    }

    pub(crate) fn worker_state(
        &self,
        worker: usize,
        coordinator: FilteredDemandCoordinator,
    ) -> Self {
        Self {
            force_keys: self.force_keys.clone(),
            // The single-threaded probe already completed every reused action
            // and left its transaction view in the overlays passed to workers.
            // Seed those claims so parallel roots do not replay reuse work.
            built_keys: self.built_keys.clone(),
            building_keys: BTreeSet::new(),
            building_stack: Vec::new(),
            results: Vec::new(),
            failed_demand: None,
            filtered_previous: self.filtered_previous.clone(),
            demanded_keys: self.demanded_keys.clone(),
            filtered_snapshot: self.filtered_snapshot.clone(),
            filtered_snapshot_delta: self.filtered_snapshot_delta.clone(),
            // Probe-only dirtiness is resolved again by actual worker reads;
            // carrying it into execution would invalidate equal rebuilt bytes.
            filtered_unconfirmed_outputs: BTreeSet::new(),
            filtered_dirty_keys: BTreeSet::new(),
            filtered_probe_root_dirty: false,
            filtered_compatible: self.filtered_compatible,
            keep_modified_outputs: self.keep_modified_outputs,
            filtered_coordinator: Some(coordinator),
            filtered_worker: worker,
        }
    }

    pub(crate) fn merge_worker_state(&mut self, mut worker: Self) {
        self.built_keys.append(&mut worker.built_keys);
        self.demanded_keys.append(&mut worker.demanded_keys);
        self.filtered_snapshot_delta
            .append(&mut worker.filtered_snapshot_delta);
        self.filtered_unconfirmed_outputs
            .append(&mut worker.filtered_unconfirmed_outputs);
        self.filtered_dirty_keys
            .append(&mut worker.filtered_dirty_keys);
        self.results.append(&mut worker.results);
        if let Some(error) = worker.failed_demand.take() {
            self.failed_demand.get_or_insert(error);
        }
    }

    fn publication(
        &self,
        spec: &BuildSpec,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
    ) -> ActionPublication {
        let outputs = spec
            .outputs
            .iter()
            .map(|output| {
                let status = if let Some(bytes) = overlay.get(output) {
                    PublishedOutput::Bytes(Arc::clone(bytes))
                } else if deleted.contains(output) {
                    PublishedOutput::Missing
                } else {
                    PublishedOutput::OnDisk
                };
                (output.clone(), status)
            })
            .collect();
        let snapshots = spec
            .outputs
            .iter()
            .filter_map(|output| {
                self.filtered_snapshot_delta
                    .get(output)
                    .map(|snapshot| (output.clone(), snapshot.clone()))
            })
            .collect();
        ActionPublication { outputs, snapshots }
    }

    fn apply_publication(
        &mut self,
        spec: &BuildSpec,
        publication: &ActionPublication,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted: &mut BTreeSet<String>,
    ) {
        for output in &spec.outputs {
            if let Some(status) = publication.outputs.get(output) {
                apply_published_output(output, status, overlay, deleted);
            }
        }
        self.filtered_snapshot_delta
            .extend(publication.snapshots.clone());
        let key = spec.action_key();
        self.demanded_keys.insert(key.clone());
        self.built_keys.insert(key);
    }

    fn complete_action(
        &mut self,
        spec: &BuildSpec,
        claim: &mut Option<ActionClaimGuard>,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
    ) {
        if let Some(mut claim) = claim.take() {
            claim.complete(self.publication(spec, overlay, deleted));
        }
    }

    pub(crate) fn demanded_keys(&self) -> &BTreeSet<String> {
        &self.demanded_keys
    }

    fn record_demand_failure(&mut self, error: &io::Error) {
        if self.filtered_previous.is_some() {
            self.failed_demand.get_or_insert_with(|| error.to_string());
        }
        if let Some(coordinator) = &self.filtered_coordinator {
            coordinator.fail_worker(error.to_string());
        }
    }

    fn mark_filtered_dirty(&mut self, spec: &BuildSpec) {
        self.filtered_dirty_keys.insert(spec.action_key());
        self.filtered_unconfirmed_outputs
            .extend(spec.outputs.iter().cloned());
        self.filtered_probe_root_dirty = true;
    }

    pub(crate) fn failed_demand(&self) -> Option<&str> {
        self.failed_demand.as_deref()
    }

    pub(crate) fn probe_filtered_roots(
        &mut self,
        workspace: &Workspace,
        roots: &[String],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        specs: &BTreeMap<String, BuildSpec>,
    ) -> io::Result<Vec<String>> {
        let mut dirty_roots = Vec::new();
        let mut execution = FilteredExecution::Probe;
        for root in roots {
            self.filtered_probe_root_dirty = false;
            execution.ensure_optional_output(
                workspace,
                root,
                overlay,
                deleted_overlay,
                visibility,
                u32::MAX,
                BuilderKind::Normal,
                specs,
                self,
            )?;
            if self.filtered_probe_root_dirty {
                dirty_roots.push(root.clone());
            }
        }
        self.filtered_probe_root_dirty = false;
        Ok(dirty_roots)
    }

    pub fn take_results(&mut self) -> Vec<LazyBuildResult> {
        std::mem::take(&mut self.results)
    }
}

impl WorkerClient {
    /// Runs one action requested by a suspended asset RPC. The Dart worker
    /// receives this as a nested `build` message and returns before the
    /// original asset request is answered.
    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    fn build_lazy(
        &mut self,
        workspace: &Workspace,
        request: &BuildRequest,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<BuildResult> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_build_lazy", Some(id));
        let effective_deleted;
        let deleted = if lazy.filtered_previous.is_some() {
            // Pending producers must still reach the demand RPC even if their
            // stale artifact is logically deleted. Keep phase blocking intact.
            effective_deleted = deleted_overlay
                .iter()
                .filter(|asset| {
                    !lazy_specs
                        .get(*asset)
                        .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()))
                })
                .cloned()
                .collect();
            &effective_deleted
        } else {
            &*deleted_overlay
        };
        let blocked_assets =
            visibility.blocked_assets(request.phase, build_request_kind(request), deleted);
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
                    Some("asset_request") => self.handle_lazy_asset_request(
                        workspace,
                        &response,
                        overlay,
                        deleted_overlay,
                        visibility,
                        request,
                        id,
                        lazy_specs,
                        lazy,
                    )?,
                    Some("build_result") => {
                        return Err(io::Error::other(
                            "worker sent JSON build result; binary capability is required",
                        ));
                    }
                    Some("error") => return Err(protocol_error("worker error", &response)),
                    _ => return Err(protocol_error("unexpected worker message", &response)),
                },
                IncomingFrame::Binary(frame) => {
                    if let Some(graph) = frame.metadata.get("dep_graph") {
                        let edges: BTreeMap<String, Vec<String>> =
                            serde_json::from_value(graph.clone()).map_err(io::Error::other)?;
                        self.dep_graph.extend(edges);
                    } else if lazy.filtered_previous.is_some() {
                        return Err(io::Error::other(
                            "filtered demand requires single-result resolver dependency metadata",
                        ));
                    }
                    let result = decode_build_result_frame(frame)?;
                    if lazy.filtered_previous.is_some() && result.stock_inputs.is_none() {
                        return Err(io::Error::other(
                            "filtered demand requires ordered stock inputs",
                        ));
                    }
                    if lazy.filtered_previous.is_some() && result.stock_globs.is_none() {
                        return Err(io::Error::other(
                            "filtered demand requires stock glob results",
                        ));
                    }
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

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub(super) fn build_batch_lazy(
        &mut self,
        workspace: &Workspace,
        requests: &[BuildRequest],
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<Vec<BuildResult>> {
        let started = Instant::now();
        let id = self.next_id();
        let _wall = self.wall_span("worker_batch_lazy", Some(id));
        // Lazy batches have the same visibility context as ordinary batches;
        // the nested build path still carries its own single-action hint.
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

        loop {
            match self.receive()? {
                IncomingFrame::Json(response) => match response.get("type").and_then(Value::as_str)
                {
                    Some("asset_request") => {
                        let (build_id, active_request) =
                            batch_asset_request_context(&response, requests)?;
                        self.handle_lazy_asset_request(
                            workspace,
                            &response,
                            overlay,
                            deleted_overlay,
                            visibility,
                            active_request,
                            build_id,
                            lazy_specs,
                            lazy,
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

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    fn handle_lazy_asset_request(
        &mut self,
        workspace: &Workspace,
        request: &Value,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        active_request: &BuildRequest,
        expected_build_id: u64,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let _wall = self.wall_span("asset_rpc_lazy", None);
        validate_asset_request_context(request, active_request, expected_build_id)?;
        let operation = request
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let phase = active_request.phase;
        let kind = build_request_kind(active_request);
        match operation {
            "resolve_assets" => {
                // Speculative reads must not bypass demand-driven optional
                // builders or cache their previous on-disk outputs. Keep
                // this path sequential: the worker treats a failed prefetch
                // as a cache miss, and read/can_read below ensure the output
                // is rebuilt only when the resolver actually requests it.
                return self.send_asset_error(
                    request,
                    &io::Error::other("dependency prefetch disabled during lazy builds"),
                );
            }
            "read" | "can_read" => {
                if let Some(asset) = request.get("asset").and_then(Value::as_str)
                    && let Err(error) = self.ensure_optional_output(
                        workspace,
                        asset,
                        overlay,
                        deleted_overlay,
                        visibility,
                        phase,
                        kind,
                        lazy_specs,
                        lazy,
                    )
                {
                    lazy.record_demand_failure(&error);
                    return self.send_asset_error(request, &error);
                }
            }
            "find_assets" => {
                let package = request
                    .get("package")
                    .and_then(Value::as_str)
                    .unwrap_or(workspace.root_package.as_str());
                let pattern = request
                    .get("pattern")
                    .and_then(Value::as_str)
                    .unwrap_or("**");
                let candidates = glob_candidates(lazy_specs, package, pattern)
                    .filter_map(|asset| {
                        let (asset_package, asset_path) = asset.split_once('|')?;
                        (asset_package == package && matches_glob(pattern, asset_path))
                            .then_some(asset.clone())
                    })
                    .collect::<Vec<_>>();
                for asset in candidates {
                    if lazy.filtered_previous.is_none()
                        && visibility.is_blocked(&asset, phase, kind, deleted_overlay)
                    {
                        continue;
                    }
                    // Filtered demand decides deletion visibility after checking
                    // whether this asset has an unbuilt replacement producer.
                    if let Err(error) = self.ensure_optional_output(
                        workspace,
                        &asset,
                        overlay,
                        deleted_overlay,
                        visibility,
                        phase,
                        kind,
                        lazy_specs,
                        lazy,
                    ) {
                        lazy.record_demand_failure(&error);
                        return self.send_asset_error(request, &error);
                    }
                }
            }
            _ => {}
        }
        if operation == "find_assets" && lazy.filtered_previous.is_some() {
            let started = Instant::now();
            let package = request
                .get("package")
                .and_then(Value::as_str)
                .unwrap_or(&workspace.root_package);
            let pattern = request
                .get("pattern")
                .and_then(Value::as_str)
                .unwrap_or("**");
            let assets = filtered_glob_members(
                workspace,
                package,
                pattern,
                overlay,
                deleted_overlay,
                visibility,
                phase,
                kind,
                lazy_specs,
            )?;
            self.metrics.find_assets_requests += 1;
            self.metrics.asset_requests += 1;
            self.metrics.find_assets_results += assets.len() as u64;
            let result = self.send(&json!({"v": 1, "type": "asset_response", "id": request["id"], "ok": true, "assets": assets}));
            self.metrics.asset_rpc_us += started.elapsed().as_micros() as u64;
            return result;
        }
        self.handle_asset_request(
            workspace,
            request,
            &*overlay,
            &*deleted_overlay,
            visibility,
            active_request,
            expected_build_id,
            Some(FilteredAssetEvidence { lazy, lazy_specs }),
        )
    }

    fn send_asset_error(&mut self, request: &Value, error: &io::Error) -> io::Result<()> {
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("asset request has no id"))?;
        self.send(&json!({
            "v": 1,
            "type": "asset_response",
            "id": id,
            "ok": false,
            "error": error.to_string(),
        }))
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    pub(super) fn ensure_optional_output(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let mut execution = FilteredExecution::Worker(self);
        execution.ensure_optional_output(
            workspace,
            asset,
            overlay,
            deleted_overlay,
            visibility,
            phase,
            kind,
            lazy_specs,
            lazy,
        )
    }
}

impl FilteredExecution<'_> {
    #[expect(
        clippy::too_many_arguments,
        reason = "Filtered demand shares one reuse path between probe and worker execution"
    )]
    fn ensure_optional_output(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let coordinator = match self {
            Self::Worker(_) => lazy.filtered_coordinator.clone(),
            Self::Probe => None,
        };
        let Some(coordinator) = coordinator else {
            let pending_producer = lazy.filtered_previous.is_some()
                && lazy_specs
                    .get(asset)
                    .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()));
            let blocked = if pending_producer {
                visibility.is_blocked(asset, phase, kind, &BTreeSet::new())
            } else {
                visibility.is_blocked(asset, phase, kind, deleted_overlay)
            };
            if blocked || overlay.contains_key(asset) {
                return Ok(());
            }
            let Some(spec) = lazy_specs
                .get(asset)
                .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
                .cloned()
            else {
                return Ok(());
            };
            let key = spec.action_key();
            if lazy.built_keys.contains(&key)
                || (lazy.filtered_previous.is_none() && !lazy.force_keys.contains(&key))
            {
                return Ok(());
            }
            if !lazy.building_keys.insert(key.clone()) {
                return Err(io::Error::other(format!(
                    "optional builder dependency cycle while reading {asset}"
                )));
            }
            lazy.demanded_keys.insert(key.clone());
            lazy.building_stack.push(key.clone());
            let result = self.ensure_optional_output_body(
                workspace,
                asset,
                overlay,
                deleted_overlay,
                visibility,
                phase,
                kind,
                lazy_specs,
                lazy,
            );
            lazy.building_stack.pop();
            lazy.building_keys.remove(&key);
            return result;
        };

        let pending_producer = lazy.filtered_previous.is_some()
            && lazy_specs
                .get(asset)
                .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()));
        let blocked = if pending_producer {
            visibility.is_blocked(asset, phase, kind, &BTreeSet::new())
        } else {
            visibility.is_blocked(asset, phase, kind, deleted_overlay)
        };
        if blocked || overlay.contains_key(asset) {
            return Ok(());
        }
        let Some(spec) = lazy_specs
            .get(asset)
            .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
            .cloned()
        else {
            return Ok(());
        };
        let key = spec.action_key();
        if lazy.built_keys.contains(&key) {
            return Ok(());
        }
        if lazy.filtered_previous.is_none() && !lazy.force_keys.contains(&key) {
            return Ok(());
        }
        if lazy.building_keys.contains(&key) {
            return Err(io::Error::other(format!(
                "filtered dependency cycle while reading {asset}"
            )));
        }
        if let Some(error) = coordinator.failure() {
            return Err(io::Error::other(error));
        }
        lazy.demanded_keys.insert(key.clone());
        let parent = lazy.building_stack.last().map(String::as_str);
        let claim = match coordinator.claim(&key, parent, lazy.filtered_worker) {
            Ok(claim) => claim,
            Err(error) => {
                lazy.record_demand_failure(&error);
                return Err(error);
            }
        };
        let mut owner = match claim {
            DemandClaim::Complete(publication) => {
                lazy.apply_publication(&spec, &publication, overlay, deleted_overlay);
                return Ok(());
            }
            DemandClaim::Owner(owner) => Some(owner),
        };

        lazy.building_keys.insert(key.clone());
        lazy.building_stack.push(key.clone());
        let result = self.ensure_optional_output_body(
            workspace,
            asset,
            overlay,
            deleted_overlay,
            visibility,
            phase,
            kind,
            lazy_specs,
            lazy,
        );
        lazy.building_stack.pop();
        lazy.building_keys.remove(&key);
        match result {
            Ok(()) => {
                lazy.complete_action(&spec, &mut owner, overlay, deleted_overlay);
                Ok(())
            }
            Err(error) => {
                if let Some(owner) = owner.as_mut() {
                    owner.fail(error.to_string());
                }
                lazy.record_demand_failure(&error);
                Err(error)
            }
        }
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "IPC operations pass workspace, visibility, and transaction state explicitly"
    )]
    fn ensure_optional_output_body(
        &mut self,
        workspace: &Workspace,
        asset: &str,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        phase: u32,
        kind: BuilderKind,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<()> {
        let pending_producer = lazy.filtered_previous.is_some()
            && lazy_specs
                .get(asset)
                .is_some_and(|spec| !lazy.built_keys.contains(&spec.action_key()));
        let blocked = if pending_producer {
            // An obsolete action's deletion must not block its replacement
            // producer. Phase visibility still applies; completed missing
            // outputs remain blocked by the ordinary deleted overlay.
            visibility.is_blocked(asset, phase, kind, &BTreeSet::new())
        } else {
            visibility.is_blocked(asset, phase, kind, deleted_overlay)
        };
        if blocked || overlay.contains_key(asset) {
            return Ok(());
        }
        let Some(spec) = lazy_specs
            .get(asset)
            .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
            .cloned()
        else {
            return Ok(());
        };
        let key = spec.action_key();
        if lazy.built_keys.contains(&key) {
            return Ok(());
        }
        if lazy.filtered_previous.is_none() && !lazy.force_keys.contains(&key) {
            return Ok(());
        }
        lazy.demanded_keys.insert(key.clone());

        if lazy.filtered_previous.is_some() {
            // Stock computes a generated primary input before checking reuse.
            self.ensure_optional_output(
                workspace,
                &spec.input,
                overlay,
                deleted_overlay,
                visibility,
                spec.instance.phase,
                BuilderKind::Normal,
                lazy_specs,
                lazy,
            )?;
            // A probe cannot know whether a dirty generated primary will
            // exist until its producer executes. Do not classify its parent
            // from stale on-disk bytes or as skipped-missing-input.
            if lazy_specs
                .get(&spec.input)
                .is_some_and(|producer| lazy.filtered_dirty_keys.contains(&producer.action_key()))
            {
                lazy.mark_filtered_dirty(&spec);
                return Ok(());
            }
            // Stock skips a missing generated primary before examining any
            // old secondary dependency. Such dependencies must leave demand
            // state even if their retained physical outputs still exist.
            if lazy_specs.contains_key(&spec.input)
                && (deleted_overlay.contains(&spec.input)
                    || (!overlay.contains_key(&spec.input)
                        && !workspace.asset_exists_at(
                            &spec.input,
                            visibility
                                .location(&spec.input)
                                .unwrap_or(spec.instance.builder.build_to),
                        )?))
            {
                let result = crate::build::empty_filtered_result(&spec);
                for output in &spec.outputs {
                    deleted_overlay.insert(output.clone());
                    overlay.remove(output);
                }
                lazy.built_keys.insert(key);
                lazy.update_outputs(&spec, overlay, deleted_overlay);
                lazy.results.push(LazyBuildResult { spec, result });
                return Ok(());
            }
            let previous = lazy
                .filtered_previous
                .as_ref()
                .and_then(|state| state.actions.get(&key))
                .cloned();
            let mut needs_build = !lazy.filtered_compatible
                || previous.as_ref().is_none_or(|action| {
                    matches!(
                        action.status.as_str(),
                        "skipped_missing_input" | "undemanded"
                    )
                });
            if let Some(producer) = lazy_specs.get(&spec.input) {
                let previously_output = lazy
                    .filtered_previous
                    .as_ref()
                    .and_then(|state| state.actions.get(&producer.action_key()))
                    .is_some_and(|action| action.outputs.contains(&spec.input));
                let primary_exists = lazy
                    .filtered_snapshot_delta
                    .get(&spec.input)
                    .or_else(|| lazy.filtered_snapshot.get(&spec.input))
                    .is_some_and(|snapshot| snapshot.exists);
                if !previously_output && primary_exists {
                    needs_build = true;
                }
            }
            if let Some(previous) = &previous {
                for output in &previous.outputs {
                    let current = crate::plan::output_digest(&crate::plan::output_path(
                        workspace,
                        &spec.instance.builder,
                        output,
                    )?)?;
                    if current.is_none()
                        || (!lazy.keep_modified_outputs
                            && previous.output_digests.get(output) != current.as_ref())
                    {
                        needs_build = true;
                    }
                }
                if !needs_build {
                    // Like stock _computeStepAction, inspect old dependencies only
                    // until a change requires running the step. New reads are then
                    // demanded by the actual BuildStep, never by an old closure.
                    let dependencies = lazy
                        .filtered_previous
                        .as_ref()
                        .and_then(|state| state.stock_input_order.get(&key))
                        .ok_or_else(|| io::Error::other("ordered stock inputs are unavailable"))?
                        .clone();
                    for dependency in dependencies {
                        self.ensure_optional_output(
                            workspace,
                            &dependency,
                            overlay,
                            deleted_overlay,
                            visibility,
                            spec.instance.phase,
                            BuilderKind::Normal,
                            lazy_specs,
                            lazy,
                        )?;
                        if lazy.asset_changed(&dependency) {
                            needs_build = true;
                            break;
                        }
                    }
                }
                if !needs_build {
                    for glob in &previous.glob_reads {
                        let candidates: Vec<String> = lazy_specs
                            .keys()
                            .filter(|asset| {
                                asset.split_once('|').is_some_and(|(package, path)| {
                                    package == glob.package && matches_glob(&glob.pattern, path)
                                })
                            })
                            .cloned()
                            .collect();
                        for asset in candidates {
                            self.ensure_optional_output(
                                workspace,
                                &asset,
                                overlay,
                                deleted_overlay,
                                visibility,
                                spec.instance.phase,
                                BuilderKind::Normal,
                                lazy_specs,
                                lazy,
                            )?;
                            // A producer reached only to classify glob
                            // membership may itself need to run. The probe
                            // cannot seed this consumer as reused until that
                            // producer's actual output set is known.
                            if matches!(self, FilteredExecution::Probe)
                                && lazy_specs.get(&asset).is_some_and(|producer| {
                                    lazy.filtered_dirty_keys.contains(&producer.action_key())
                                })
                            {
                                needs_build = true;
                                break;
                            }
                        }
                        if needs_build {
                            break;
                        }
                        let matched = filtered_glob_members(
                            workspace,
                            &glob.package,
                            &glob.pattern,
                            overlay,
                            deleted_overlay,
                            visibility,
                            spec.instance.phase,
                            BuilderKind::Normal,
                            lazy_specs,
                        )?;
                        let glob_key = format!("{}|{}", glob.package, glob.pattern);
                        let old = lazy
                            .filtered_previous
                            .as_ref()
                            .and_then(|s| s.stock_glob_members.get(&key))
                            .and_then(|globs| globs.get(&glob_key))
                            .ok_or_else(|| {
                                io::Error::other("per-action stock glob evidence is unavailable")
                            })?;
                        if old != &matched {
                            needs_build = true;
                            break;
                        }
                    }
                }
                if !needs_build {
                    // Stock evaluates resolver graphs after inputs and globs.
                    // Evaluate children before parents and accumulate changes
                    // across the full previously resolved acyclic graph.
                    for entrypoint in &previous.resolver_entrypoints {
                        let mut seen = BTreeSet::new();
                        let mut stack = vec![(entrypoint.clone(), false)];
                        let mut changed = false;
                        while let Some((dependency, expanded)) = stack.pop() {
                            if !expanded {
                                if !seen.insert(dependency.clone()) {
                                    continue;
                                }
                                stack.push((dependency.clone(), true));
                                if let Some(edges) = lazy
                                    .filtered_previous
                                    .as_ref()
                                    .and_then(|s| s.resolver_dep_graph.get(&dependency))
                                {
                                    stack.extend(
                                        edges.iter().rev().map(|asset| (asset.clone(), false)),
                                    );
                                }
                                continue;
                            }
                            self.ensure_optional_output(
                                workspace,
                                &dependency,
                                overlay,
                                deleted_overlay,
                                visibility,
                                spec.instance.phase,
                                BuilderKind::Normal,
                                lazy_specs,
                                lazy,
                            )?;
                            changed |= lazy.asset_changed(&dependency);
                        }
                        if changed {
                            needs_build = true;
                            break;
                        }
                    }
                }
            }
            if !needs_build {
                // A reused producer still determines which declared siblings
                // exist. A stray on-disk file cannot turn an omitted output
                // into a readable generated input for its consumers.
                if let Some(previous) = &previous {
                    for output in &spec.outputs {
                        if !previous.outputs.contains(output) {
                            deleted_overlay.insert(output.clone());
                            overlay.remove(output);
                        }
                    }
                    lazy.update_outputs(&spec, overlay, deleted_overlay);
                }
                lazy.built_keys.insert(key);
                return Ok(());
            }
        }

        // Ordinary optional chains have the same missing-primary rule as
        // filtered demand: run the producer first, then skip an absent input.
        if lazy.filtered_previous.is_none() && lazy_specs.contains_key(&spec.input) {
            self.ensure_optional_output(
                workspace,
                &spec.input,
                overlay,
                deleted_overlay,
                visibility,
                spec.instance.phase,
                BuilderKind::Normal,
                lazy_specs,
                lazy,
            )?;
            if deleted_overlay.contains(&spec.input)
                || (!overlay.contains_key(&spec.input)
                    && !workspace.asset_exists_at(
                        &spec.input,
                        visibility
                            .location(&spec.input)
                            .unwrap_or(spec.instance.builder.build_to),
                    )?)
            {
                let result = crate::build::empty_filtered_result(&spec);
                for output in &spec.outputs {
                    deleted_overlay.insert(output.clone());
                    overlay.remove(output);
                }
                lazy.built_keys.insert(key);
                lazy.results.push(LazyBuildResult { spec, result });
                return Ok(());
            }
        }

        if matches!(self, FilteredExecution::Probe) {
            lazy.mark_filtered_dirty(&spec);
            return Ok(());
        }

        for output in &spec.outputs {
            deleted_overlay.insert(output.clone());
            overlay.remove(output);
        }
        let request = BuildRequest {
            builder: spec.instance.builder.id.clone(),
            input: spec.input.clone(),
            outputs: spec.outputs.clone(),
            options: spec.instance.options.clone(),
            phase: spec.instance.phase,
            instance_key: spec.instance.instance_key.clone(),
            is_root: spec.instance.is_root,
            post_process: false,
            triggers: spec.instance.builder.triggers.clone(),
        };
        let result = self.build_lazy(
            workspace,
            &request,
            overlay,
            deleted_overlay,
            visibility,
            lazy_specs,
            lazy,
        );
        let result = result?;
        if result.status != "success" && result.status != "not_triggered" {
            return Err(io::Error::other(
                result
                    .error
                    .clone()
                    .unwrap_or_else(|| "Optional builder failed".to_owned()),
            ));
        }
        if !result.deleted.is_empty() {
            return Err(io::Error::other(format!(
                "deletePrimaryInput is only supported for post-process builders: {}",
                result.deleted.join(", ")
            )));
        }
        let allowed = spec.outputs.iter().cloned().collect::<BTreeSet<_>>();
        for generated in &result.outputs {
            if !allowed.contains(&generated.asset) {
                return Err(io::Error::other(format!(
                    "unexpected output from optional builder {}: {}",
                    spec.instance.builder.id, generated.asset
                )));
            }
            overlay.insert(generated.asset.clone(), Arc::clone(&generated.bytes));
            deleted_overlay.remove(&generated.asset);
        }
        let actual_outputs = result
            .outputs
            .iter()
            .map(|output| output.asset.as_str())
            .collect::<BTreeSet<_>>();
        for expected in &spec.outputs {
            if !actual_outputs.contains(expected.as_str()) {
                deleted_overlay.insert(expected.clone());
                overlay.remove(expected);
            }
        }
        lazy.built_keys.insert(key);
        lazy.update_outputs(&spec, overlay, deleted_overlay);
        lazy.results.push(LazyBuildResult { spec, result });
        Ok(())
    }

    #[expect(
        clippy::too_many_arguments,
        reason = "Demand execution passes its shared transaction context explicitly"
    )]
    fn build_lazy(
        &mut self,
        workspace: &Workspace,
        request: &BuildRequest,
        overlay: &mut BTreeMap<String, Arc<[u8]>>,
        deleted_overlay: &mut BTreeSet<String>,
        visibility: &AssetVisibility,
        lazy_specs: &BTreeMap<String, BuildSpec>,
        lazy: &mut LazyBuildState,
    ) -> io::Result<BuildResult> {
        match self {
            Self::Worker(worker) => worker.build_lazy(
                workspace,
                request,
                overlay,
                deleted_overlay,
                visibility,
                lazy_specs,
                lazy,
            ),
            Self::Probe => Err(io::Error::other("filtered probe cannot execute a builder")),
        }
    }
}

#[cfg(test)]
mod demand_coordinator_tests {
    use super::*;
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, Instant};

    fn owner(claim: DemandClaim) -> ActionClaimGuard {
        match claim {
            DemandClaim::Owner(owner) => owner,
            DemandClaim::Complete(_) => panic!("action unexpectedly completed"),
        }
    }

    #[test]
    fn source_observations_are_shared_across_workers_and_committed_consistently() {
        let coordinator = FilteredDemandCoordinator::default();
        let mut merged = LazyBuildState::new(BTreeSet::new());
        let asset = "external|lib/shared.txt";
        let first_bytes: Arc<[u8]> = Arc::from(&b"first version"[..]);
        let first_snapshot = crate::snapshot::AssetSnapshot {
            exists: true,
            digest: crate::digest::digest_bytes(&first_bytes),
            size: first_bytes.len() as u64,
        };
        for (worker, value) in [(0, b"first version".as_slice()), (1, b"edited version")] {
            let mut state = merged.worker_state(worker, coordinator.clone());
            let published = state.publish_source_observation(
                asset,
                FilteredSourceObservation {
                    content: FilteredSourceContent::Bytes(Arc::from(value)),
                    snapshot: crate::snapshot::AssetSnapshot {
                        exists: true,
                        digest: crate::digest::digest_bytes(value),
                        size: value.len() as u64,
                    },
                },
            );
            assert_eq!(published.snapshot, first_snapshot);
            match published.content {
                FilteredSourceContent::Bytes(bytes) => assert_eq!(&*bytes, &*first_bytes),
                FilteredSourceContent::Spool(_) | FilteredSourceContent::Missing => {
                    panic!("the transaction-wide byte publication was not reused")
                }
            }
            merged.merge_worker_state(state);
        }

        assert_eq!(
            merged.filtered_snapshot_delta.get(asset),
            Some(&first_snapshot)
        );
    }

    #[test]
    fn nested_cross_worker_wait_cycle_is_detected_and_wakes_waiter() {
        let coordinator = FilteredDemandCoordinator::default();
        let _root = owner(coordinator.claim("A", None, 0).unwrap());
        let _nested = owner(coordinator.claim("B", Some("A"), 0).unwrap());
        let _other_root = owner(coordinator.claim("C", None, 1).unwrap());
        let waiting_coordinator = coordinator.clone();
        let (waiter_tx, waiter_rx) = mpsc::channel();
        let waiter = thread::spawn(move || {
            let result = waiting_coordinator
                .claim("C", Some("B"), 0)
                .map(|claim| matches!(claim, DemandClaim::Complete(_)))
                .map_err(|error| error.to_string());
            let _ = waiter_tx.send(result);
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while coordinator.lock().dependencies.get("B").map(String::as_str) != Some("C") {
            assert!(
                Instant::now() < deadline,
                "nested wait edge was not recorded"
            );
            thread::yield_now();
        }

        let cycle_coordinator = coordinator.clone();
        let (cycle_tx, cycle_rx) = mpsc::channel();
        let cycle = thread::spawn(move || {
            let result = cycle_coordinator
                .claim("A", Some("C"), 1)
                .map(|claim| matches!(claim, DemandClaim::Complete(_)))
                .map_err(|error| error.to_string());
            let _ = cycle_tx.send(result);
        });
        let cycle_error = cycle_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("cycle claim hung instead of detecting the nested wait cycle")
            .unwrap_err();
        assert!(cycle_error.contains("wait cycle"), "{cycle_error}");
        let waiter_result = waiter_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("waiter was not released after cycle detection");
        assert!(waiter_result.is_err(), "waiter did not receive the failure");
        assert!(coordinator.failure().unwrap().contains("wait cycle"));
        cycle.join().expect("cycle thread panicked");
        waiter.join().expect("waiter thread panicked");
    }

    #[test]
    fn dropped_running_owner_latches_failure_and_releases_waiters() {
        let coordinator = FilteredDemandCoordinator::default();
        let shared_owner = owner(coordinator.claim("shared", None, 0).unwrap());
        let _consumer = owner(coordinator.claim("consumer", None, 1).unwrap());
        let waiting_coordinator = coordinator.clone();
        let (waiter_tx, waiter_rx) = mpsc::channel();
        let waiter = thread::spawn(move || {
            let result = waiting_coordinator
                .claim("shared", Some("consumer"), 1)
                .map(|claim| matches!(claim, DemandClaim::Complete(_)))
                .map_err(|error| error.to_string());
            let _ = waiter_tx.send(result);
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while coordinator
            .lock()
            .dependencies
            .get("consumer")
            .map(String::as_str)
            != Some("shared")
        {
            assert!(
                Instant::now() < deadline,
                "waiter did not record its dependency edge"
            );
            thread::yield_now();
        }
        drop(shared_owner);
        let result = waiter_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("dropped owner did not wake its waiter");
        assert!(result.is_err());
        assert!(
            coordinator
                .failure()
                .unwrap()
                .contains("exited without publishing")
        );
        waiter.join().expect("waiter thread panicked");
    }

    #[test]
    fn protocol_failure_is_shared_with_waiting_worker() {
        let coordinator = FilteredDemandCoordinator::default();
        let mut shared_owner = owner(coordinator.claim("shared", None, 0).unwrap());
        let _consumer = owner(coordinator.claim("consumer", None, 1).unwrap());
        let waiting_coordinator = coordinator.clone();
        let (waiter_tx, waiter_rx) = mpsc::channel();
        let waiter = thread::spawn(move || {
            let result = waiting_coordinator
                .claim("shared", Some("consumer"), 1)
                .map(|claim| matches!(claim, DemandClaim::Complete(_)))
                .map_err(|error| error.to_string());
            let _ = waiter_tx.send(result);
        });
        let deadline = Instant::now() + Duration::from_secs(1);
        while coordinator
            .lock()
            .dependencies
            .get("consumer")
            .map(String::as_str)
            != Some("shared")
        {
            assert!(
                Instant::now() < deadline,
                "waiter did not record its dependency edge"
            );
            thread::yield_now();
        }
        shared_owner.fail("worker IPC failed".to_owned());
        let result = waiter_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("worker failure did not wake its waiter");
        assert!(result.unwrap_err().contains("worker IPC failed"));
        waiter.join().expect("waiter thread panicked");
    }

    #[test]
    fn action_publication_updates_all_siblings_as_one_bundle() {
        let coordinator = FilteredDemandCoordinator::default();
        let mut claim = owner(coordinator.claim("multi", None, 0).unwrap());
        let publication = ActionPublication {
            outputs: BTreeMap::from([
                (
                    "app|lib/a.mid".to_owned(),
                    PublishedOutput::Bytes(Arc::from(&b"generated"[..])),
                ),
                ("app|lib/a.side".to_owned(), PublishedOutput::Missing),
                ("app|lib/a.final".to_owned(), PublishedOutput::OnDisk),
            ]),
            snapshots: BTreeMap::new(),
        };
        claim.complete(publication);

        let completed = match coordinator.claim("multi", None, 1).unwrap() {
            DemandClaim::Complete(publication) => publication,
            DemandClaim::Owner(_) => panic!("completed action was claimed again"),
        };
        assert_eq!(completed.outputs.len(), 3);
        let mut overlay =
            BTreeMap::from([("app|lib/a.final".to_owned(), Arc::from(&b"stale"[..]))]);
        let mut deleted = BTreeSet::from(["app|lib/a.mid".to_owned()]);
        for (asset, output) in &completed.outputs {
            apply_published_output(asset, output, &mut overlay, &mut deleted);
        }
        assert_eq!(overlay["app|lib/a.mid"].as_ref(), b"generated");
        assert!(!overlay.contains_key("app|lib/a.final"));
        assert_eq!(deleted, BTreeSet::from(["app|lib/a.side".to_owned()]));
    }
}
