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

use crate::graph::{DirtyContext, GraphState};
use crate::plan::BuildSpec;
use crate::protocol::ApiFingerprintRecord;
use crate::snapshot::Snapshot;
use crate::worker::ApiUnitEvidence;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// The outcome of a stage 4 preflight: the actions whose resolver
/// observations are proven unchanged, plus the fingerprints the
/// preflight learned, to merge into the graph with the build's save.
pub(super) struct CutoffEvidence {
    pub(super) clean_actions: BTreeSet<String>,
    pub(super) learned: BTreeMap<String, Option<ApiFingerprintRecord>>,
}

/// The bare BLAKE3 hex of a snapshot digest, which carries a `b3-`
/// prefix unlike the digests workers report.
fn bare_digest(digest: &str) -> &str {
    digest.strip_prefix("b3-").unwrap_or(digest)
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
}

struct Candidate {
    key: String,
    /// Builder definition id, for diagnostics attribution.
    builder: String,
    /// Resolver observation roots: entrypoints plus direct resolver
    /// reads. The action's effective signature is the fold of these.
    roots: Vec<String>,
}

/// Per-builder counters behind the cutoff metrics output
/// (`BUILD_RUNNER_ACCELERATOR_METRICS=1`). They explain why an
/// opt-in did or did not pay off: how [`assess`] filtered the
/// opted-in actions, and how [`evaluate`] decided each candidate.
/// Counting never changes a decision.
#[derive(Debug, Default)]
pub(super) struct CutoffDiagnostics {
    /// Counting costs a map entry per opted-in action, so it only
    /// runs when the metrics output is on; `prepare_cutoff` sets
    /// this from the same flag that gates printing.
    pub(super) enabled: bool,
    pub(super) assess: BTreeMap<String, AssessCounts>,
    pub(super) evaluate: BTreeMap<String, EvaluateCounts>,
    pub(super) changed_units: usize,
    pub(super) generated_assets: usize,
    pub(super) query_units: usize,
    /// Set when assess proved every candidate blocked from the
    /// recorded graph alone, so `prepare_cutoff` prints the
    /// evaluate counters even though no preflight ran.
    pub(super) preflight_skipped: bool,
}

#[derive(Debug, Default)]
pub(super) struct AssessCounts {
    pub(super) candidates: usize,
    pub(super) no_recorded_action: usize,
    pub(super) ast_or_content_read: usize,
    pub(super) own_input_or_direct_read_changed: usize,
    pub(super) no_resolver_observation: usize,
    pub(super) not_reached_by_change: usize,
    pub(super) no_roots: usize,
    /// Candidates dropped before evaluation because no unit in
    /// their changed closures could be queried: a generated unit
    /// changed, or the changed units are absent from the current
    /// snapshot. Split by which of the two applies.
    pub(super) no_query_generated_asset: usize,
    pub(super) no_query_deleted_or_appeared: usize,
}

#[derive(Debug, Default)]
pub(super) struct EvaluateCounts {
    /// The signature proof passed. Dirty planning can still run
    /// the action for reasons outside the resolver observations
    /// (a changed glob, a missing output), so this counts proven
    /// unchanged signatures, not final skips.
    pub(super) signature_unchanged: usize,
    pub(super) generated_asset: usize,
    pub(super) deleted_or_appeared: usize,
    pub(super) unanswered_unit: usize,
    pub(super) missing_evidence: usize,
    pub(super) signature_changed: usize,
}

