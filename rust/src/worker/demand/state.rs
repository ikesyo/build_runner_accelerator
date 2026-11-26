use super::coordinator::{
    ActionClaimGuard, ActionPublication, FilteredDemandCoordinator, FilteredSourceObservation,
    PublishedOutput, apply_published_output,
};
use crate::plan::BuildSpec;
use crate::protocol::BuildResult;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::sync::Arc;

/// A successful optional action that was requested while another action was
/// suspended in the resident Dart worker. The build frontend commits these
/// results together with the outer transaction.
pub struct LazyBuildResult {
    pub spec: BuildSpec,
    pub result: BuildResult,
}

#[derive(Clone)]
pub(super) struct FilteredWorkerContext {
    pub(super) coordinator: FilteredDemandCoordinator,
    pub(super) worker: usize,
}

pub(super) struct FilteredDemandState {
    pub(super) previous: Arc<crate::graph::GraphState>,
    pub(super) snapshot: Arc<crate::snapshot::Snapshot>,
    pub(super) snapshot_delta: BTreeMap<String, crate::snapshot::AssetSnapshot>,
    unconfirmed_outputs: BTreeSet<String>,
    pub(super) dirty_keys: BTreeSet<String>,
    pub(super) probe_root_dirty: bool,
    pub(super) compatible: bool,
    pub(super) keep_modified_outputs: bool,
    pub(super) worker: Option<FilteredWorkerContext>,
}

impl FilteredDemandState {
    pub(super) fn coordinator(&self) -> Option<&FilteredDemandCoordinator> {
        self.worker.as_ref().map(|context| &context.coordinator)
    }

    pub(super) fn for_worker(&self, worker: usize, coordinator: FilteredDemandCoordinator) -> Self {
        Self {
            previous: Arc::clone(&self.previous),
            snapshot: Arc::clone(&self.snapshot),
            snapshot_delta: self.snapshot_delta.clone(),
            // Probe-only dirtiness is resolved again by actual worker reads;
            // carrying it into execution would invalidate equal rebuilt bytes.
            unconfirmed_outputs: BTreeSet::new(),
            dirty_keys: BTreeSet::new(),
            probe_root_dirty: false,
            compatible: self.compatible,
            keep_modified_outputs: self.keep_modified_outputs,
            worker: Some(FilteredWorkerContext {
                coordinator,
                worker,
            }),
        }
    }
}

/// State shared by optional builds and filtered normal demand in one transaction.
/// Filtered demand workers share immutable action publications and retain
/// worker-local RPC stacks and mutable transaction views.
pub struct LazyBuildState {
    pub(super) force_keys: BTreeSet<String>,
    pub(super) built_keys: BTreeSet<String>,
    pub(super) building_keys: BTreeSet<String>,
    pub(super) building_stack: Vec<String>,
    pub(super) results: Vec<LazyBuildResult>,
    failed_demand: Option<String>,
    pub(super) demanded_keys: BTreeSet<String>,
    pub(super) filtered: Option<FilteredDemandState>,
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

    /// Source-overlay replay invalidates only affected optional producers.
    /// Unaffected demand results remain reusable within the transaction.
    pub(crate) fn invalidate_optional(&mut self, keys: &BTreeSet<String>) {
        self.force_keys.extend(keys.iter().cloned());
        self.built_keys.retain(|key| !keys.contains(key));
        self.demanded_keys.retain(|key| !keys.contains(key));
    }

    pub fn new(force_keys: BTreeSet<String>) -> Self {
        Self {
            force_keys,
            built_keys: BTreeSet::new(),
            building_keys: BTreeSet::new(),
            building_stack: Vec::new(),
            results: Vec::new(),
            failed_demand: None,
            demanded_keys: BTreeSet::new(),
            filtered: None,
        }
    }

    pub(crate) fn filtered(
        previous: crate::graph::GraphState,
        current: crate::snapshot::Snapshot,
        compatible: bool,
        keep_modified_outputs: bool,
    ) -> Self {
        Self {
            force_keys: BTreeSet::new(),
            built_keys: BTreeSet::new(),
            building_keys: BTreeSet::new(),
            building_stack: Vec::new(),
            results: Vec::new(),
            failed_demand: None,
            demanded_keys: BTreeSet::new(),
            filtered: Some(FilteredDemandState {
                previous: Arc::new(previous),
                snapshot: Arc::new(current),
                snapshot_delta: BTreeMap::new(),
                unconfirmed_outputs: BTreeSet::new(),
                dirty_keys: BTreeSet::new(),
                probe_root_dirty: false,
                compatible,
                keep_modified_outputs,
                worker: None,
            }),
        }
    }

    pub(super) fn is_filtered(&self) -> bool {
        self.filtered.is_some()
    }

    pub(super) fn filtered_state(&self) -> Option<&FilteredDemandState> {
        self.filtered.as_ref()
    }

    pub(super) fn filtered_mut(&mut self) -> Option<&mut FilteredDemandState> {
        self.filtered.as_mut()
    }

    pub(super) fn coordinator(&self) -> Option<FilteredDemandCoordinator> {
        self.filtered
            .as_ref()
            .and_then(|filtered| filtered.coordinator().cloned())
    }

    pub(super) fn asset_changed(&self, asset: &str) -> bool {
        let Some(filtered) = &self.filtered else {
            return false;
        };
        if filtered.unconfirmed_outputs.contains(asset) {
            return true;
        }
        let current = filtered
            .snapshot_delta
            .get(asset)
            .or_else(|| filtered.snapshot.get(asset));
        let previous = filtered.previous.assets.get(asset);
        match (previous, current) {
            (Some(previous), Some(current)) => {
                previous.exists != current.exists || previous.digest != current.digest
            }
            (None, None) => false,
            _ => true,
        }
    }

