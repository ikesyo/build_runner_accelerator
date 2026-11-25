mod codec;
mod dirty_context;

pub use dirty_context::DirtyContext;

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
    /// Assets whose fingerprint the current build reported, used by
    /// [`GraphState::update_assets`] to tell fresh evidence apart from
    /// records the previous build left. Runtime-only: never saved.
    pub api_fingerprint_reports: BTreeSet<String>,
    /// Assets whose fingerprint reports conflicted within the current
    /// build (learned from different bytes after a mid-build edit).
    /// Their evidence stays dropped until the next build boundary:
    /// no later report in the same build can resurrect it, because
    /// outputs may have been generated against either observation.
    /// Runtime-only: never saved.
    pub api_fingerprint_conflicts: BTreeSet<String>,
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

    /// Merges API fingerprints reported by the workers (ADR 0056). A
    /// reported record replaces the recorded one; a reported
    /// unavailable marker removes the entry, so evidence recorded for
    /// an earlier content of the asset is never kept.
    /// Drops the recorded fingerprints of [assets], whose bytes a
    /// resolver reset is changing. Called by the frontend before
    /// post-reset actions dispatch, so a removal can never merge
    /// after a fingerprint relearned from the new bytes.
    pub fn drop_api_fingerprints(&mut self, assets: &BTreeSet<String>) {
        for asset in assets {
            self.asset_fingerprints.remove(asset);
        }
    }

    pub fn merge_api_fingerprints(
        &mut self,
        reported: BTreeMap<String, Option<crate::protocol::ApiFingerprintRecord>>,
    ) {
        for (asset, record) in reported {
            if self.api_fingerprint_conflicts.contains(&asset) {
                self.asset_fingerprints.remove(&asset);
                continue;
            }
            match record {
                Some(record) => {
                    // A second, different report for the same asset in
                    // one build means the build observed two versions
                    // of its bytes (a mid-build edit): outputs may
                    // have been generated against either fingerprint,
                    // so the evidence is dropped for the rest of the
                    // build rather than letting the later report win.
                    if self.api_fingerprint_reports.contains(&asset)
                        && self.asset_fingerprints.get(&asset) != Some(&record)
                    {
                        self.asset_fingerprints.remove(&asset);
                        self.api_fingerprint_conflicts.insert(asset);
                        continue;
                    }
                    self.api_fingerprint_reports.insert(asset.clone());
                    self.asset_fingerprints.insert(asset, record);
                }
                None => {
                    // An unavailable report after a recorded one in
                    // the same build is a disagreement too: the two
                    // observations cannot both describe the bytes the
                    // build's outputs were generated against, so the
                    // evidence stays dropped for the rest of the
                    // build instead of being resurrected by a later
                    // agreeing report.
                    if self.api_fingerprint_reports.contains(&asset) {
                        self.api_fingerprint_conflicts.insert(asset.clone());
                    }
                    self.asset_fingerprints.remove(&asset);
                    self.api_fingerprint_reports.insert(asset);
                }
            }
        }
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
        // A recorded fingerprint describes the bytes it was learned
        // from. An asset whose snapshot entry changed or vanished
        // since the previous build drops its fingerprint here, at
        // the build boundary, so a build that never relearns it (for
        // example because only opted-out actions resolved it) cannot
        // leave evidence for superseded bytes behind. Fingerprints
        // reported during this build are fresh evidence and survive
        // even when their asset changed.
        if !self.asset_fingerprints.is_empty() {
            let reported = &self.api_fingerprint_reports;
            self.asset_fingerprints.retain(|asset, _| {
                (reported.contains(asset) && snapshot.get(asset).is_some_and(|entry| entry.exists))
                    || match (self.assets.get(asset), snapshot.get(asset)) {
                        (Some(old), Some(new)) => {
                            old.exists == new.exists && old.digest == new.digest
                        }
                        _ => false,
                    }
            });
        }
        self.api_fingerprint_reports.clear();
        self.api_fingerprint_conflicts.clear();
        self.assets = snapshot;
    }

    /// Drops the fingerprints reported this build for assets whose
    /// bytes the build's transaction changed after a walk could have
    /// fingerprinted them (an output written or deleted later in the
    /// build, a source edit published at commit). A report cannot say
    /// which in-build version of the bytes it describes, and the
    /// previous-vs-final comparison in [`GraphState::update_assets`]
    /// cannot detect every stale value (a transaction that restores
    /// the previous bytes leaves the two snapshots equal), so the
    /// values are removed outright rather than only losing their
    /// fresh-evidence exemption.
    pub fn supersede_api_fingerprint_reports(&mut self, assets: &BTreeSet<String>) {
        for asset in assets {
            self.api_fingerprint_reports.remove(asset);
            self.api_fingerprint_conflicts.remove(asset);
            self.asset_fingerprints.remove(asset);
        }
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
