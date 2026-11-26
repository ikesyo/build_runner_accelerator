use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

#[derive(Clone)]
pub(super) enum PublishedOutput {
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
pub(super) struct ActionPublication {
    pub(super) outputs: BTreeMap<String, PublishedOutput>,
    pub(super) snapshots: BTreeMap<String, crate::snapshot::AssetSnapshot>,
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

pub(super) enum DemandClaim {
    Owner(ActionClaimGuard),
    Complete(ActionPublication),
}

pub(super) struct ActionClaimGuard {
    coordinator: FilteredDemandCoordinator,
    key: String,
    parent: Option<String>,
    worker: usize,
    settled: bool,
}

impl ActionClaimGuard {
    pub(super) fn complete(&mut self, publication: ActionPublication) {
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

    pub(super) fn fail(&mut self, error: impl Into<String>) {
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

    pub(super) fn claim(
        &self,
        key: &str,
        parent: Option<&str>,
        worker: usize,
    ) -> io::Result<DemandClaim> {
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

    pub(super) fn source_observation(&self, asset: &str) -> Option<FilteredSourceObservation> {
        self.lock().source_observations.get(asset).cloned()
    }

    pub(super) fn publish_source_observation(
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

pub(super) fn apply_published_output(
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
