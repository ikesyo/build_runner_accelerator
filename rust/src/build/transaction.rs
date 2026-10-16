use crate::builder::BuilderDefinition;
use crate::graph::{ActionState, GraphState};
use crate::plan::BuildSpec;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

/// Overlay mutations since the last resolver reset. A single-worker reset can
/// forward these deltas so the worker refreshes only those assets in its
/// Analyzer filesystem instead of re-walking every source.
#[derive(Default)]
pub(super) struct ResolverChanges {
    pub(super) resolver_updated: BTreeSet<String>,
    pub(super) resolver_deleted: BTreeSet<String>,
    pub(super) resolver_cache_updated: BTreeSet<String>,
    pub(super) resolver_cache_deleted: BTreeSet<String>,
}

impl ResolverChanges {
    /// Whether a resolver reset has any source or artifact-tree delta to apply.
    pub(super) fn has_changes(&self) -> bool {
        !self.resolver_updated.is_empty()
            || !self.resolver_deleted.is_empty()
            || !self.resolver_cache_updated.is_empty()
            || !self.resolver_cache_deleted.is_empty()
    }

    /// Clears deltas after a resolver reset or worker reinitialization consumes
    /// their baseline.
    pub(super) fn clear(&mut self) {
        self.resolver_updated.clear();
        self.resolver_deleted.clear();
        self.resolver_cache_updated.clear();
        self.resolver_cache_deleted.clear();
    }
}

/// In-memory output, deletion, graph, and resolver-reset state for one build
/// attempt. Staging changes here does not alter workspace files; callers must
/// reach `commit` only after every required action has succeeded.
pub(super) struct PendingTransaction {
    // Immutable output allocations are shared with pending_outputs (and lazy
    // results); deleting an overlay entry only releases that entry's reference.
    pub(super) overlay: BTreeMap<String, Arc<[u8]>>,
    pub(super) deleted_overlay: BTreeSet<String>,
    pub(super) pending_outputs: Vec<(Arc<BuilderDefinition>, String, Arc<[u8]>)>,
    pub(super) pending_deletions: Vec<(Arc<BuilderDefinition>, String)>,
    pub(super) pending_location_deletions: Vec<(crate::builder::BuildTo, String)>,
    pub(super) clean_artifact_tree: bool,
    pub(super) pending_actions: Vec<(String, ActionState)>,
    pub(super) pending_stock_inputs: BTreeMap<String, Option<Vec<String>>>,
    pub(super) pending_stock_globs: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    pub(super) deleted_actions: Vec<(String, ActionState)>,
    pub(super) resolver: ResolverChanges,
}

impl PendingTransaction {
    /// Seeds logical deletions from outputs of dirty and removed actions.
    /// This hides stale bytes during the attempt without deleting them from
    /// disk; current results and filesystem mutations are staged separately.
    pub(super) fn new(
        dirty: &[BuildSpec],
        state: &GraphState,
        deleted_actions: Vec<(String, ActionState)>,
    ) -> Self {
        let mut deleted_overlay = dirty
            .iter()
            .filter_map(|spec| state.actions.get(&spec.action_key()))
            .flat_map(|action| action.outputs.iter().cloned())
            .collect::<BTreeSet<_>>();
        for (_, action) in &deleted_actions {
            deleted_overlay.extend(action.outputs.iter().cloned());
        }
        Self {
            overlay: BTreeMap::new(),
            deleted_overlay,
            pending_outputs: Vec::new(),
            pending_deletions: Vec::new(),
            pending_location_deletions: Vec::new(),
            clean_artifact_tree: false,
            pending_actions: Vec::new(),
            pending_stock_inputs: BTreeMap::new(),
            pending_stock_globs: BTreeMap::new(),
            deleted_actions,
            resolver: ResolverChanges::default(),
        }
    }
}
