//! Shared-library planning and phase coordination. Contribution lookup and
//! ownership are indexed once; source edits remain transaction-local.
use super::transaction::PendingTransaction;
use crate::builder::ConfiguredBuilder;
use crate::graph::GraphState;
use crate::plan::{BuildAction, BuildSpec};
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::sync::Arc;

pub(crate) fn part_id(input: &str) -> Option<String> {
    let (package, path) = input.split_once('|')?;
    let stem = path.strip_suffix(".dart")?;
    if path.starts_with("_br_/") || path.starts_with("lib/_br_/") {
        return None;
    }
    Some(if let Some(rest) = stem.strip_prefix("lib/") {
        format!("{package}|lib/_br_/{rest}.part.dart")
    } else {
        format!("{package}|_br_/{stem}.part.dart")
    })
}

pub(crate) fn owns_part(spec: &BuildSpec, asset: &str) -> bool {
    spec.instance.builder.adds_to_library && part_id(&spec.input).as_deref() == Some(asset)
}

pub(super) fn declare(specs: &mut [BuildSpec]) -> io::Result<()> {
    let mut owners = BTreeMap::new();
    let mut keys = BTreeSet::new();
    let declared: BTreeSet<_> = specs
        .iter()
        .flat_map(|spec| spec.outputs.iter().cloned())
        .collect();
    for (index, spec) in specs
        .iter()
        .enumerate()
        .filter(|(_, spec)| spec.instance.builder.adds_to_library)
    {
        if !keys.insert((spec.input.clone(), spec.instance.builder.id.clone())) {
            return Err(io::Error::other(
                "duplicate shared-part builder for a library",
            ));
        }
        if let Some(part) = part_id(&spec.input) {
            owners.insert(part, index);
        }
    }
    for (part, index) in owners {
        if declared.contains(&part) {
            return Err(io::Error::other(format!(
                "shared part conflicts with a builder output: {part}"
            )));
        }
        let spec = &specs[index];
        let mut outputs = spec.outputs.clone();
        outputs.push(part);
        specs[index] = Arc::new(BuildAction {
            instance: spec.instance.clone(),
            input: spec.input.clone(),
            outputs,
        });
    }
    Ok(())
}

struct Contributor {
    key: String,
    phase: u32,
}

struct Library {
    owner: BuildSpec,
    generated_input: bool,
    contributors: Vec<Contributor>,
}

/// Immutable indexes shared by phase execution and directive replay.
#[derive(Default)]
pub(super) struct SharedLibraryPlan {
    libraries: BTreeMap<String, Library>,
    phase_indices: BTreeMap<(String, u32), u32>,
}

impl SharedLibraryPlan {
    pub(super) fn new(specs: &[BuildSpec], builders: &[ConfiguredBuilder]) -> Self {
        let generated: BTreeSet<_> = specs.iter().flat_map(|spec| &spec.outputs).collect();
        let mut libraries: BTreeMap<String, Library> = BTreeMap::new();
        for spec in specs
            .iter()
            .filter(|spec| spec.instance.builder.adds_to_library)
        {
            let Some(part) = part_id(&spec.input) else {
                continue;
            };
            let library = libraries.entry(part.clone()).or_insert_with(|| Library {
                owner: spec.clone(),
                generated_input: generated.contains(&spec.input),
                contributors: Vec::new(),
            });
            if spec.outputs.contains(&part) {
                library.owner = spec.clone();
            }
            library.contributors.push(Contributor {
                key: spec.action_key(),
                phase: spec.instance.phase,
            });
        }
        for library in libraries.values_mut() {
            library.contributors.sort_by_key(|entry| entry.phase);
        }
        let mut phases_by_package = BTreeMap::<&str, BTreeMap<u32, u32>>::new();
        for builder in builders
            .iter()
            .filter(|builder| builder.definition.adds_to_library)
        {
            *phases_by_package
                .entry(&builder.package)
                .or_default()
                .entry(builder.phase)
                .or_default() += 1;
        }
        let phase_indices = phases_by_package
            .into_iter()
            .flat_map(|(package, phases)| {
                let mut next = 0;
                phases.into_iter().map(move |(phase, count)| {
                    let index = next;
                    next += count;
                    ((package.to_owned(), phase), index)
                })
            })
            .collect();
        Self {
            libraries,
            phase_indices,
        }
    }

    pub(super) fn phase_index(&self, package: &str, phase: u32) -> Option<u32> {
        self.phase_indices
            .get(&(package.to_owned(), phase))
            .copied()
    }

    pub(super) fn is_empty(&self) -> bool {
        self.libraries.is_empty()
    }
}

