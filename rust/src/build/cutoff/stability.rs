use super::{GraphView, forward_closure};
use crate::digest::bare_digest;
use crate::graph::GraphState;
use crate::plan::BuildSpec;
use crate::snapshot::Snapshot;
use crate::workspace::asset_matches_glob;
use std::collections::{BTreeMap, BTreeSet};

/// The generated assets in `closure` (the candidates' recorded
/// closure) whose recorded fingerprint cannot stand in for the
/// bytes the resolver will read in this build. The proof's
/// universe covers recorded outputs and outputs the current
/// plan declares, so an asset that gains a producer in this
/// build is judged by the same rule as a recorded output.
///
/// A generated asset is stable when all of these hold: the asset
/// itself did not change; a fingerprint record bound to the
/// recorded snapshot's bytes exists for it; it has a producer in
/// the current plan that is not an assembled shared part; and the
/// producer provably does not run in this build (see
/// [`producer_seed_dirty`] and the fixpoint below). Anything else
/// stays unstable and keeps blocking candidates exactly as every
/// generated asset did before producer-stability inheritance.
/// The build-wide evidence the producer-stability proof reads.
pub(super) struct StabilityInputs<'a> {
    pub(super) changed: &'a BTreeSet<String>,
    pub(super) tainted: &'a std::collections::HashSet<&'a str>,
    pub(super) generated: &'a BTreeSet<String>,
    pub(super) current_snapshot: &'a Snapshot,
}

pub(super) fn unstable_generated_assets(
    state: &GraphState,
    specs: &[BuildSpec],
    inputs: &StabilityInputs<'_>,
    closure: &BTreeSet<String>,
    recorded: &GraphView<'_>,
) -> BTreeSet<String> {
    let changed = inputs.changed;
    let generated = inputs.generated;
    // The proof's asset universe is the recorded generated assets
    // plus every output the current plan declares. An asset can
    // gain a producer in this build (a checked-in file a builder
    // now emits), and until that producer is proven idle the
    // asset's bytes are no more stable than a recorded output's.
    // Glob reads observe the same widened set: their matches can
    // gain members from actions planned for the first time in
    // this build (an added input creating an earlier-phase
    // action).
    let mut glob_universe: BTreeSet<String> = generated.clone();
    for spec in specs {
        for output in &spec.outputs {
            glob_universe.insert(output.clone());
        }
    }
    let relevant: Vec<&String> = glob_universe
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
    let mut producers: BTreeMap<&str, &BuildSpec> = BTreeMap::new();
    let mut phases: BTreeMap<&str, u32> = BTreeMap::new();
    for spec in specs {
        for output in &spec.outputs {
            producers.entry(output.as_str()).or_insert(spec);
            phases.entry(output.as_str()).or_insert(spec.instance.phase);
        }
    }
    // Byte stability is a least fixpoint over the producer
    // subgraph the relevant assets reach: an asset is unstable
    // when it changed, has no producer in the plan, is assembled
    // as a shared part, or its producer is dirty; a producer is
    // dirty when a non-recursive channel says it can rerun (see
    // producer_seed_dirty) or when a generated asset it consumes
    // is unstable. Byte stability is deliberately separate from
    // fingerprint availability: an intermediate generated asset
    // (a generated JSON a part producer reads, say) has no API
    // fingerprint and needs none; only the relevant assets, the
    // ones entering a candidate's signature fold, require a bound
    // record, checked at the end.
    //
    // Discover the subgraph first, computing each producer's
    // consumed generated assets (the propagation edges) once.
    let mut specs_by_key: BTreeMap<String, &BuildSpec> = BTreeMap::new();
    let mut closure_cache: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut consumed_by: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut consumers_of: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut subgraph_assets: BTreeSet<String> = BTreeSet::new();
    let mut stack: Vec<String> = relevant.iter().map(|asset| (*asset).clone()).collect();
    while let Some(asset) = stack.pop() {
        if !subgraph_assets.insert(asset.clone()) {
            continue;
        }
        let Some(spec) = producers.get(asset.as_str()) else {
            continue;
        };
        let key = spec.action_key();
        if consumed_by.contains_key(&key) {
            continue;
        }
        specs_by_key.insert(key.clone(), spec);
        let consumed = producer_consumed_assets(
            state,
            spec,
            &glob_universe,
            &phases,
            recorded,
            &mut closure_cache,
        );
        for member in &consumed {
            consumers_of
                .entry(member.clone())
                .or_default()
                .push(key.clone());
            stack.push(member.clone());
        }
        consumed_by.insert(key, consumed);
    }
    // Seeds.
    let mut unstable_assets: BTreeSet<String> = BTreeSet::new();
    for asset in &subgraph_assets {
        let seeded = changed.contains(asset)
            || match producers.get(asset.as_str()) {
                None => true,
                Some(spec) => crate::build::shared_parts::owns_part(spec, asset),
            };
        if seeded {
            unstable_assets.insert(asset.clone());
        }
    }
    let mut dirty_producers: BTreeSet<String> = BTreeSet::new();
    let mut asset_queue: Vec<String> = unstable_assets.iter().cloned().collect();
    for (key, spec) in &specs_by_key {
        if producer_seed_dirty(state, spec, inputs, &phases) && dirty_producers.insert(key.clone())
        {
            asset_queue.extend(spec.outputs.iter().cloned());
        }
    }
    // A cycle in the producer consumption graph has no grounding
    // proof (ADR 0056), so producers on a multi-producer cycle
    // are seeded dirty even when no channel fires. A producer
    // observing its own output cannot form such an edge: own
    // outputs are exempt from the consumed sets.
    for key in producer_cycle_members(&consumed_by, &producers) {
        if dirty_producers.insert(key.clone()) {
            asset_queue.extend(specs_by_key[key.as_str()].outputs.iter().cloned());
        }
    }
    // Propagation: an unstable asset dirties its consumers; a
    // dirty producer's outputs are unstable. Visited is tracked
    // separately from the unstable set: seed assets are already
    // in the set, and their consumers still need visiting.
    let mut visited: BTreeSet<String> = BTreeSet::new();
    while let Some(asset) = asset_queue.pop() {
        if !visited.insert(asset.clone()) {
            continue;
        }
        unstable_assets.insert(asset.clone());
        let Some(consumers) = consumers_of.get(&asset) else {
            continue;
        };
        for key in consumers {
            if dirty_producers.insert(key.clone()) {
                let spec = specs_by_key[key.as_str()];
                asset_queue.extend(spec.outputs.iter().cloned());
            }
        }
    }
    relevant
        .iter()
        .filter(|asset| {
            unstable_assets.contains(asset.as_str()) || !fingerprint_bound(state, asset)
        })
        .map(|asset| (*asset).clone())
        .collect()
}

