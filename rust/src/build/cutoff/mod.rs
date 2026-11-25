//! ADR 0056 stage 4: preflight assessment and effective-signature
//! comparison for API-signature early cutoff.
//!
//! When source files changed, [`assess`] finds the opted-in actions
//! whose recorded resolver observations reach the changes. Only those
//! actions can be waived, and only when a worker preflight supplies
//! the changed units' current fingerprints and directive edges:
//! [`evaluate`] then folds effective signatures over the resolver dep
//! graph (SCC-collapsed, seeded with the build's config digest) for
//! the recorded graph and for the refreshed graph, and an action is
//! clean exactly when every root fold matches and none of its
//! resolver content reads changed. Any missing evidence (no recorded
//! fingerprint, a recorded fingerprint not bound to the previous
//! snapshot's bytes, an unavailable unit, a deleted or newly appeared
//! asset in the closure, or a generated asset whose producer cannot
//! be proven stable) leaves the action content-keyed.

mod diagnostics;
mod fold;
mod stability;

pub(super) use diagnostics::{AssessCounts, CutoffDiagnostics, EvaluateCounts};
#[cfg(test)]
use fold::fold_all;
use fold::{
    FingerprintView, GraphView, bound_fingerprints, fold_map, forward_closure,
    reverse_reachable_sets,
};
use stability::{StabilityInputs, unstable_generated_assets};

use crate::digest::bare_digest;
use crate::graph::{DirtyContext, GraphState};
use crate::plan::BuildSpec;
use crate::protocol::ApiFingerprintRecord;
use crate::snapshot::Snapshot;
use crate::worker::ApiUnitEvidence;
use std::collections::{BTreeMap, BTreeSet};

/// The outcome of a stage 4 preflight: the actions whose resolver
/// observations are proven unchanged, plus the fingerprints the
/// preflight learned, to merge into the graph with the build's save.
pub(super) struct CutoffEvidence {
    pub(super) clean_actions: BTreeSet<String>,
    pub(super) learned: BTreeMap<String, Option<ApiFingerprintRecord>>,
}

/// A preflight plan: the units to ask a worker about, and the
/// candidate actions to evaluate with the answers.
pub(super) struct Assessment {
    /// (asset, current content digest) pairs for the fingerprint query.
    pub(super) query: Vec<(String, String)>,
    /// Package of the first candidate spec, for pool initialization.
    pub(super) first_package: String,
    candidates: Vec<Candidate>,
    /// Changed assets that no longer exist as sources.
    deleted: BTreeSet<String>,
    /// Changed assets that did not exist in the previous snapshot.
    /// A restored or newly appeared unit is existence-changed, not
    /// API-changed: the recorded output may have been produced while
    /// it was missing, which fingerprint evidence cannot rule out.
    appeared: BTreeSet<String>,
    /// Generated assets in the candidates' recorded closures whose
    /// recorded fingerprint cannot stand in for the bytes the
    /// resolver will read in this build (see
    /// [`unstable_generated_assets`]). Stable generated assets fold
    /// with their recorded fingerprint like source units.
    unstable_generated: BTreeSet<String>,
    /// Forward closure of the candidates' roots over the recorded
    /// graph, computed once by [`assess`] and reused by [`evaluate`]
    /// for the old view.
    recorded_closure: BTreeSet<String>,
}

struct Candidate {
    key: String,
    /// Builder definition id, for diagnostics attribution.
    builder: String,
    /// Resolver observation roots: entrypoints plus direct resolver
    /// reads. The action's effective signature is the fold of these.
    roots: Vec<String>,
}

