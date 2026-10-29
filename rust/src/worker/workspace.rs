//! Bounded workspace leases with one package context per resident process.
use super::client::WorkerClient;
use super::overlay_blob::OverlayBlob;
use super::request::BuildRequest;
use crate::builder::BuildTo;
use crate::protocol::BuildResult;
use crate::visibility::AssetVisibility;
use crate::worker_kernel::{WorkerArtifact, resolve_worker_artifact};
use crate::workspace::Workspace;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::ops::Range;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, OnceLock, Weak, mpsc};
use std::time::{Duration, Instant};

/// A complete baseline of the phase-visible asset view. Assets already hidden
/// by the phase guard need not be transported or invalidate a resident view.
pub(crate) struct WorkspaceBaseline {
    overlay: BTreeMap<String, Arc<[u8]>>,
    deleted: BTreeSet<String>,
    updated_sources: Value,
    deleted_sources: Value,
    updated_cache: Value,
    deleted_cache: Value,
    blob: OverlayBlob,
}

impl WorkspaceBaseline {
    pub(crate) fn matches(
        &self,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
        hidden: &BTreeSet<String>,
    ) -> bool {
        overlay
            .iter()
            .filter(|(asset, _)| !hidden.contains(*asset))
            .eq(self.overlay.iter())
            && deleted
                .iter()
                .filter(|asset| !hidden.contains(*asset))
                .eq(self.deleted.iter())
    }

    fn is_empty(&self) -> bool {
        self.overlay.is_empty() && self.deleted.is_empty()
    }

    pub(crate) fn new(
        workspace: &Workspace,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
        visibility: &AssetVisibility,
        hidden: &BTreeSet<String>,
    ) -> io::Result<Arc<Self>> {
        // Rust and Dart still receive the full phase guard on each batch.
        // Keep logical deletions not covered by it, including removed outputs
        // absent from the current plan and visible post-process cleanup.
        let overlay = overlay
            .iter()
            .filter(|(asset, _)| !hidden.contains(*asset))
            .map(|(asset, bytes)| (asset.clone(), Arc::clone(bytes)))
            .collect::<BTreeMap<_, _>>();
        let deleted = deleted
            .iter()
            .filter(|asset| !hidden.contains(*asset))
            .cloned()
            .collect::<BTreeSet<_>>();
        let (sources, cache): (BTreeSet<_>, BTreeSet<_>) = overlay
            .keys()
            .cloned()
            .partition(|asset| visibility.location(asset) != Some(BuildTo::Cache));
        let (source_deletes, cache_deletes): (BTreeSet<_>, BTreeSet<_>) = deleted
            .iter()
            .cloned()
            .partition(|asset| visibility.location(asset) != Some(BuildTo::Cache));
        let blob = OverlayBlob::create(
            &workspace.root,
            &overlay,
            &overlay.keys().cloned().collect(),
        )?;
        Ok(Arc::new(Self {
            overlay,
            deleted,
            updated_sources: json!(sources),
            deleted_sources: json!(source_deletes),
            updated_cache: json!(cache),
            deleted_cache: json!(cache_deletes),
            blob,
        }))
    }
}

pub(crate) struct WorkspaceLease {
    pub(crate) application: usize,
    pub(crate) package: String,
    pub(crate) requests: Arc<Vec<BuildRequest>>,
    pub(crate) range: Range<usize>,
    pub(crate) baseline: Arc<WorkspaceBaseline>,
}

pub(crate) struct WorkspaceCompletion {
    pub(crate) worker: usize,
    pub(crate) application: usize,
    pub(crate) range: Range<usize>,
    pub(crate) results: io::Result<Vec<BuildResult>>,
    pub(crate) dep_graph: BTreeMap<String, Vec<String>>,
    pub(crate) elapsed: Duration,
}

pub(crate) struct WorkspaceDispatch {
    pub(super) leases: Vec<mpsc::SyncSender<WorkspaceLease>>,
    pub(super) completions: mpsc::Receiver<WorkspaceCompletion>,
}

impl WorkspaceDispatch {
    pub(crate) fn worker_count(&self) -> usize {
        self.leases.len()
    }

    pub(crate) fn send(&self, worker: usize, lease: WorkspaceLease) -> io::Result<()> {
        self.leases[worker]
            .send(lease)
            .map_err(|_| io::Error::other("workspace worker disconnected"))
    }

    pub(crate) fn receive(&self) -> io::Result<WorkspaceCompletion> {
        self.completions
            .recv()
            .map_err(|_| io::Error::other("workspace completion channel disconnected"))
    }
}

pub(super) struct WorkspaceWorkerFactory<'a> {
    pub(super) workspace: &'a Workspace,
    pub(super) dart_binary: &'a str,
    pub(super) worker_executable: &'a str,
    pub(super) auto_worker_artifact: bool,
    pub(super) artifact: OnceLock<io::Result<WorkerArtifact>>,
    pub(super) phase_count: usize,
    pub(super) restrictions: BTreeMap<String, Vec<String>>,
    pub(super) retained_output_guard: bool,
    pub(super) visibility: &'a AssetVisibility,
}