impl CutoffDiagnostics {
    /// The assessment counters print before the fallible worker
    /// preflight starts, so a failed query still leaves them in
    /// the output; the evaluation counters print after evaluation.
    pub(super) fn print_assess(&self) {
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

    pub(super) fn print_evaluate(&self) {
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
    let changed_set: BTreeSet<String> = changed.iter().map(|asset| (*asset).to_owned()).collect();
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
    let all_roots: Vec<String> = candidates
        .iter()
        .flat_map(|candidate| candidate.roots.iter().cloned())
        .collect();
    let closure = forward_closure(&recorded, &all_roots);
    for asset in closure.intersection(&changed_set) {
        if generated.contains(asset) {
            continue;
        }
        let Some(current) = current_snapshot.get(asset) else {
            continue;
        };
        if current.exists {
            query.insert(asset.clone(), current.digest.clone());
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
                .map(String::as_str)
                .filter(|asset| generated.contains(*asset))
                .collect();
            let [generated_reached] =
                reverse_reachable_sets(&recorded, &all_roots, [&changed_generated]);
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
    let unstable_generated =
        unstable_generated_assets(state, specs, &changed_set, generated, &closure, &recorded);
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
        let [generated_reached, lifecycle_reached] =
            reverse_reachable_sets(&recorded, &all_roots, [&generated_targets, &lifecycle]);
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
        let [blocked_reached] = reverse_reachable_sets(&recorded, &all_roots, [&blocked_targets]);
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
    })
}

/// The generated assets in `closure` (the candidates' recorded
/// closure) whose recorded fingerprint cannot stand in for the
/// bytes the resolver will read in this build.
///
/// A generated asset is stable when all of these hold: the asset
/// itself did not change; a fingerprint record bound to the
/// recorded snapshot's bytes exists for it; it has a producer in
/// the current plan that is not an assembled shared part; and the
/// producer provably does not run in this build (see
/// [`GeneratedStability::producer_stable`]). Anything else stays
/// unstable and keeps blocking candidates exactly as every
/// generated asset did before producer-stability inheritance.
fn unstable_generated_assets(
    state: &GraphState,
    specs: &[BuildSpec],
    changed: &BTreeSet<String>,
    generated: &BTreeSet<String>,
    closure: &BTreeSet<String>,
    recorded: &GraphView<'_>,
) -> BTreeSet<String> {
    let relevant: Vec<&String> = generated
        .iter()
        .filter(|asset| closure.contains(*asset))
        .collect();
    if relevant.is_empty() {
        return BTreeSet::new();
    }
    if state.was_filtered {
        // The first unfiltered build after a filtered one inherits
        // action records a filtered commit pruned or kept under
        // different demand, so producer stability cannot be proven
        // from them. The next build relearns from a full commit.
        return relevant.iter().map(|asset| (*asset).clone()).collect();
    }
    let bound = bound_fingerprints(state);
    let mut producers: BTreeMap<&str, &BuildSpec> = BTreeMap::new();
    for spec in specs {
        for output in &spec.outputs {
            producers.entry(output.as_str()).or_insert(spec);
        }
    }
    let mut stability = GeneratedStability {
        state,
        changed,
        generated,
        bound: &bound,
        producers: &producers,
        recorded,
        asset_verdicts: BTreeMap::new(),
        producer_verdicts: BTreeMap::new(),
        assets_in_progress: BTreeSet::new(),
        producers_in_progress: BTreeSet::new(),
    };
    relevant
        .iter()
        .filter(|asset| !stability.asset_stable(asset))
        .map(|asset| (*asset).clone())
        .collect()
}

/// Recursive producer-stability proof for generated assets.
/// Verdicts are memoized per asset and per producer action; a
/// cycle in the producer graph is unstable, since the recursion
/// itself is the only proof available and it cannot ground out.
struct GeneratedStability<'a> {
    state: &'a GraphState,
    changed: &'a BTreeSet<String>,
    generated: &'a BTreeSet<String>,
    bound: &'a BTreeMap<String, String>,
    producers: &'a BTreeMap<&'a str, &'a BuildSpec>,
    recorded: &'a GraphView<'a>,
    asset_verdicts: BTreeMap<String, bool>,
    producer_verdicts: BTreeMap<String, bool>,
    assets_in_progress: BTreeSet<String>,
    producers_in_progress: BTreeSet<String>,
}

impl GeneratedStability<'_> {
    fn asset_stable(&mut self, asset: &str) -> bool {
        if let Some(verdict) = self.asset_verdicts.get(asset) {
            return *verdict;
        }
        if !self.assets_in_progress.insert(asset.to_owned()) {
            return false;
        }
        let producer = self.producers.get(asset).copied();
        let verdict = !self.changed.contains(asset)
            && self.bound.contains_key(asset)
            && producer.is_some_and(|spec| {
                // Assembled shared parts are assembled per phase
                // from every contributor of the library, so no
                // single producer's idleness proves their bytes.
                !super::shared_parts::owns_part(spec, asset) && self.producer_stable(spec)
            });
        self.assets_in_progress.remove(asset);
        self.asset_verdicts.insert(asset.to_owned(), verdict);
        verdict
    }

