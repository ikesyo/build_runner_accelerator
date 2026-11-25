use super::{ActionState, GraphState};
use crate::snapshot::{Snapshot, glob_asset_key};
use std::collections::BTreeMap;

pub(crate) fn reverse_resolver_deps(
    dep_graph: &BTreeMap<String, Vec<String>>,
) -> BTreeMap<&str, Vec<&str>> {
    let mut parents: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (node, deps) in dep_graph {
        for dep in deps {
            parents.entry(dep.as_str()).or_default().push(node.as_str());
        }
    }
    parents
}

impl GraphState {
    /// Precomputed change information shared by every per-action dirty
    /// check: the assets whose snapshot entry differs between the previous
    /// and current runs, plus the reverse closure of that set through
    /// [`GraphState::resolver_dep_graph`]. An entrypoint in `tainted` means
    /// something it transitively depends on changed, which is exactly what
    /// expanding `action_entrypoint_deps` per action was checking — once
    /// instead of per action.
    pub fn dirty_context<'a>(&'a self, current_assets: &'a Snapshot) -> DirtyContext<'a> {
        let mut changed = std::collections::HashSet::new();
        // Both snapshots are ordered. Merge them once instead of searching
        // either tree for every asset; additions and removals are changes too.
        let mut previous = self.assets.iter().peekable();
        let mut current = current_assets.iter().peekable();
        while let (Some((old_asset, old)), Some((new_asset, new))) =
            (previous.peek(), current.peek())
        {
            match old_asset.cmp(new_asset) {
                std::cmp::Ordering::Less => {
                    changed.insert(old_asset.as_str());
                    previous.next();
                }
                std::cmp::Ordering::Greater => {
                    changed.insert(new_asset.as_str());
                    current.next();
                }
                std::cmp::Ordering::Equal => {
                    if old.exists != new.exists || old.digest != new.digest {
                        changed.insert(old_asset.as_str());
                    }
                    previous.next();
                    current.next();
                }
            }
        }
        changed.extend(previous.map(|(asset, _)| asset.as_str()));
        changed.extend(current.map(|(asset, _)| asset.as_str()));
        // The reverse closure of an empty change set is empty. In particular,
        // no-op builds need no reverse-edge map or per-node Vec allocations.
        if changed.is_empty() {
            return DirtyContext {
                changed,
                tainted: std::collections::HashSet::new(),
                parents: None,
            };
        }
        let parents = reverse_resolver_deps(&self.resolver_dep_graph);
        let mut tainted = std::collections::HashSet::new();
        let mut stack: Vec<&str> = changed.iter().copied().collect();
        while let Some(asset) = stack.pop() {
            if !tainted.insert(asset) {
                continue;
            }
            if let Some(dependents) = parents.get(asset) {
                stack.extend(dependents.iter().copied());
            }
        }
        DirtyContext {
            changed,
            tainted,
            parents: Some(parents),
        }
    }

    #[cfg(test)]
    pub fn changed_since_previous(
        &self,
        action: &ActionState,
        current_assets: &Snapshot,
        current_output_digests: &BTreeMap<String, String>,
    ) -> bool {
        let context = self.dirty_context(current_assets);
        self.changed_since_previous_with(
            action,
            &context,
            current_assets,
            current_output_digests,
            false,
        )
    }

    /// Compares a recorded action with the old/current snapshots and the
    /// precomputed resolver closure. Reads and input are compared by presence
    /// and digest, glob dependencies by membership snapshot, and outputs by
    /// recorded/current output digest; any difference requires execution.
    pub fn changed_since_previous_with(
        &self,
        action: &ActionState,
        context: &DirtyContext<'_>,
        current_assets: &Snapshot,
        current_output_digests: &BTreeMap<String, String>,
        resolver_explained: bool,
    ) -> bool {
        // The primary input and direct reads are content observations:
        // they always key the action. Resolver observations are keyed
        // by content too, unless `resolver_explained` reports that the
        // action's effective API signature is unchanged (ADR 0056), in
        // which case they cannot have observed anything new.
        let direct_changed = std::iter::once(action.input.as_str())
            .chain(action.reads.iter().map(String::as_str))
            .any(|asset| context.changed.contains(asset));
        let resolver_changed = action
            .resolver_reads
            .iter()
            .any(|asset| context.changed.contains(asset.as_str()))
            || action
                .resolver_entrypoints
                .iter()
                .any(|entrypoint| context.tainted.contains(entrypoint.as_str()));
        direct_changed
            || (resolver_changed && !resolver_explained)
            || action.glob_reads.iter().any(|glob| {
                let key = glob_asset_key(glob);
                let previous = self
                    .assets
                    .get(&key)
                    .map(|entry| (entry.exists, entry.digest.as_str()));
                let current = current_assets
                    .get(&key)
                    .map(|entry| (entry.exists, entry.digest.as_str()));
                previous != current
            })
            || action.outputs.iter().any(|output| {
                action.output_digests.get(output) != current_output_digests.get(output)
            })
    }
}

/// Shared per-pass dirty-check state: `changed` holds the assets whose
/// snapshot entry differs between the previous and current runs, and
/// `tainted` is the reverse closure of `changed` through the resolver
/// dependency graph (assets that transitively depend on a changed one).
pub struct DirtyContext<'a> {
    pub(super) changed: std::collections::HashSet<&'a str>,
    pub(super) tainted: std::collections::HashSet<&'a str>,
    pub(super) parents: Option<BTreeMap<&'a str, Vec<&'a str>>>,
}

impl<'a> DirtyContext<'a> {
    /// Assets whose snapshot entry differs (see [`GraphState::dirty_context`]).
    pub fn changed(&self) -> &std::collections::HashSet<&str> {
        &self.changed
    }

    /// Assets whose resolver dependency closure contains a changed asset.
    pub fn tainted(&self) -> &std::collections::HashSet<&str> {
        &self.tainted
    }

    /// Reverse resolver dependency map built during taint propagation, or
    /// `None` when the empty-change fast path skipped constructing it.
    pub fn reverse_deps(&self) -> Option<&BTreeMap<&'a str, Vec<&'a str>>> {
        self.parents.as_ref()
    }
}