#[derive(Default)]
pub(super) struct WorkspaceWorkerOutcome {
    pub(super) worker: Option<WorkerClient>,
    pub(super) starts: u64,
    pub(super) initializes: u64,
    pub(super) resets: u64,
}

/// Lazily starts a process on its first lease. Artifact compilation is shared
/// once across the whole session. Every error/panic reports a completion so
/// the controller never waits for a lease whose thread disappeared silently.
pub(super) fn run_worker(
    index: usize,
    factory: &WorkspaceWorkerFactory<'_>,
    leases: mpsc::Receiver<WorkspaceLease>,
    completions: mpsc::Sender<WorkspaceCompletion>,
) -> WorkspaceWorkerOutcome {
    let mut outcome = WorkspaceWorkerOutcome::default();
    let mut package = None;
    let mut baseline: Option<Weak<WorkspaceBaseline>> = None;
    while let Ok(lease) = leases.recv() {
        let mut elapsed = Duration::ZERO;
        let result = catch_unwind(AssertUnwindSafe(|| {
            if outcome.worker.is_none() {
                let artifact = factory
                    .artifact
                    .get_or_init(|| {
                        resolve_worker_artifact(
                            factory.workspace,
                            factory.dart_binary,
                            factory.worker_executable,
                            factory.auto_worker_artifact,
                        )
                    })
                    .as_ref()
                    .map_err(|error| io::Error::new(error.kind(), error.to_string()))?;
                outcome.worker = Some(WorkerClient::start(
                    &factory.workspace.root,
                    factory.dart_binary,
                    factory.worker_executable,
                    artifact,
                )?);
                outcome.starts += 1;
            }
            let worker = outcome.worker.as_mut().expect("started worker");
            let initializing = package.as_ref() != Some(&lease.package);
            if initializing {
                worker.initialize(
                    &factory.workspace.root,
                    &lease.package,
                    factory.phase_count,
                    false,
                    &factory.restrictions,
                    factory.retained_output_guard,
                )?;
                outcome.initializes += 1;
                package = Some(lease.package.clone());
                baseline = None;
            }
            let unchanged = baseline
                .as_ref()
                .and_then(Weak::upgrade)
                .is_some_and(|previous| Arc::ptr_eq(&previous, &lease.baseline));
            if !unchanged && !(initializing && lease.baseline.is_empty()) {
                let baseline = &lease.baseline;
                worker.reset_resolver(
                    &baseline.updated_sources,
                    &baseline.deleted_sources,
                    &baseline.updated_cache,
                    &baseline.deleted_cache,
                    true,
                    &baseline.blob.metadata,
                )?;
                outcome.resets += 1;
            }
            baseline = Some(Arc::downgrade(&lease.baseline));
            let started = Instant::now();
            let result = worker.build_batch(
                factory.workspace,
                &lease.requests[lease.range.clone()],
                &lease.baseline.overlay,
                &lease.baseline.deleted,
                factory.visibility,
            );
            elapsed = started.elapsed();
            result
        }))
        .unwrap_or_else(|_| Err(io::Error::other("workspace worker thread panicked")));
        let failed = result.is_err();
        let dep_graph = outcome
            .worker
            .as_mut()
            .map(|worker| std::mem::take(&mut worker.dep_graph))
            .unwrap_or_default();
        if completions
            .send(WorkspaceCompletion {
                worker: index,
                application: lease.application,
                range: lease.range,
                results: result,
                dep_graph,
                elapsed,
            })
            .is_err()
            || failed
        {
            break;
        }
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reuse_compares_visible_bytes_and_keeps_deletions_outside_the_phase_guard() {
        let visible = BTreeMap::from([(
            "app|lib/previous.dart".into(),
            Arc::<[u8]>::from(&b"old"[..]),
        )]);
        let deleted = BTreeSet::from(["app|lib/obsolete.dart".into()]);
        let hidden = BTreeSet::from(["app|lib/current.dart".into()]);
        let root = std::env::temp_dir().join(format!(
            "accelerator-baseline-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let baseline = WorkspaceBaseline {
            overlay: visible.clone(),
            deleted: deleted.clone(),
            updated_sources: Value::Null,
            deleted_sources: Value::Null,
            updated_cache: Value::Null,
            deleted_cache: Value::Null,
            blob: OverlayBlob::create(&root, &visible, &visible.keys().cloned().collect()).unwrap(),
        };
        let mut overlay = visible;
        overlay.insert(
            "app|lib/current.dart".into(),
            Arc::from(&b"hidden output"[..]),
        );
        let mut changes = deleted;
        changes.insert("app|lib/current.dart".into());
        assert!(baseline.matches(&overlay, &changes, &hidden));
        changes.insert("app|lib/new-deletion.dart".into());
        assert!(!baseline.matches(&overlay, &changes, &hidden));
        changes.remove("app|lib/new-deletion.dart");
        overlay.insert(
            "app|lib/previous.dart".into(),
            Arc::from(&b"changed visible output"[..]),
        );
        assert!(!baseline.matches(&overlay, &changes, &hidden));
        drop(baseline);
        std::fs::remove_dir_all(root).unwrap();
    }
}
