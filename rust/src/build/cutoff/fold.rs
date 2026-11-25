use super::stability::fingerprint_bound;
use crate::graph::GraphState;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// The recorded fingerprints that are baseline evidence for this
/// build: a record counts only when it is bound to the previous
/// snapshot's bytes for that unit. A worker can learn a fingerprint
/// from content newer than the snapshot a watch build commits (an
/// edit that arrives mid-build), and such a record must never stand
/// in for the earlier content.
pub(super) fn bound_fingerprints(state: &GraphState) -> BTreeMap<String, String> {
    state
        .asset_fingerprints
        .iter()
        .filter(|(asset, _)| fingerprint_bound(state, asset))
        .map(|(asset, record)| (asset.clone(), record.fingerprint.clone()))
        .collect()
}

/// For each target set, the subset of `roots` that can reach any of
/// its targets over the dep graph. The forward closure and the
/// reverse map are built once and shared by every set; each set
/// then walks the reverse graph from its own targets within the
/// region reachable from `roots`.
pub(super) fn reverse_reachable_sets<const N: usize>(
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
pub(super) fn forward_closure(graph: &GraphView<'_>, roots: &[String]) -> BTreeSet<String> {
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
pub(super) struct GraphView<'a> {
    pub(super) base: &'a BTreeMap<String, Vec<String>>,
    pub(super) overrides: Option<&'a BTreeMap<String, Vec<String>>>,
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
pub(super) struct FingerprintView<'a> {
    pub(super) base: &'a BTreeMap<String, String>,
    pub(super) overrides: Option<&'a BTreeMap<String, String>>,
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
pub(super) fn fold_all(
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
pub(super) fn fold_map(
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