/// The non-recursive channels that can rerun a producer in this
/// build, mirroring what dirty analysis keys on: a missing or
/// changed recorded action, a declared output that now exists
/// but was never recorded (dirty analysis reruns the action to
/// resolve that conflict), a changed glob snapshot entry or a
/// changed visible glob match, and a resolver root the change
/// taints.
fn producer_seed_dirty(
    state: &GraphState,
    spec: &BuildSpec,
    inputs: &StabilityInputs<'_>,
    phases: &BTreeMap<&str, u32>,
) -> bool {
    let changed = inputs.changed;
    let current_snapshot = inputs.current_snapshot;
    let Some(action) = state.actions.get(&spec.action_key()) else {
        return true;
    };
    if changed.contains(action.input.as_str())
        || action
            .reads
            .iter()
            .any(|asset| changed.contains(asset.as_str()))
        || action
            .outputs
            .iter()
            .any(|asset| changed.contains(asset.as_str()))
    {
        return true;
    }
    if spec.outputs.iter().any(|output| {
        !action.outputs.iter().any(|actual| actual == output)
            && current_snapshot
                .get(output)
                .is_some_and(|entry| entry.exists)
    }) {
        return true;
    }
    for glob in &action.glob_reads {
        if changed.contains(crate::snapshot::glob_asset_key(glob).as_str()) {
            return true;
        }
        if changed.iter().any(|asset| {
            asset_matches_glob(asset, &glob.package, &glob.pattern)
                && (!inputs.generated.contains(asset)
                    || phases
                        .get(asset.as_str())
                        .is_none_or(|phase| *phase < spec.instance.phase))
        }) {
            return true;
        }
    }
    action
        .resolver_entrypoints
        .iter()
        .chain(action.resolver_reads.iter())
        .any(|root| inputs.tainted.contains(root.as_str()))
}