/// Finds the opted-in actions a preflight could waive. Returns `None`
/// when no changed source reaches any opted-in action's recorded
/// resolver observations, and when the recorded graph alone proves
/// every candidate blocked by a generated or deleted/appeared unit;
/// in both cases planning proceeds exactly as without cutoff and
/// no worker is started for classification.
pub(super) fn assess(
    state: &GraphState,
    specs: &[BuildSpec],
    context: &DirtyContext<'_>,
    current_snapshot: &Snapshot,
    generated: &BTreeSet<String>,
    diagnostics: &mut CutoffDiagnostics,
) -> Option<Assessment> {
    let changed = context.changed();
    diagnostics.changed_units = changed.len();
    diagnostics.generated_assets = generated.len();
    if changed.is_empty() || state.actions.is_empty() {
        return None;
    }
    let tainted = context.tainted();
    let changed_set: BTreeSet<&str> = changed.iter().copied().collect();
    let recorded = GraphView {
        base: &state.resolver_dep_graph,
        overrides: None,
    };
    let mut candidates = Vec::new();
    // Counts land in this scratch entry when diagnostics are off,
    // so the disabled path pays no builder-id clone or map entry.
    let mut scratch_counts: AssessCounts;
    let mut query: BTreeMap<String, String> = BTreeMap::new();
    let mut first_package = None;
    for spec in specs {
        if !spec.instance.api_cutoff {
            continue;
        }
        let counts = if diagnostics.enabled {
            diagnostics
                .assess
                .entry(spec.instance.builder.id.clone())
                .or_default()
        } else {
            scratch_counts = AssessCounts::default();
            &mut scratch_counts
        };
        let key = spec.action_key();
        let Some(action) = state.actions.get(&key) else {
            counts.no_recorded_action += 1;
            continue;
        };
        // Recorded AST access to a non-primary library breaks the
        // observation contract for the whole action (ADR 0056): the
        // safety net downgrades the action's recorded reads to
        // content-keyed, not just the accessed asset's, so such
        // actions are never candidates.
        if !action.resolver_content_reads.is_empty() {
            counts.ast_or_content_read += 1;
            continue;
        }
        // An action whose primary input or direct reads changed is
        // dirty on its direct terms no matter what the signatures
        // say, so preflight evidence could never waive it; do not
        // spend a query on it. (Reads recorded before the read split
        // hold the union and exclude more, which is the safe side.)
        if changed.contains(action.input.as_str())
            || action
                .reads
                .iter()
                .any(|asset| changed.contains(asset.as_str()))
        {
            counts.own_input_or_direct_read_changed += 1;
            continue;
        }
        if action.resolver_entrypoints.is_empty() && action.resolver_reads.is_empty() {
            counts.no_resolver_observation += 1;
            continue;
        }
        let reaches = action
            .resolver_reads
            .iter()
            .any(|asset| changed.contains(asset.as_str()))
            || action
                .resolver_entrypoints
                .iter()
                .any(|entrypoint| tainted.contains(entrypoint.as_str()));
        if !reaches {
            counts.not_reached_by_change += 1;
            continue;
        }
        // Signature roots are the action's resolver observations:
        // its entrypoints plus the recorded resolver reads that are
        // not also direct reads. The recorded resolver_reads keep
        // the legacy union (direct reads included) for the dirty
        // predicate, but a direct-only read must not become a fold
        // root: a non-Dart config file has no fingerprint, so folding
        // it in would block every waiver for the action. Direct
        // reads stay content-keyed through the direct channel (and
        // changed ones already excluded the action above).
        let direct: BTreeSet<&str> = action.reads.iter().map(String::as_str).collect();
        let roots: Vec<String> = action
            .resolver_entrypoints
            .iter()
            .cloned()
            .chain(
                action
                    .resolver_reads
                    .iter()
                    .filter(|asset| !direct.contains(asset.as_str()))
                    .cloned(),
            )
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        if roots.is_empty() {
            counts.no_roots += 1;
            continue;
        }
        if first_package.is_none() {
            first_package = Some(spec.instance.package.clone());
        }
        counts.candidates += 1;
        candidates.push(Candidate {
            key,
            builder: spec.instance.builder.id.clone(),
            roots,
        });
    }
    if candidates.is_empty() {
        return None;
    }
    // Every changed unit in the candidates' recorded closures needs
    // a current fingerprint and refreshed edges for the comparison.
    // The closures share the dependency tree, so walk their union
    // once instead of once per candidate.
    let all_roots: Vec<&str> = candidates
        .iter()
        .flat_map(|candidate| candidate.roots.iter().map(String::as_str))
        .collect();
    let closure = forward_closure(&recorded, &all_roots);
    for &asset in &changed_set {
        if !closure.contains(asset) || generated.contains(asset) {
            continue;
        }
        let Some(current) = current_snapshot.get(asset) else {
            continue;
        };
        if current.exists {
            query.insert(asset.to_owned(), current.digest.clone());
        }
    }
    if query.is_empty() {
        if diagnostics.enabled {
            // No unit in the changed closures can be queried, so
            // evaluate never runs; attribute each candidate here
            // instead. Every changed unit in a candidate's recorded
            // closure is generated or absent from the current
            // snapshot (anything else would have been queried), so
            // one shared reverse walk over the candidates' roots
            // classifies them all.
            let changed_generated: BTreeSet<&str> = changed_set
                .iter()
                .copied()
                .filter(|asset| generated.contains(*asset))
                .collect();
            let [generated_reached] =
                reverse_reachable_sets(&recorded, &all_roots, &closure, [&changed_generated]);
            for candidate in &candidates {
                let counts = diagnostics
                    .assess
                    .entry(candidate.builder.clone())
                    .or_default();
                if candidate
                    .roots
                    .iter()
                    .any(|root| generated_reached.contains(root))
                {
                    counts.no_query_generated_asset += 1;
                } else {
                    counts.no_query_deleted_or_appeared += 1;
                }
            }
        }
        return None;
    }
    let deleted: BTreeSet<String> = changed
        .iter()
        .filter(|asset| {
            current_snapshot
                .get(**asset)
                .is_none_or(|current| !current.exists)
        })
        .map(|asset| (*asset).to_owned())
        .collect();
    let appeared: BTreeSet<String> = changed
        .iter()
        .filter(|asset| {
            current_snapshot
                .get(**asset)
                .is_some_and(|current| current.exists)
                && state
                    .assets
                    .get(**asset)
                    .is_none_or(|previous| !previous.exists)
        })
        .map(|asset| (*asset).to_owned())
        .collect();
    // Generated assets a candidate can still be waived through:
    // only the unstable ones (no bound fingerprint record, or a
    // producer that cannot be proven idle in this build) keep
    // blocking. The rest fold with their recorded fingerprint.
    let unstable_generated = unstable_generated_assets(
        state,
        specs,
        &StabilityInputs {
            changed: &changed_set,
            tainted,
            generated,
            current_snapshot,
        },
        &closure,
        &recorded,
    );
    // Preflight skip: when every candidate's recorded closure
    // already reaches an unstable generated or deleted/appeared
    // unit, the recorded graph alone proves evaluation would
    // block them all, so starting a worker pool to learn that is
    // a pure tax (the production shape behind this is an app
    // whose libraries all have generated parts, where the tax
    // was about 10% of wall time). The old-side block is decisive
    // on its own: a candidate whose new closure no longer reached
    // the disqualifying unit got there through an edit inside the
    // closure, which changes its fold, so it could not be waived
    // either. With diagnostics on, attribute each candidate to
    // the rule that blocks it, generated first, as evaluate does.
    let lifecycle: BTreeSet<&str> = deleted
        .iter()
        .chain(appeared.iter())
        .map(String::as_str)
        .collect();
    // The forward closure is already computed for the query; when
    // it holds no disqualifying unit at all, no candidate can be
    // proven blocked and the reverse walks below would be pure
    // overhead on the common source-only path.
    let any_blocker_in_closure = closure
        .iter()
        .any(|asset| unstable_generated.contains(asset) || lifecycle.contains(asset.as_str()));
    if any_blocker_in_closure && diagnostics.enabled {
        let generated_targets: BTreeSet<&str> =
            unstable_generated.iter().map(String::as_str).collect();
        let [generated_reached, lifecycle_reached] = reverse_reachable_sets(
            &recorded,
            &all_roots,
            &closure,
            [&generated_targets, &lifecycle],
        );
        let reaches = |candidate: &Candidate, set: &BTreeSet<String>| {
            candidate
                .roots
                .iter()
                .any(|root| set.contains(root.as_str()))
        };
        if candidates.iter().all(|candidate| {
            reaches(candidate, &generated_reached) || reaches(candidate, &lifecycle_reached)
        }) {
            for candidate in &candidates {
                let counts = diagnostics
                    .evaluate
                    .entry(candidate.builder.clone())
                    .or_default();
                if reaches(candidate, &generated_reached) {
                    counts.generated_asset += 1;
                } else {
                    counts.deleted_or_appeared += 1;
                }
            }
            diagnostics.preflight_skipped = true;
            return None;
        }
    } else if any_blocker_in_closure {
        let blocked_targets: BTreeSet<&str> = unstable_generated
            .iter()
            .map(String::as_str)
            .chain(lifecycle.iter().copied())
            .collect();
        let [blocked_reached] =
            reverse_reachable_sets(&recorded, &all_roots, &closure, [&blocked_targets]);
        if candidates.iter().all(|candidate| {
            candidate
                .roots
                .iter()
                .any(|root| blocked_reached.contains(root.as_str()))
        }) {
            return None;
        }
    }
    diagnostics.query_units = query.len();
    Some(Assessment {
        query: query.into_iter().collect(),
        first_package: first_package.expect("a candidate supplied a package"),
        candidates,
        deleted,
        appeared,
        unstable_generated,
        recorded_closure: closure,
    })
}