    fn producer_stable(&mut self, spec: &BuildSpec) -> bool {
        let key = spec.action_key();
        if let Some(verdict) = self.producer_verdicts.get(&key) {
            return *verdict;
        }
        if !self.producers_in_progress.insert(key.clone()) {
            return false;
        }
        let verdict = self.producer_stable_inner(spec);
        self.producers_in_progress.remove(&key);
        self.producer_verdicts.insert(key, verdict);
        verdict
    }

    fn producer_stable_inner(&mut self, spec: &BuildSpec) -> bool {
        let Some(action) = self.state.actions.get(&spec.action_key()) else {
            return false;
        };
        // Content channel: the recorded input, direct reads and
        // outputs are what dirty analysis keys on; a change among
        // them can rerun the producer.
        if self.changed.contains(action.input.as_str())
            || action
                .reads
                .iter()
                .any(|asset| self.changed.contains(asset.as_str()))
            || action
                .outputs
                .iter()
                .any(|asset| self.changed.contains(asset.as_str()))
        {
            return false;
        }
        // Glob reads observe a set, not recorded members: a changed
        // asset the pattern matches can rerun the producer, and a
        // generated member's bytes are only as stable as its own
        // producer. The producer's own outputs are exempt from the
        // cascade checks: a producer that resolves its input
        // library observes the previous version of its own output
        // (a part of that library, or a glob member it wrote), and
        // that self-observation carries no information beyond the
        // content checks above, which already key on the outputs.
        let own_outputs: BTreeSet<&str> = action.outputs.iter().map(String::as_str).collect();
        for glob in &action.glob_reads {
            let changed_matches = self.changed.iter().any(|asset| glob_matches(glob, asset));
            if changed_matches {
                return false;
            }
            let generated_members: Vec<String> = self
                .generated
                .iter()
                .filter(|asset| glob_matches(glob, asset) && !own_outputs.contains(asset.as_str()))
                .cloned()
                .collect();
            if !generated_members
                .iter()
                .all(|asset| self.asset_stable(asset))
            {
                return false;
            }
        }
        // Resolver channel: the producer reruns if anything its
        // resolver observations reach has changed.
        let roots: Vec<String> = action
            .resolver_entrypoints
            .iter()
            .cloned()
            .chain(action.resolver_reads.iter().cloned())
            .collect();
        let closure = forward_closure(self.recorded, &roots);
        if closure
            .iter()
            .any(|asset| self.changed.contains(asset.as_str()))
        {
            return false;
        }
        // Cascade: a generated unit the producer consumes (as its
        // input, a direct read, or through the resolver) is
        // regenerated before the producer whenever its own
        // producer runs, and a rerun upstream producer reruns
        // this one. Own outputs are exempt, as above.
        let consumed: Vec<String> = action
            .reads
            .iter()
            .chain(std::iter::once(&action.input))
            .chain(closure.iter())
            .filter(|asset| {
                self.generated.contains(asset.as_str()) && !own_outputs.contains(asset.as_str())
            })
            .cloned()
            .collect();
        consumed.iter().all(|asset| self.asset_stable(asset))
    }
}

fn glob_matches(glob: &crate::protocol::GlobRead, asset: &str) -> bool {
    asset.split_once('|').is_some_and(|(package, path)| {
        package == glob.package && crate::workspace::matches_glob(&glob.pattern, path)
    })
}