pub(super) struct SharedLibraryCoordinator<'a> {
    plan: &'a SharedLibraryPlan,
    visible_counts: BTreeMap<&'a str, usize>,
}

impl<'a> SharedLibraryCoordinator<'a> {
    pub(super) fn new(plan: &'a SharedLibraryPlan) -> Self {
        Self {
            plan,
            visible_counts: BTreeMap::new(),
        }
    }

    /// Reassemble only when crossing a contributing phase. Replays move back
    /// to phase zero, so the same mechanism also removes future contributions.
    pub(super) fn refresh(
        &mut self,
        state: &GraphState,
        pending: &mut PendingTransaction,
        phase: Option<u32>,
    ) {
        for (id, library) in &self.plan.libraries {
            let count = library
                .contributors
                .partition_point(|entry| phase.is_some_and(|phase| entry.phase <= phase));
            if self.visible_counts.get(id.as_str()) == Some(&count) {
                continue;
            }
            self.visible_counts.insert(id.as_str(), count);
            let entries: Vec<_> = library.contributors[..count]
                .iter()
                .filter_map(|entry| {
                    pending
                        .action(&entry.key, state)?
                        .shared_part
                        .as_ref()
                        .filter(|part| !part.source.is_empty())
                })
                .collect();
            let bytes: Option<Arc<[u8]>> = entries.first().map(|first| {
                let mut content = first.header.clone();
                for entry in &entries {
                    content.push_str(&entry.imports);
                }
                for entry in &entries {
                    content.push_str(&entry.source);
                }
                Arc::from(content.into_bytes())
            });
            match bytes {
                Some(bytes) => {
                    let changed = pending.overlay.get(id) != Some(&bytes)
                        || pending.deleted_overlay.contains(id);
                    pending.overlay.insert(id.clone(), bytes);
                    pending.deleted_overlay.remove(id);
                    if changed {
                        pending.resolver.resolver_updated.insert(id.clone());
                        pending.resolver.resolver_deleted.remove(id);
                    }
                }
                None => {
                    pending.overlay.remove(id);
                    if pending.deleted_overlay.insert(id.clone()) {
                        pending.resolver.resolver_deleted.insert(id.clone());
                        pending.resolver.resolver_updated.remove(id);
                    }
                }
            }
        }
    }

    /// Finalize ownership and return exactly the libraries whose source changed.
    pub(super) fn finish(
        &mut self,
        workspace: &Workspace,
        state: &GraphState,
        pending: &mut PendingTransaction,
    ) -> io::Result<BTreeSet<String>> {
        self.refresh(state, pending, Some(u32::MAX));
        let mut edited = BTreeSet::new();
        for (id, library) in &self.plan.libraries {
            let spec = &library.owner;
            if pending.deleted_overlay.contains(&spec.input) {
                return Err(io::Error::other(
                    "post-process deletion of a shared-library primary input is outside the supported subset",
                ));
            }
            // Phase visibility may rebuild views for clean libraries too; only
            // libraries with a fresh contribution need publication/graph edits.
            let Some(evidence) = pending.source_edit_evidence.remove(&spec.input) else {
                continue;
            };
            let content = pending.overlay.get(id).cloned();
            let key = spec.action_key();
            let owner = match pending.pending_actions.entry(key) {
                std::collections::btree_map::Entry::Occupied(entry) => entry.into_mut(),
                std::collections::btree_map::Entry::Vacant(entry) => {
                    let owner = state
                        .actions
                        .get(entry.key())
                        .cloned()
                        .ok_or_else(|| io::Error::other("missing shared-part action result"))?;
                    entry.insert(owner)
                }
            };
            owner.outputs.retain(|output| output != id);
            owner.output_digests.remove(id);
            pending.pending_outputs.remove(id);
            if let Some(bytes) = &content {
                let output = super::transaction::PendingOutput::new(
                    spec.instance.builder.clone(),
                    bytes.clone(),
                );
                owner.outputs.push(id.clone());
                owner
                    .output_digests
                    .insert(id.clone(), output.digest.clone());
                pending.pending_outputs.insert(id.clone(), output);
            } else {
                pending
                    .pending_deletions
                    .push((spec.instance.builder.clone(), id.clone()));
            }
            if library.generated_input {
                continue;
            }
            let replacement = if content.is_some() {
                &evidence.with_part
            } else {
                &evidence.without_part
            };
            if let Some(replacement) = replacement
                && pending.edit_source(workspace, &spec.input, &evidence.original, replacement)?
            {
                edited.insert(spec.input.clone());
            }
        }
        Ok(edited)
    }
}
