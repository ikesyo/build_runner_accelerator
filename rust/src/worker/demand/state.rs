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
    pub(super) filtered_previous: Option<Arc<crate::graph::GraphState>>,
    pub(super) demanded_keys: BTreeSet<String>,
    pub(super) filtered_snapshot: Arc<crate::snapshot::Snapshot>,
    pub(super) filtered_snapshot_delta: BTreeMap<String, crate::snapshot::AssetSnapshot>,
    filtered_unconfirmed_outputs: BTreeSet<String>,
    pub(super) filtered_dirty_keys: BTreeSet<String>,
    pub(super) filtered_probe_root_dirty: bool,
    pub(super) filtered_compatible: bool,
    pub(crate) keep_modified_outputs: bool,
    pub(super) filtered_coordinator: Option<FilteredDemandCoordinator>,
    pub(super) filtered_worker: usize,
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

    pub(super) fn asset_changed(&self, asset: &str) -> bool {
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

    pub(in crate::worker) fn is_untracked_filtered_source(
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

    pub(in crate::worker) fn shared_source_observation(
        &self,
        asset: &str,
    ) -> Option<FilteredSourceObservation> {
        self.filtered_coordinator
            .as_ref()?
            .source_observation(asset)
    }

    pub(in crate::worker) fn publish_source_observation(
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

    pub(super) fn update_outputs(
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
        self.filtered_snapshot_delta
            .extend(publication.snapshots.clone());
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
        if self.filtered_previous.is_some() {
            self.failed_demand.get_or_insert_with(|| error.to_string());
        }
        if let Some(coordinator) = &self.filtered_coordinator {
            coordinator.fail_worker(error.to_string());
        }
    }

    pub(super) fn mark_filtered_dirty(&mut self, spec: &BuildSpec) {
        self.filtered_dirty_keys.insert(spec.action_key());
        self.filtered_unconfirmed_outputs
            .extend(spec.outputs.iter().cloned());
        self.filtered_probe_root_dirty = true;
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
}