/// The assets in the proof's universe (recorded generated
/// assets and outputs the current plan declares) that a producer
/// consumes, as propagation edges: its input and direct reads,
/// the universe members of its resolver closure, and the visible
/// universe members of its glob reads. The producer's own
/// outputs are exempt: a producer that resolves its input
/// library observes the previous version of its own output (a
/// part is a member of the library it is generated from), and
/// that self-observation carries no information beyond the
/// content checks, which already key on the outputs.
fn producer_consumed_assets(
    state: &GraphState,
    spec: &BuildSpec,
    universe: &BTreeSet<String>,
    phases: &BTreeMap<&str, u32>,
    recorded: &GraphView<'_>,
    closure_cache: &mut BTreeMap<String, BTreeSet<String>>,
) -> Vec<String> {
    let Some(action) = state.actions.get(&spec.action_key()) else {
        return Vec::new();
    };
    let own_outputs: BTreeSet<&str> = action.outputs.iter().map(String::as_str).collect();
    let roots: Vec<String> = action
        .resolver_entrypoints
        .iter()
        .cloned()
        .chain(action.resolver_reads.iter().cloned())
        .collect();
    let mut candidates: Vec<String> = vec![action.input.clone()];
    candidates.extend(action.reads.iter().cloned());
    // Only the universe members of a root's closure feed the
    // cascade, so the cache retains those per root and producers
    // sharing roots (a hub library many producers resolve) reuse
    // the walk instead of repeating it.
    for root in &roots {
        if !closure_cache.contains_key(root) {
            let members: BTreeSet<String> = forward_closure(recorded, std::slice::from_ref(root))
                .into_iter()
                .filter(|asset| universe.contains(asset))
                .collect();
            closure_cache.insert(root.clone(), members);
        }
        candidates.extend(closure_cache[root].iter().cloned());
    }
    let mut consumed: BTreeSet<String> = BTreeSet::new();
    for asset in candidates {
        if universe.contains(&asset) && !own_outputs.contains(asset.as_str()) {
            consumed.insert(asset);
        }
    }
    for glob in &action.glob_reads {
        for asset in universe {
            if asset_matches_glob(asset, &glob.package, &glob.pattern)
                && !own_outputs.contains(asset.as_str())
                && phases
                    .get(asset.as_str())
                    .is_none_or(|phase| *phase < spec.instance.phase)
            {
                consumed.insert(asset.clone());
            }
        }
    }
    consumed.into_iter().collect()
}

/// Producers sitting on a multi-producer cycle of the
/// consumption graph (producer -> producers of the generated
/// assets it consumes), by Kosaraju's algorithm over the
/// subgraph's producers. Single-producer components are not
/// cycles: own outputs never appear in consumed sets, so no
/// self-edge exists.
fn producer_cycle_members(
    consumed_by: &BTreeMap<String, Vec<String>>,
    producers: &BTreeMap<&str, &BuildSpec>,
) -> Vec<String> {
    // Edges between producer action keys.
    let mut edges: BTreeMap<&str, Vec<String>> = BTreeMap::new();
    let mut reverse: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (key, consumed) in consumed_by {
        let mut targets: Vec<String> = Vec::new();
        for asset in consumed {
            if let Some(other) = producers.get(asset.as_str()) {
                let other_key = other.action_key();
                if other_key != *key {
                    targets.push(other_key);
                }
            }
        }
        targets.sort();
        targets.dedup();
        edges.insert(key.as_str(), targets);
    }
    for (key, targets) in &edges {
        for target in targets {
            reverse.entry(target.as_str()).or_default().push(key);
        }
    }
    // First pass: finishing order by iterative DFS.
    let mut finished: Vec<&str> = Vec::new();
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for start in edges.keys() {
        if !seen.insert(start) {
            continue;
        }
        let mut stack: Vec<(&str, usize)> = vec![(start, 0)];
        while let Some((node, index)) = stack.last_mut() {
            let node = *node;
            let targets = &edges[node];
            if *index < targets.len() {
                let next = targets[*index].as_str();
                *index += 1;
                if seen.insert(next) {
                    stack.push((next, 0));
                }
            } else {
                finished.push(node);
                stack.pop();
            }
        }
    }
    // Second pass: components on the reversed graph, in reverse
    // finishing order.
    let mut assigned: BTreeSet<&str> = BTreeSet::new();
    let mut members: Vec<String> = Vec::new();
    for start in finished.iter().rev() {
        if !assigned.insert(start) {
            continue;
        }
        let mut component: Vec<&str> = vec![start];
        let mut stack: Vec<&str> = vec![start];
        while let Some(node) = stack.pop() {
            if let Some(parents) = reverse.get(node) {
                for parent in parents {
                    if assigned.insert(parent) {
                        component.push(parent);
                        stack.push(parent);
                    }
                }
            }
        }
        if component.len() > 1 {
            members.extend(component.iter().map(|key| (*key).to_owned()));
        }
    }
    members
}

/// Whether one unit's recorded fingerprint is bound to the
/// previous snapshot's bytes for that unit (see
/// [`super::fold::bound_fingerprints`]).
pub(super) fn fingerprint_bound(state: &GraphState, asset: &str) -> bool {
    state.asset_fingerprints.get(asset).is_some_and(|record| {
        state.assets.get(asset).is_some_and(|previous| {
            previous.exists && bare_digest(&previous.digest) == record.digest
        })
    })
}
