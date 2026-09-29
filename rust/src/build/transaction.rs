use crate::builder::BuilderDefinition;
use crate::graph::{ActionState, GraphState};
use crate::plan::BuildSpec;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

#[derive(Default)]
pub(super) struct ResolverChanges {
    pub(super) resolver_updated: BTreeSet<String>,
    pub(super) resolver_deleted: BTreeSet<String>,
    pub(super) resolver_cache_updated: BTreeSet<String>,
    pub(super) resolver_cache_deleted: BTreeSet<String>,
}

pub(super) struct PendingTransaction {
    pub(super) overlay: BTreeMap<String, Vec<u8>>,
    pub(super) deleted_overlay: BTreeSet<String>,
    pub(super) pending_outputs: Vec<(Arc<BuilderDefinition>, String, Vec<u8>)>,
    pub(super) pending_deletions: Vec<(Arc<BuilderDefinition>, String)>,
    pub(super) pending_actions: Vec<(String, ActionState)>,
    pub(super) deleted_actions: Vec<(String, ActionState)>,
    pub(super) resolver: ResolverChanges,
}

impl PendingTransaction {
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
            pending_actions: Vec::new(),
            deleted_actions,
            resolver: ResolverChanges::default(),
        }
    }
}
