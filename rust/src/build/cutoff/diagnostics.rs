use std::collections::BTreeMap;

/// Per-builder counters behind the cutoff metrics output
/// (`BUILD_RUNNER_ACCELERATOR_METRICS=1`). They explain why an
/// opt-in did or did not pay off: how [`assess`] filtered the
/// opted-in actions, and how [`evaluate`] decided each candidate.
/// Counting never changes a decision.
#[derive(Debug, Default)]
pub(in crate::build) struct CutoffDiagnostics {
    /// Counting costs a map entry per opted-in action, so it only
    /// runs when the metrics output is on; `prepare_cutoff` sets
    /// this from the same flag that gates printing.
    pub(in crate::build) enabled: bool,
    pub(in crate::build) assess: BTreeMap<String, AssessCounts>,
    pub(in crate::build) evaluate: BTreeMap<String, EvaluateCounts>,
    pub(in crate::build) changed_units: usize,
    pub(in crate::build) generated_assets: usize,
    pub(in crate::build) query_units: usize,
    /// Set when assess proved every candidate blocked from the
    /// recorded graph alone, so `prepare_cutoff` prints the
    /// evaluate counters even though no preflight ran.
    pub(in crate::build) preflight_skipped: bool,
}

#[derive(Debug, Default)]
pub(in crate::build) struct AssessCounts {
    pub(in crate::build) candidates: usize,
    pub(in crate::build) no_recorded_action: usize,
    pub(in crate::build) ast_or_content_read: usize,
    pub(in crate::build) own_input_or_direct_read_changed: usize,
    pub(in crate::build) no_resolver_observation: usize,
    pub(in crate::build) not_reached_by_change: usize,
    pub(in crate::build) no_roots: usize,
    /// Candidates dropped before evaluation because no unit in
    /// their changed closures could be queried: a generated unit
    /// changed, or the changed units are absent from the current
    /// snapshot. Split by which of the two applies.
    pub(in crate::build) no_query_generated_asset: usize,
    pub(in crate::build) no_query_deleted_or_appeared: usize,
}

#[derive(Debug, Default)]
pub(in crate::build) struct EvaluateCounts {
    /// The signature proof passed. Dirty planning can still run
    /// the action for reasons outside the resolver observations
    /// (a changed glob, a missing output), so this counts proven
    /// unchanged signatures, not final skips.
    pub(in crate::build) signature_unchanged: usize,
    pub(in crate::build) generated_asset: usize,
    pub(in crate::build) deleted_or_appeared: usize,
    pub(in crate::build) unanswered_unit: usize,
    pub(in crate::build) missing_evidence: usize,
    pub(in crate::build) signature_changed: usize,
}

impl CutoffDiagnostics {
    /// The assessment counters print before the fallible worker
    /// preflight starts, so a failed query still leaves them in
    /// the output; the evaluation counters print after evaluation.
    pub(in crate::build) fn print_assess(&self) {
        // The evaluate lines that follow a skipped preflight are
        // recorded-graph attributions, not evaluation outcomes (a
        // candidate blocked by a deleted unit on the recorded
        // graph might have reached a generated unit through a
        // refreshed edge), so the header marks them as such.
        if self.preflight_skipped {
            eprintln!(
                "Rust cutoff metrics: changed_units={} generated_assets={} query_units={} preflight_skipped=1",
                self.changed_units, self.generated_assets, self.query_units,
            );
        } else {
            eprintln!(
                "Rust cutoff metrics: changed_units={} generated_assets={} query_units={}",
                self.changed_units, self.generated_assets, self.query_units,
            );
        }
        for (builder, counts) in &self.assess {
            eprintln!(
                "Rust cutoff metrics: stage=assess builder={builder} candidates={} no_recorded_action={} ast_or_content_read={} own_input_or_direct_read_changed={} no_resolver_observation={} not_reached_by_change={} no_roots={} no_query_generated_asset={} no_query_deleted_or_appeared={}",
                counts.candidates,
                counts.no_recorded_action,
                counts.ast_or_content_read,
                counts.own_input_or_direct_read_changed,
                counts.no_resolver_observation,
                counts.not_reached_by_change,
                counts.no_roots,
                counts.no_query_generated_asset,
                counts.no_query_deleted_or_appeared,
            );
        }
    }

    pub(in crate::build) fn print_evaluate(&self) {
        for (builder, counts) in &self.evaluate {
            eprintln!(
                "Rust cutoff metrics: stage=evaluate builder={builder} signature_unchanged={} generated_asset={} deleted_or_appeared={} unanswered_unit={} missing_evidence={} signature_changed={}",
                counts.signature_unchanged,
                counts.generated_asset,
                counts.deleted_or_appeared,
                counts.unanswered_unit,
                counts.missing_evidence,
                counts.signature_changed,
            );
        }
    }
}