/// The recorded fingerprints that are baseline evidence for this
/// build: a record counts only when it is bound to the previous
/// snapshot's bytes for that unit. A worker can learn a fingerprint
/// from content newer than the snapshot a watch build commits (an
/// edit that arrives mid-build), and such a record must never stand
/// in for the earlier content.
fn bound_fingerprints(state: &GraphState) -> BTreeMap<String, String> {
    state
        .asset_fingerprints
        .iter()
        .filter(|(asset, record)| {
            state.assets.get(*asset).is_some_and(|previous| {
                previous.exists && bare_digest(&previous.digest) == record.digest
            })
        })
        .map(|(asset, record)| (asset.clone(), record.fingerprint.clone()))
        .collect()
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
    let queried: BTreeSet<&str> = assessment
        .query
        .iter()
        .map(|(asset, _)| asset.as_str())
        .collect();
    let all_roots: Vec<String> = assessment
        .candidates
        .iter()
        .flat_map(|candidate| candidate.roots.iter().cloned())
        .collect();
    let old_folds = fold_map(&all_roots, &old_graph, &old_fingerprints, seed);
    let new_folds = fold_map(&all_roots, &new_graph, &new_fingerprints, seed);
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
            [&generated_targets, &lifecycle_targets, &unanswered_targets],
        );
        let [generated_new, lifecycle_new, unanswered_new] = reverse_reachable_sets(
            &new_graph,
            &all_roots,
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
            [&blocked_targets, &unanswered_targets],
        );
        let [blocked_new, unanswered_new] = reverse_reachable_sets(
            &new_graph,
            &all_roots,
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

/// For each target set, the subset of `roots` that can reach any of
/// its targets over the dep graph. The forward closure and the
/// reverse map are built once and shared by every set; each set
/// then walks the reverse graph from its own targets within the
/// region reachable from `roots`.
fn reverse_reachable_sets<const N: usize>(
    graph: &GraphView<'_>,
    roots: &[String],
    target_sets: [&BTreeSet<&str>; N],
) -> [BTreeSet<String>; N] {
    let reachable = forward_closure(graph, roots);
    let mut reverse: HashMap<&str, Vec<&str>> = HashMap::new();
    for asset in &reachable {
        for dep in graph.deps(asset) {
            if reachable.contains(dep.as_str()) {
                reverse
                    .entry(dep.as_str())
                    .or_default()
                    .push(asset.as_str());
            }
        }
    }
    let root_set: BTreeSet<&str> = roots.iter().map(String::as_str).collect();
    target_sets.map(|targets| {
        let mut reached_roots = BTreeSet::new();
        let mut seen: BTreeSet<&str> = BTreeSet::new();
        let mut stack: Vec<&str> = targets
            .iter()
            .copied()
            .filter(|target| reachable.contains(*target))
            .collect();
        for target in &stack {
            seen.insert(target);
        }
        while let Some(asset) = stack.pop() {
            if root_set.contains(asset) {
                reached_roots.insert(asset.to_owned());
            }
            if let Some(dependents) = reverse.get(asset) {
                for dependent in dependents {
                    if seen.insert(dependent) {
                        stack.push(dependent);
                    }
                }
            }
        }
        reached_roots
    })
}

/// The forward closure of `roots` over the dep graph, roots included.
fn forward_closure(graph: &GraphView<'_>, roots: &[String]) -> BTreeSet<String> {
    let mut seen: BTreeSet<String> = roots.iter().cloned().collect();
    let mut stack: Vec<String> = roots.to_vec();
    while let Some(asset) = stack.pop() {
        for dep in graph.deps(&asset) {
            if seen.insert(dep.clone()) {
                stack.push(dep.clone());
            }
        }
    }
    seen
}

/// A dep graph view: recorded edges with per-asset overrides applied.
struct GraphView<'a> {
    base: &'a BTreeMap<String, Vec<String>>,
    overrides: Option<&'a BTreeMap<String, Vec<String>>>,
}

impl GraphView<'_> {
    fn deps(&self, asset: &str) -> &[String] {
        self.overrides
            .and_then(|overrides| overrides.get(asset))
            .or_else(|| self.base.get(asset))
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }
}

/// A fingerprint view: recorded fingerprints with overrides applied.
struct FingerprintView<'a> {
    base: &'a BTreeMap<String, String>,
    overrides: Option<&'a BTreeMap<String, String>>,
}

impl FingerprintView<'_> {
    fn get(&self, asset: &str) -> Option<&str> {
        self.overrides
            .and_then(|overrides| overrides.get(asset))
            .or_else(|| self.base.get(asset))
            .map(String::as_str)
    }
}

/// Folds effective signatures for `roots`: for each root, the hash of
/// its SCC's member fingerprints and the folds of the SCCs it depends
/// on, seeded with `seed`. Returns `None` when any unit in the
/// reachable subgraph has no fingerprint.
#[cfg(test)]
fn fold_all(
    roots: &[String],
    graph: &GraphView<'_>,
    fingerprints: &FingerprintView<'_>,
    seed: &str,
) -> Option<BTreeMap<String, String>> {
    let folds = fold_map(roots, graph, fingerprints, seed);
    let mut result = BTreeMap::new();
    for root in roots {
        result.insert(root.clone(), folds.get(root.as_str())?.clone());
    }
    Some(result)
}

