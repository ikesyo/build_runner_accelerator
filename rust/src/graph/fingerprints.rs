use super::GraphState;
use crate::protocol::ApiFingerprintRecord;
use crate::snapshot::Snapshot;
use std::collections::{BTreeMap, BTreeSet};

/// Runtime-only per-build API fingerprint report and conflict tracking
/// (ADR 0056). Never saved.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct FingerprintTracker {
    /// Assets whose fingerprint the current build reported, used by
    /// [`GraphState::update_assets`] to tell fresh evidence apart from
    /// records the previous build left. Runtime-only: never saved.
    reports: BTreeSet<String>,
    /// Assets whose fingerprint reports conflicted within the current
    /// build (learned from different bytes after a mid-build edit).
    /// Their evidence stays dropped until the next build boundary:
    /// no later report in the same build can resurrect it, because
    /// outputs may have been generated against either observation.
    /// Runtime-only: never saved.
    conflicts: BTreeSet<String>,
}

impl FingerprintTracker {
    fn merge(
        &mut self,
        fingerprints: &mut BTreeMap<String, ApiFingerprintRecord>,
        reported: BTreeMap<String, Option<ApiFingerprintRecord>>,
    ) {
        for (asset, record) in reported {
            if self.conflicts.contains(&asset) {
                fingerprints.remove(&asset);
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
                    if self.reports.contains(&asset) && fingerprints.get(&asset) != Some(&record) {
                        fingerprints.remove(&asset);
                        self.conflicts.insert(asset);
                        continue;
                    }
                    self.reports.insert(asset.clone());
                    fingerprints.insert(asset, record);
                }
                None => {
                    // An unavailable report after a recorded one in
                    // the same build is a disagreement too: the two
                    // observations cannot both describe the bytes the
                    // build's outputs were generated against, so the
                    // evidence stays dropped for the rest of the
                    // build instead of being resurrected by a later
                    // agreeing report.
                    if self.reports.contains(&asset) {
                        self.conflicts.insert(asset.clone());
                    }
                    fingerprints.remove(&asset);
                    self.reports.insert(asset);
                }
            }
        }
    }

    fn supersede(
        &mut self,
        fingerprints: &mut BTreeMap<String, ApiFingerprintRecord>,
        assets: &BTreeSet<String>,
    ) {
        for asset in assets {
            self.reports.remove(asset);
            self.conflicts.remove(asset);
            fingerprints.remove(asset);
        }
    }

    pub(super) fn end_build(
        &mut self,
        fingerprints: &mut BTreeMap<String, ApiFingerprintRecord>,
        previous: &Snapshot,
        next: &Snapshot,
    ) {
        // A recorded fingerprint describes the bytes it was learned
        // from. An asset whose snapshot entry changed or vanished
        // since the previous build drops its fingerprint here, at
        // the build boundary, so a build that never relearns it (for
        // example because only opted-out actions resolved it) cannot
        // leave evidence for superseded bytes behind. Fingerprints
        // reported during this build are fresh evidence and survive
        // even when their asset changed.
        if !fingerprints.is_empty() {
            let reported = &self.reports;
            fingerprints.retain(|asset, _| {
                (reported.contains(asset) && next.get(asset).is_some_and(|entry| entry.exists))
                    || match (previous.get(asset), next.get(asset)) {
                        (Some(old), Some(new)) => {
                            old.exists == new.exists && old.digest == new.digest
                        }
                        _ => false,
                    }
            });
        }
        self.reports.clear();
        self.conflicts.clear();
    }

    #[cfg(test)]
    pub(super) fn has_conflicts(&self) -> bool {
        !self.conflicts.is_empty()
    }
}

impl GraphState {
    /// Drops the recorded fingerprints of [assets], whose bytes a
    /// resolver reset is changing. Called by the frontend before
    /// post-reset actions dispatch, so a removal can never merge
    /// after a fingerprint relearned from the new bytes.
    pub fn drop_api_fingerprints(&mut self, assets: &BTreeSet<String>) {
        for asset in assets {
            self.asset_fingerprints.remove(asset);
        }
    }

    /// Merges API fingerprints reported by the workers (ADR 0056). A
    /// reported record replaces the recorded one; a reported
    /// unavailable marker removes the entry, so evidence recorded for
    /// an earlier content of the asset is never kept.
    pub fn merge_api_fingerprints(
        &mut self,
        reported: BTreeMap<String, Option<ApiFingerprintRecord>>,
    ) {
        self.fingerprint_tracker
            .merge(&mut self.asset_fingerprints, reported);
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
        self.fingerprint_tracker
            .supersede(&mut self.asset_fingerprints, assets);
    }
}