/// Compares effective signatures for every assessed candidate using
/// the preflight answers in `results`. Units the worker did not
/// answer for, answered without a fingerprint or deps, deleted units,
/// and generated assets whose producer cannot be proven stable all
/// leave the action content-keyed.
pub(super) fn evaluate(
    state: &GraphState,
    assessment: &Assessment,
    results: &BTreeMap<String, ApiUnitEvidence>,
    seed: &str,
    diagnostics: &mut CutoffDiagnostics,
) -> CutoffEvidence {
    let mut learned: BTreeMap<String, Option<ApiFingerprintRecord>> = BTreeMap::new();
    for (asset, digest) in &assessment.query {
        if let Some(evidence) = results.get(asset) {
            // The worker verified the content it fingerprinted
            // against this snapshot digest, so the answer binds to it.
            learned.insert(
                asset.clone(),
                evidence
                    .fingerprint
                    .clone()
                    .map(|fingerprint| ApiFingerprintRecord {
                        digest: bare_digest(digest).to_owned(),
                        fingerprint,
                    }),
            );
        }
    }
    let old_graph = GraphView {
        base: &state.resolver_dep_graph,
        overrides: None,
    };
    let mut edge_overrides: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut fingerprint_overrides: BTreeMap<String, String> = BTreeMap::new();
    // Only queried units may contribute evidence: the worker was
    // given a snapshot digest to verify for those, and an
    // unsolicited entry binds to nothing, so it could otherwise
    // override a unit whose recorded evidence should stand.
    let queried: BTreeSet<&str> = assessment
        .query
        .iter()
        .map(|(asset, _)| asset.as_str())
        .collect();
    for (asset, evidence) in results {
        if !queried.contains(asset.as_str()) {
            continue;
        }
        if let Some(deps) = &evidence.deps {
            edge_overrides.insert(asset.clone(), deps.clone());
        }
        if let Some(fingerprint) = &evidence.fingerprint {
            fingerprint_overrides.insert(asset.clone(), fingerprint.clone());
        }
    }
    let new_graph = GraphView {
        base: &state.resolver_dep_graph,
        overrides: Some(&edge_overrides),
    };
    let bound_fingerprints = bound_fingerprints(state);
    let old_fingerprints = FingerprintView {
        base: &bound_fingerprints,
        overrides: None,
    };
    let new_fingerprints = FingerprintView {
        base: &bound_fingerprints,
        overrides: Some(&fingerprint_overrides),
    };
    // Folds are per-unit values: compute them once per view over the
    // union of all candidates' roots instead of re-walking the
    // shared dependency tree (and re-hashing it) for every action.
    let all_roots: Vec<&str> = assessment
        .candidates
        .iter()
        .flat_map(|candidate| candidate.roots.iter().map(String::as_str))
        .collect();
    let new_closure = forward_closure(&new_graph, &all_roots);
    let old_folds = fold_map(
        &assessment.recorded_closure,
        &old_graph,
        &old_fingerprints,
        seed,
    );
    let new_folds = fold_map(&new_closure, &new_graph, &new_fingerprints, seed);
    // The remaining checks ask whether a candidate's closure reaches
    // a disqualifying asset: a generated, deleted or restored unit
    // (blocked), or a queried unit the worker could not answer with
    // both a fingerprint and refreshed edges (unanswered; the new
    // fold would silently reuse stale evidence). Compute the roots
    // each set taints once per view by walking the reverse graph,
    // instead of walking every candidate's closure.
    let generated_targets: BTreeSet<&str> = assessment
        .unstable_generated
        .iter()
        .map(String::as_str)
        .collect();
    let lifecycle_targets: BTreeSet<&str> = assessment
        .deleted
        .iter()
        .chain(assessment.appeared.iter())
        .map(String::as_str)
        .collect();
    let unanswered_targets: BTreeSet<&str> = queried
        .iter()
        .copied()
        .filter(|asset| {
            results
                .get(*asset)
                .is_none_or(|evidence| evidence.fingerprint.is_none() || evidence.deps.is_none())
        })
        .collect();
    // With diagnostics on, the generated and lifecycle splits stay
    // separate so a disqualification can be attributed to the rule
    // that caused it. With diagnostics off, only their union (the
    // blocked set the decision uses) is walked, as before, and it
    // is reported through the generated slots with the lifecycle
    // slots empty; the counts land in scratch and are discarded.
    let (
        generated_old,
        lifecycle_old,
        unanswered_old,
        generated_new,
        lifecycle_new,
        unanswered_new,
    ) = if diagnostics.enabled {
        let [generated_old, lifecycle_old, unanswered_old] = reverse_reachable_sets(
            &old_graph,
            &all_roots,
            &assessment.recorded_closure,
            [&generated_targets, &lifecycle_targets, &unanswered_targets],
        );
        let [generated_new, lifecycle_new, unanswered_new] = reverse_reachable_sets(
            &new_graph,
            &all_roots,
            &new_closure,
            [&generated_targets, &lifecycle_targets, &unanswered_targets],
        );
        (
            generated_old,
            lifecycle_old,
            unanswered_old,
            generated_new,
            lifecycle_new,
            unanswered_new,
        )
    } else {
        let blocked_targets: BTreeSet<&str> = generated_targets
            .iter()
            .chain(lifecycle_targets.iter())
            .copied()
            .collect();
        let [blocked_old, unanswered_old] = reverse_reachable_sets(
            &old_graph,
            &all_roots,
            &assessment.recorded_closure,
            [&blocked_targets, &unanswered_targets],
        );
        let [blocked_new, unanswered_new] = reverse_reachable_sets(
            &new_graph,
            &all_roots,
            &new_closure,
            [&blocked_targets, &unanswered_targets],
        );
        (
            blocked_old,
            BTreeSet::new(),
            unanswered_old,
            blocked_new,
            BTreeSet::new(),
            unanswered_new,
        )
    };
    let mut clean_actions = BTreeSet::new();
    let mut scratch_counts: EvaluateCounts;
    for candidate in &assessment.candidates {
        let reaches = |set: &BTreeSet<String>| {
            candidate
                .roots
                .iter()
                .any(|root| set.contains(root.as_str()))
        };
        let counts = if diagnostics.enabled {
            diagnostics
                .evaluate
                .entry(candidate.builder.clone())
                .or_default()
        } else {
            scratch_counts = EvaluateCounts::default();
            &mut scratch_counts
        };
        if reaches(&generated_old) || reaches(&generated_new) {
            counts.generated_asset += 1;
            continue;
        }
        if reaches(&lifecycle_old) || reaches(&lifecycle_new) {
            counts.deleted_or_appeared += 1;
            continue;
        }
        if reaches(&unanswered_old) || reaches(&unanswered_new) {
            counts.unanswered_unit += 1;
            continue;
        }
        // A root absent from a fold map has no determined fold in
        // that view (missing fingerprint evidence at or below it),
        // which leaves the action content-keyed exactly as a failed
        // fold did; a present root fold also implies the root's
        // whole closure is folded in that view. With diagnostics
        // off, the single short-circuiting comparison decides; with
        // diagnostics on, one pass over the roots classifies
        // presence and equality together for the counters.
        if !diagnostics.enabled {
            if candidate.roots.iter().all(|root| {
                old_folds
                    .get(root)
                    .is_some_and(|fold| new_folds.get(root) == Some(fold))
            }) {
                clean_actions.insert(candidate.key.clone());
            }
            continue;
        }
        let mut all_present = true;
        let mut all_equal = true;
        for root in &candidate.roots {
            match (old_folds.get(root), new_folds.get(root)) {
                (Some(old_fold), Some(new_fold)) => {
                    if old_fold != new_fold {
                        all_equal = false;
                    }
                }
                _ => {
                    all_present = false;
                    all_equal = false;
                }
            }
        }
        if !all_present {
            counts.missing_evidence += 1;
            continue;
        }
        if all_equal {
            counts.signature_unchanged += 1;
            clean_actions.insert(candidate.key.clone());
        } else {
            counts.signature_changed += 1;
        }
    }
    CutoffEvidence {
        clean_actions,
        learned,
    }
}

#[cfg(test)]
mod tests;