/// Computes the effective-signature fold of every unit reachable
/// from `roots` whose fold is determined. A unit's fold needs its
/// own fingerprint and the folds of all its dependencies, so a unit
/// with no fingerprint, and everything depending on it, is absent
/// from the result. Folds are per-unit values, so one computation
/// serves every candidate that shares the dependency tree.
fn fold_map(
    roots: &[String],
    graph: &GraphView<'_>,
    fingerprints: &FingerprintView<'_>,
    seed: &str,
) -> BTreeMap<String, String> {
    let reachable = {
        let mut seen: BTreeSet<String> = roots.iter().cloned().collect();
        let mut stack: Vec<String> = roots.to_vec();
        while let Some(asset) = stack.pop() {
            for dep in graph.deps(&asset) {
                if seen.insert(dep.clone()) {
                    stack.push(dep.clone());
                }
            }
        }
        seen
    };
    // Iterative Tarjan: SCCs are emitted in reverse topological order
    // (dependencies first), which is the order folds are computed in.
    let mut index_of: HashMap<&str, usize> = HashMap::new();
    let mut lowlink: HashMap<&str, usize> = HashMap::new();
    let mut on_stack: BTreeSet<&str> = BTreeSet::new();
    let mut tarjan_stack: Vec<&str> = Vec::new();
    let mut next_index = 0usize;
    let mut sccs: Vec<Vec<&str>> = Vec::new();
    for root in &reachable {
        if index_of.contains_key(root.as_str()) {
            continue;
        }
        // Each frame: (node, next dep position to visit).
        let mut frames: Vec<(&str, usize)> = vec![(root.as_str(), 0)];
        index_of.insert(root.as_str(), next_index);
        lowlink.insert(root.as_str(), next_index);
        next_index += 1;
        tarjan_stack.push(root.as_str());
        on_stack.insert(root.as_str());
        while let Some(&(node, child)) = frames.last() {
            let deps = graph.deps(node);
            if child < deps.len() {
                frames.last_mut().expect("frame exists").1 += 1;
                let dep = deps[child].as_str();
                if !reachable.contains(dep) {
                    continue;
                }
                if !index_of.contains_key(dep) {
                    index_of.insert(dep, next_index);
                    lowlink.insert(dep, next_index);
                    next_index += 1;
                    tarjan_stack.push(dep);
                    on_stack.insert(dep);
                    frames.push((dep, 0));
                } else if on_stack.contains(dep) {
                    let dep_index = index_of[dep];
                    let low = lowlink.get_mut(node).expect("node indexed");
                    *low = (*low).min(dep_index);
                }
            } else {
                frames.pop();
                if let Some(&(parent, _)) = frames.last() {
                    let node_low = lowlink[node];
                    let parent_low = lowlink.get_mut(parent).expect("parent indexed");
                    *parent_low = (*parent_low).min(node_low);
                }
                if lowlink[node] == index_of[node] {
                    let mut scc = Vec::new();
                    loop {
                        let member = tarjan_stack.pop().expect("SCC member on stack");
                        on_stack.remove(member);
                        scc.push(member);
                        if member == node {
                            break;
                        }
                    }
                    sccs.push(scc);
                }
            }
        }
    }
    let mut scc_fold: HashMap<&str, String> = HashMap::new();
    for scc in &sccs {
        let mut members: Vec<&str> = scc.clone();
        members.sort_unstable();
        let mut external: BTreeMap<&str, &str> = BTreeMap::new();
        let mut computable = true;
        for member in &members {
            for dep in graph.deps(member) {
                let dep = dep.as_str();
                // `members` is sorted above; a linear scan per edge
                // would make folding a large import cycle quadratic.
                if members.binary_search(&dep).is_err() {
                    match scc_fold.get(dep) {
                        Some(fold) => {
                            external.insert(dep, fold);
                        }
                        None => computable = false,
                    }
                }
            }
        }
        if !computable
            || members
                .iter()
                .any(|member| fingerprints.get(member).is_none())
        {
            continue;
        }
        let mut hasher = blake3::Hasher::new();
        hash_field(&mut hasher, seed);
        for member in &members {
            hash_field(&mut hasher, member);
            hash_field(
                &mut hasher,
                fingerprints.get(member).expect("checked computable"),
            );
        }
        for (dep, fold) in &external {
            hash_field(&mut hasher, dep);
            hash_field(&mut hasher, fold);
        }
        let fold = hasher.finalize().to_hex().to_string();
        for member in &members {
            scc_fold.insert(member, fold.clone());
        }
    }
    scc_fold
        .into_iter()
        .map(|(asset, fold)| (asset.to_owned(), fold))
        .collect()
}