    pub(in crate::worker) fn is_untracked_filtered_source(
        &self,
        asset: &str,
        lazy_specs: &BTreeMap<String, BuildSpec>,
    ) -> bool {
        let Some(filtered) = &self.filtered else {
            return false;
        };
        if filtered.snapshot.contains_key(asset) || lazy_specs.contains_key(asset) {
            return false;
        }
        let previous = &filtered.previous;
        !previous.output_locations.contains_key(asset)
            && !previous.watch_generated_sources.contains(asset)
            && !previous
                .actions
                .values()
                .any(|action| action.outputs.iter().any(|output| output == asset))
    }

    pub(in crate::worker) fn shared_source_observation(
        &self,
        asset: &str,
    ) -> Option<FilteredSourceObservation> {
        self.filtered
            .as_ref()?
            .coordinator()?
            .source_observation(asset)
    }

    pub(in crate::worker) fn publish_source_observation(
        &mut self,
        asset: &str,
        observed: FilteredSourceObservation,
    ) -> FilteredSourceObservation {
        let Some(filtered) = &mut self.filtered else {
            return observed;
        };
        let published = if let Some(coordinator) = filtered.coordinator() {
            coordinator.publish_source_observation(asset, observed)
        } else {
            observed
        };
        filtered
            .snapshot_delta
            .insert(asset.to_owned(), published.snapshot.clone());
        published
    }

    pub(crate) fn filtered_snapshot_delta(
        &self,
    ) -> &BTreeMap<String, crate::snapshot::AssetSnapshot> {
        static EMPTY: BTreeMap<String, crate::snapshot::AssetSnapshot> = BTreeMap::new();
        self.filtered
            .as_ref()
            .map_or(&EMPTY, |filtered| &filtered.snapshot_delta)
    }

    pub(super) fn update_outputs(
        &mut self,
        spec: &BuildSpec,
        overlay: &BTreeMap<String, Arc<[u8]>>,
        deleted: &BTreeSet<String>,
    ) {
        let Some(filtered) = &mut self.filtered else {
            return;
        };
        for output in &spec.outputs {
            filtered.unconfirmed_outputs.remove(output);
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
                filtered.snapshot_delta.insert(output.clone(), entry);
            }
        }
    }

    pub(crate) fn worker_state(
        &self,
        worker: usize,
        coordinator: FilteredDemandCoordinator,
    ) -> Self {
        let filtered = self
            .filtered
            .as_ref()
            .expect("worker_state requires filtered LazyBuildState")
            .for_worker(worker, coordinator);
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
            demanded_keys: self.demanded_keys.clone(),
            filtered: Some(filtered),
        }
    }

    pub(crate) fn merge_worker_state(&mut self, mut worker: Self) {
        self.built_keys.append(&mut worker.built_keys);
        self.demanded_keys.append(&mut worker.demanded_keys);
        if let (Some(dst), Some(src)) = (&mut self.filtered, worker.filtered.as_mut()) {
            dst.snapshot_delta.append(&mut src.snapshot_delta);
            dst.unconfirmed_outputs.append(&mut src.unconfirmed_outputs);
            dst.dirty_keys.append(&mut src.dirty_keys);
        }
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
        let snapshots = self
            .filtered
            .as_ref()
            .map(|filtered| {
                spec.outputs
                    .iter()
                    .filter_map(|output| {
                        filtered
                            .snapshot_delta
                            .get(output)
                            .map(|snapshot| (output.clone(), snapshot.clone()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        ActionPublication { outputs, snapshots }
    }

    pub(super) fn apply_publication(
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
        if let Some(filtered) = &mut self.filtered {
            filtered
                .snapshot_delta
                .extend(publication.snapshots.clone());
        }
        let key = spec.action_key();
        self.demanded_keys.insert(key.clone());
        self.built_keys.insert(key);
    }

    pub(super) fn complete_action(
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

    pub(super) fn record_demand_failure(&mut self, error: &io::Error) {
        if let Some(filtered) = &self.filtered {
            self.failed_demand.get_or_insert_with(|| error.to_string());
            if let Some(coordinator) = filtered.coordinator() {
                coordinator.fail_worker(error.to_string());
            }
        }
    }

    pub(super) fn mark_filtered_dirty(&mut self, spec: &BuildSpec) {
        if let Some(filtered) = &mut self.filtered {
            filtered.dirty_keys.insert(spec.action_key());
            filtered
                .unconfirmed_outputs
                .extend(spec.outputs.iter().cloned());
            filtered.probe_root_dirty = true;
        }
    }

    pub(crate) fn failed_demand(&self) -> Option<&str> {
        self.failed_demand.as_deref()
    }

    pub fn take_results(&mut self) -> Vec<LazyBuildResult> {
        std::mem::take(&mut self.results)
    }
}

#[cfg(test)]
mod tests {
    use super::super::coordinator::FilteredSourceContent;
    use super::*;

    #[test]
    fn source_observations_are_shared_across_workers_and_committed_consistently() {
        let coordinator = FilteredDemandCoordinator::default();
        let mut merged = LazyBuildState::filtered(
            crate::graph::GraphState::default(),
            BTreeMap::new(),
            false,
            false,
        );
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
            merged.filtered_snapshot_delta().get(asset),
            Some(&first_snapshot)
        );
    }
}
