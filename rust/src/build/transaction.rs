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
    pub(super) source_edits: BTreeMap<String, SourceEdit>,
    // Immutable output allocations are shared with pending_outputs (and lazy
    // results); deleting an overlay entry only releases that entry's reference.
    pub(super) overlay: BTreeMap<String, Arc<[u8]>>,
    pub(super) deleted_overlay: BTreeSet<String>,
    pub(super) pending_outputs: BTreeMap<String, PendingOutput>,
    pub(super) pending_deletions: Vec<(Arc<BuilderDefinition>, String)>,
    pub(super) pending_location_deletions: Vec<(crate::builder::BuildTo, String)>,
    pub(super) clean_artifact_tree: bool,
    pub(super) pending_actions: BTreeMap<String, ActionState>,
    pub(super) source_edit_evidence: BTreeMap<String, crate::shared_library::SourceEditEvidence>,
    pub(super) pending_stock_inputs: BTreeMap<String, Option<Vec<String>>>,
    pub(super) pending_stock_globs: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    pub(super) deleted_actions: Vec<(String, ActionState)>,
    pub(super) resolver: ResolverChanges,
}

/// Own the digest of the final staged bytes, shared by graph and publication.
pub(super) struct PendingOutput {
    pub(super) builder: Arc<BuilderDefinition>,
    pub(super) bytes: Arc<[u8]>,
    pub(super) digest: String,
}

impl PendingOutput {
    pub(super) fn new(builder: Arc<BuilderDefinition>, bytes: Arc<[u8]>) -> Self {
        let digest = crate::digest::digest_bytes(&bytes);
        Self {
            builder,
            bytes,
            digest,
        }
    }
}

pub(super) struct SourceEdit {
    pub(super) original: Arc<[u8]>,
    pub(super) updated: Arc<[u8]>,
}

impl PendingTransaction {
    pub(super) fn action<'a>(
        &'a self,
        key: &str,
        state: &'a GraphState,
    ) -> Option<&'a ActionState> {
        self.pending_actions
            .get(key)
            .or_else(|| state.actions.get(key))
    }

    /// An action result replaces its earlier staged outputs, including dynamic
    /// post-process outputs. Other actions' buffers remain untouched.
    pub(super) fn replace_action_outputs(&mut self, spec: &BuildSpec) {
        for asset in &spec.outputs {
            self.pending_outputs.remove(asset);
        }
        if let Some(previous) = self.pending_actions.get(&spec.action_key()) {
            for asset in &previous.outputs {
                self.pending_outputs.remove(asset);
                self.overlay.remove(asset);
                self.deleted_overlay.insert(asset.clone());
                if spec.instance.builder.build_to == crate::builder::BuildTo::Cache {
                    self.resolver.resolver_cache_updated.remove(asset);
                    self.resolver.resolver_cache_deleted.insert(asset.clone());
                } else {
                    self.resolver.resolver_updated.remove(asset);
                    self.resolver.resolver_deleted.insert(asset.clone());
                }
            }
        }
    }

    /// Check the observed source version and stage an edit with its original
    /// bytes retained for publication checks and undo recovery.
    pub(super) fn edit_source(
        &mut self,
        workspace: &crate::workspace::Workspace,
        asset: &str,
        original: &str,
        replacement: &str,
    ) -> std::io::Result<bool> {
        let current = self
            .overlay
            .get(asset)
            .cloned()
            .map(Ok)
            .unwrap_or_else(|| std::fs::read(workspace.path_for_asset(asset)?).map(Arc::from))?;
        if current.as_ref() != original.as_bytes() {
            return Err(std::io::Error::other(
                "shared-part source changed during the build; retry",
            ));
        }
        let bytes: Arc<[u8]> = Arc::from(replacement.as_bytes());
        if current == bytes {
            return Ok(false);
        }
        self.source_edits
            .entry(asset.to_owned())
            .and_modify(|edit| edit.updated = bytes.clone())
            .or_insert(SourceEdit {
                original: current,
                updated: bytes.clone(),
            });
        self.overlay.insert(asset.to_owned(), bytes);
        self.resolver.resolver_updated.insert(asset.to_owned());
        self.resolver.resolver_deleted.remove(asset);
        Ok(true)
    }

    /// Only invalidated lazy producers lose their staged output. Keep paths
    /// demandable; a logical deletion hint would suppress the producer RPC.
    pub(super) fn invalidate_optional_outputs(
        &mut self,
        specs: &[BuildSpec],
        keys: &BTreeSet<String>,
    ) {
        for spec in specs
            .iter()
            .filter(|spec| spec.instance.builder.is_optional && keys.contains(&spec.action_key()))
        {
            for output in &spec.outputs {
                self.pending_outputs.remove(output);
                self.overlay.remove(output);
                self.deleted_overlay.remove(output);
                if spec.instance.builder.build_to == crate::builder::BuildTo::Cache {
                    self.resolver.resolver_cache_updated.remove(output);
                    self.resolver.resolver_cache_deleted.insert(output.clone());
                } else {
                    self.resolver.resolver_updated.remove(output);
                    self.resolver.resolver_deleted.insert(output.clone());
                }
            }
        }
    }

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
            source_edits: BTreeMap::new(),
            overlay: BTreeMap::new(),
            deleted_overlay,
            pending_outputs: BTreeMap::new(),
            pending_deletions: Vec::new(),
            pending_location_deletions: Vec::new(),
            clean_artifact_tree: state.config_digest.is_empty(),
            pending_actions: BTreeMap::new(),
            source_edit_evidence: BTreeMap::new(),
            pending_stock_inputs: BTreeMap::new(),
            pending_stock_globs: BTreeMap::new(),
            deleted_actions,
            resolver: ResolverChanges::default(),
        }
    }
}