fn hash_field(hasher: &mut blake3::Hasher, value: &str) {
    hasher.update(&(value.len() as u32).to_be_bytes());
    hasher.update(value.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::ActionState;

    fn graph(edges: &[(&str, &[&str])]) -> BTreeMap<String, Vec<String>> {
        edges
            .iter()
            .map(|(asset, deps)| {
                (
                    asset.to_string(),
                    deps.iter().map(|dep| dep.to_string()).collect(),
                )
            })
            .collect()
    }

    fn view<'a>(
        graph: &'a BTreeMap<String, Vec<String>>,
        fingerprints: &'a BTreeMap<String, String>,
    ) -> (GraphView<'a>, FingerprintView<'a>) {
        (
            GraphView {
                base: graph,
                overrides: None,
            },
            FingerprintView {
                base: fingerprints,
                overrides: None,
            },
        )
    }

    fn fingerprints(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(asset, fp)| (asset.to_string(), fp.to_string()))
            .collect()
    }

    #[test]
    fn fold_propagates_leaf_changes_and_ignores_unrelated() {
        let edges = graph(&[("a", &["b"]), ("b", &["c"]), ("c", &[])]);
        let fps = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc")]);
        let (g, f) = view(&edges, &fps);
        let before = fold_all(&["a".into()], &g, &f, "seed").expect("folds");
        let changed = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc2")]);
        let (g2, f2) = view(&edges, &changed);
        let after = fold_all(&["a".into()], &g2, &f2, "seed").expect("folds");
        assert_ne!(before, after, "a leaf API change must reach the root");
        let unrelated = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc"), ("z", "fz")]);
        let (g3, f3) = view(&edges, &unrelated);
        assert_eq!(
            before,
            fold_all(&["a".into()], &g3, &f3, "seed").expect("folds")
        );
        let (g4, f4) = view(&edges, &fps);
        assert_ne!(
            before,
            fold_all(&["a".into()], &g4, &f4, "other-seed").expect("folds"),
            "the seed binds the fold to the resolution environment"
        );
    }

    #[test]
    fn fold_collapses_cycles() {
        let edges = graph(&[("a", &["b"]), ("b", &["a", "c"]), ("c", &[])]);
        let fps = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc")]);
        let (g, f) = view(&edges, &fps);
        let folds = fold_all(&["a".into(), "b".into()], &g, &f, "seed").expect("folds");
        assert_eq!(folds["a"], folds["b"], "cycle members share one fold");
        let changed = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc2")]);
        let (g2, f2) = view(&edges, &changed);
        let after = fold_all(&["a".into(), "b".into()], &g2, &f2, "seed").expect("folds");
        assert_ne!(folds, after);
    }

    #[test]
    fn fold_requires_every_fingerprint() {
        let edges = graph(&[("a", &["b"]), ("b", &[])]);
        let fps = fingerprints(&[("a", "fa")]);
        let (g, f) = view(&edges, &fps);
        assert_eq!(fold_all(&["a".into()], &g, &f, "seed"), None);
    }

    fn state_with(
        edges: &[(&str, &[&str])],
        fps: &[(&str, &str)],
        action: ActionState,
    ) -> GraphState {
        // Recorded fingerprints are bound to snapshot entries whose
        // digests carry the `b3-` prefix the records omit.
        let asset_fingerprints = fps
            .iter()
            .map(|(asset, fp)| {
                (
                    asset.to_string(),
                    ApiFingerprintRecord {
                        digest: format!("digest-of-{asset}"),
                        fingerprint: fp.to_string(),
                    },
                )
            })
            .collect();
        let assets = fps
            .iter()
            .map(|(asset, _)| {
                (
                    asset.to_string(),
                    crate::snapshot::AssetSnapshot {
                        exists: true,
                        digest: format!("b3-digest-of-{asset}"),
                        size: 0,
                    },
                )
            })
            .collect();
        GraphState {
            resolver_dep_graph: graph(edges),
            asset_fingerprints,
            assets,
            actions: BTreeMap::from([("app|target:app:consumer".to_string(), action)]),
            ..GraphState::default()
        }
    }

    #[test]
    fn evaluate_marks_only_proven_clean_actions() {
        let action = ActionState {
            builder: "app:consumer".into(),
            input: "app|lib/main.dart".into(),
            resolver_entrypoints: vec!["app|lib/main.dart".into()],
            ..ActionState::default()
        };
        let state = state_with(
            &[("app|lib/main.dart", &["app|lib/dep.dart"])],
            &[
                ("app|lib/main.dart", "f-main"),
                ("app|lib/dep.dart", "f-dep"),
            ],
            action,
        );
        let assessment = Assessment {
            query: vec![("app|lib/dep.dart".into(), "d2".into())],
            first_package: "app".into(),
            candidates: vec![Candidate {
                key: "app|target:app:consumer".into(),
                builder: "app:consumer".into(),
                roots: vec!["app|lib/main.dart".into()],
            }],
            deleted: BTreeSet::new(),
            appeared: BTreeSet::new(),
            unstable_generated: BTreeSet::new(),
        };
        let unchanged = BTreeMap::from([(
            "app|lib/dep.dart".to_string(),
            ApiUnitEvidence {
                fingerprint: Some("f-dep".into()),
                deps: Some(vec![]),
            },
        )]);
        let evidence = evaluate(
            &state,
            &assessment,
            &unchanged,
            "seed",
            &mut CutoffDiagnostics::default(),
        );
        assert!(evidence.clean_actions.contains("app|target:app:consumer"));
        assert_eq!(
            evidence.learned.get("app|lib/dep.dart"),
            Some(&Some(ApiFingerprintRecord {
                digest: "d2".to_string(),
                fingerprint: "f-dep".to_string(),
            }))
        );
        let changed = BTreeMap::from([(
            "app|lib/dep.dart".to_string(),
            ApiUnitEvidence {
                fingerprint: Some("f-dep-2".into()),
                deps: Some(vec![]),
            },
        )]);
        let evidence = evaluate(
            &state,
            &assessment,
            &changed,
            "seed",
            &mut CutoffDiagnostics::default(),
        );
        assert!(evidence.clean_actions.is_empty());
        // An unanswered unit is no evidence at all.
        let evidence = evaluate(
            &state,
            &assessment,
            &BTreeMap::new(),
            "seed",
            &mut CutoffDiagnostics::default(),
        );
        assert!(evidence.clean_actions.is_empty());
        // A unit that appeared since the previous snapshot is an
        // existence change: matching fingerprints cannot prove the
        // recorded output was not produced while it was missing.
        let appeared_assessment = Assessment {
            query: assessment.query.clone(),
            first_package: assessment.first_package.clone(),
            candidates: vec![Candidate {
                key: "app|target:app:consumer".into(),
                builder: "app:consumer".into(),
                roots: vec!["app|lib/main.dart".into()],
            }],
            deleted: BTreeSet::new(),
            appeared: BTreeSet::from(["app|lib/dep.dart".to_string()]),
            unstable_generated: BTreeSet::new(),
        };
        let evidence = evaluate(
            &state,
            &appeared_assessment,
            &unchanged,
            "seed",
            &mut CutoffDiagnostics::default(),
        );
        assert!(evidence.clean_actions.is_empty());
        // Evidence for a unit that was never queried binds to no
        // snapshot digest and is ignored outright: the same reply
        // plus a volunteered entry for the importing unit (claiming
        // a different fingerprint and no deps) changes nothing.
        let mut with_volunteered = unchanged.clone();
        with_volunteered.insert(
            "app|lib/main.dart".to_string(),
            ApiUnitEvidence {
                fingerprint: Some("f-main-other".into()),
                deps: Some(vec![]),
            },
        );
        let evidence = evaluate(
            &state,
            &assessment,
            &with_volunteered,
            "seed",
            &mut CutoffDiagnostics::default(),
        );
        assert!(evidence.clean_actions.contains("app|target:app:consumer"));
    }

    #[test]
    fn evaluate_diagnostics_attribute_outcomes() {
        let action = ActionState {
            builder: "app:consumer".into(),
            input: "app|lib/main.dart".into(),
            resolver_entrypoints: vec!["app|lib/main.dart".into()],
            ..ActionState::default()
        };
        let state = state_with(
            &[("app|lib/main.dart", &["app|lib/dep.dart"])],
            &[
                ("app|lib/main.dart", "f-main"),
                ("app|lib/dep.dart", "f-dep"),
            ],
            action,
        );
        let assessment = Assessment {
            query: vec![("app|lib/dep.dart".into(), "d2".into())],
            first_package: "app".into(),
            candidates: vec![Candidate {
                key: "app|target:app:consumer".into(),
                builder: "app:consumer".into(),
                roots: vec!["app|lib/main.dart".into()],
            }],
            deleted: BTreeSet::new(),
            appeared: BTreeSet::new(),
            unstable_generated: BTreeSet::new(),
        };
        let unchanged = BTreeMap::from([(
            "app|lib/dep.dart".to_string(),
            ApiUnitEvidence {
                fingerprint: Some("f-dep".into()),
                deps: Some(vec![]),
            },
        )]);
        let mut diagnostics = CutoffDiagnostics {
            enabled: true,
            ..Default::default()
        };
        let evidence = evaluate(&state, &assessment, &unchanged, "seed", &mut diagnostics);
        assert!(evidence.clean_actions.contains("app|target:app:consumer"));
        assert_eq!(diagnostics.evaluate["app:consumer"].signature_unchanged, 1);
        // An unstable generated asset in the closure disqualifies
        // the whole action, and the diagnostics attribute it to
        // that rule.
        let mut diagnostics = CutoffDiagnostics {
            enabled: true,
            ..Default::default()
        };
        let blocked_assessment = Assessment {
            query: assessment.query.clone(),
            first_package: assessment.first_package.clone(),
            candidates: vec![Candidate {
                key: "app|target:app:consumer".into(),
                builder: "app:consumer".into(),
                roots: vec!["app|lib/main.dart".into()],
            }],
            deleted: BTreeSet::new(),
            appeared: BTreeSet::new(),
            unstable_generated: BTreeSet::from(["app|lib/dep.dart".to_string()]),
        };
        let evidence = evaluate(
            &state,
            &blocked_assessment,
            &unchanged,
            "seed",
            &mut diagnostics,
        );
        assert!(evidence.clean_actions.is_empty());
        assert_eq!(diagnostics.evaluate["app:consumer"].generated_asset, 1);
        assert_eq!(diagnostics.evaluate["app:consumer"].signature_unchanged, 0);
    }

    #[test]
    fn evaluate_rejects_fingerprints_not_bound_to_the_snapshot() {
        let action = ActionState {
            builder: "app:consumer".into(),
            input: "app|lib/main.dart".into(),
            resolver_entrypoints: vec!["app|lib/main.dart".into()],
            ..ActionState::default()
        };
        let mut state = state_with(
            &[("app|lib/main.dart", &["app|lib/dep.dart"])],
            &[
                ("app|lib/main.dart", "f-main"),
                ("app|lib/dep.dart", "f-dep"),
            ],
            action,
        );
        // The recorded fingerprint for the changed unit describes
        // other bytes than the previous snapshot's (a worker learned
        // it from a mid-build edit the commit did not record). Even
        // though the preflight answer matches it, it is not evidence
        // about the snapshot's content and must not waive the action.
        state
            .asset_fingerprints
            .get_mut("app|lib/dep.dart")
            .expect("recorded fingerprint")
            .digest = "digest-of-newer-content".into();
        let assessment = Assessment {
            query: vec![("app|lib/dep.dart".into(), "d2".into())],
            first_package: "app".into(),
            candidates: vec![Candidate {
                key: "app|target:app:consumer".into(),
                builder: "app:consumer".into(),
                roots: vec!["app|lib/main.dart".into()],
            }],
            deleted: BTreeSet::new(),
            appeared: BTreeSet::new(),
            unstable_generated: BTreeSet::new(),
        };
        let answers = BTreeMap::from([(
            "app|lib/dep.dart".to_string(),
            ApiUnitEvidence {
                fingerprint: Some("f-dep".into()),
                deps: Some(vec![]),
            },
        )]);
        let evidence = evaluate(
            &state,
            &assessment,
            &answers,
            "seed",
            &mut CutoffDiagnostics::default(),
        );
        assert!(evidence.clean_actions.is_empty());
    }
}
