mod codec;
mod dirty_context;
mod fingerprints;

pub use dirty_context::DirtyContext;
use fingerprints::FingerprintTracker;

use crate::protocol::GlobRead;
use crate::snapshot::Snapshot;
use std::collections::{BTreeMap, BTreeSet};

pub const GRAPH_SCHEMA_VERSION: u32 = 10;

/// Persisted observations for one builder action, used to decide reuse and
/// retain the actual output set from its last successful execution.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ActionState {
    pub shared_part: Option<crate::shared_library::SharedContribution>,
    pub builder: String,
    pub input: String,
    pub reads: Vec<String>,
    pub resolver_reads: Vec<String>,
    /// Libraries the action touched as source text through the
    /// resolver (ADR 0056): actions with a non-empty split observe
    /// more than the API fingerprint covers, so later stages key
    /// their resolver reads by content instead of by signature.
    pub resolver_content_reads: Vec<String>,
    /// Entrypoints the action passed to the resolver. Dependency edges are
    /// expanded through [`GraphState::resolver_dep_graph`] at dirty-check
    /// time, mirroring stock build_runner's `previousLibraryCycleGraphLoader`.
    pub resolver_entrypoints: Vec<String>,
    pub glob_reads: Vec<GlobRead>,
    pub outputs: Vec<String>,
    pub output_digests: BTreeMap<String, String>,
    pub status: String,
}

/// Incremental evidence committed after a successful build. In particular,
/// `output_locations` records where outputs were actually written, rather than
/// guessing from whichever path currently exists.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GraphState {
    pub schema_version: u32,
    pub config_digest: String,
    /// Whether the last successful build applied output filters.
    pub was_filtered: bool,
    pub assets: Snapshot,
    pub actions: BTreeMap<String, ActionState>,
    /// Direct dependency edges the Dart resolver loader has observed.
    /// Actions that resolve an already-loaded library cycle observe no new
    /// IO, so their dependency edges cannot be recovered from reads alone.
    pub resolver_dep_graph: BTreeMap<String, Vec<String>>,
    /// API fingerprints of source units, learned by the workers' dep
    /// walks (ADR 0056), each bound to the content digest that
    /// produced it. Absence means no evidence: later stages treat
    /// such units as content-keyed.
    pub asset_fingerprints: BTreeMap<String, crate::protocol::ApiFingerprintRecord>,
    /// Runtime-only per-build API fingerprint report and conflict tracking;
    /// never saved.
    pub(crate) fingerprint_tracker: FingerprintTracker,
    /// Actual output location at the successful commit (true means cache).
    pub output_locations: BTreeMap<String, bool>,
    /// Stock InputTracker input order, distinct from broader observed reads.
    pub stock_input_order: BTreeMap<String, Vec<String>>,
    /// Actual glob results by action and glob, preserving source/generated order.
    pub stock_glob_members: BTreeMap<String, BTreeMap<String, Vec<String>>>,
    /// Source-path generated files excluded from plain sources in this watch.
    pub watch_generated_sources: BTreeSet<String>,
    /// A keep build can leave consumers generated from retained manual bytes.
    /// Subsequent overwrite builds must keep using demand evaluation, even
    /// after upstream files are repaired: equal logical producer bytes must
    /// not cause those legitimate consumers to rerun through eager invalidation.
    pub retained_output_state: bool,
}

impl GraphState {
    /// Reports a cycle in the recorded resolver dependency edges.
    /// Missing leaf nodes are included as ordinary vertices; the check is
    /// based on recorded resolver evidence, not action-graph dependencies.
    pub(crate) fn has_resolver_cycle(&self) -> bool {
        let mut degrees = BTreeMap::new();
        for (asset, edges) in &self.resolver_dep_graph {
            degrees.entry(asset.as_str()).or_insert(0usize);
            for edge in edges {
                *degrees.entry(edge.as_str()).or_insert(0) += 1;
            }
        }
        let mut ready: Vec<_> = degrees
            .iter()
            .filter(|(_, degree)| **degree == 0)
            .map(|(asset, _)| *asset)
            .collect();
        let mut processed = 0;
        while let Some(asset) = ready.pop() {
            processed += 1;
            if let Some(edges) = self.resolver_dep_graph.get(asset) {
                for edge in edges {
                    let degree = degrees.get_mut(edge.as_str()).expect("edge was indexed");
                    *degree -= 1;
                    if *degree == 0 {
                        ready.push(edge.as_str());
                    }
                }
            }
        }
        processed != degrees.len()
    }

    /// Updates compatibility metadata and the filesystem snapshot together.
    /// Returns true exactly when the persisted graph now needs a save.
    pub fn update_metadata_if_changed(&mut self, config_digest: &str, snapshot: Snapshot) -> bool {
        let changed = self.schema_version != GRAPH_SCHEMA_VERSION
            || self.config_digest != config_digest
            || self.assets != snapshot;
        if changed {
            self.schema_version = GRAPH_SCHEMA_VERSION;
            self.config_digest = config_digest.to_owned();
            self.update_assets(snapshot);
        }
        changed
    }

    pub fn update_assets(&mut self, snapshot: Snapshot) {
        self.fingerprint_tracker
            .end_build(&mut self.asset_fingerprints, &self.assets, &snapshot);
        self.assets = snapshot;
    }

    /// Whether this graph's schema and builder configuration match the plan.
    /// A false result means prior action/output evidence cannot authorize reuse.
    pub fn is_compatible(&self, config_digest: &str) -> bool {
        self.schema_version == GRAPH_SCHEMA_VERSION && self.config_digest == config_digest
    }
}

#[cfg(test)]
mod bench;

#[cfg(test)]
mod tests;
