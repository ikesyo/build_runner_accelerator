//! Native shared-part aggregation. Dart supplies upstream-formatted, escaped
//! sections; Rust owns phase visibility, incremental evidence and publication.
use super::transaction::PendingTransaction;
use crate::graph::{ActionState, GraphState};
use crate::plan::{BuildAction, BuildSpec};
use crate::workspace::Workspace;
use std::collections::BTreeMap;
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
    let mut keys = std::collections::BTreeSet::new();
    for (index, spec) in specs.iter().enumerate() {
        if !spec.instance.builder.adds_to_library {
            continue;
        }
        if !keys.insert((spec.input.clone(), spec.instance.builder.id.clone())) {
            return Err(io::Error::other(
                "duplicate shared-part builder for a library",
            ));
        }
        let Some(part) = part_id(&spec.input) else {
            continue;
        };
        owners.insert(part, index);
    }
    for (part, index) in owners {
        if specs.iter().any(|spec| spec.outputs.contains(&part)) {
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

fn action<'a>(
    spec: &BuildSpec,
    state: &'a GraphState,
    pending: &'a PendingTransaction,
) -> Option<&'a ActionState> {
    let key = spec.action_key();
    pending
        .pending_actions
        .iter()
        .rev()
        .find(|(id, _)| id == &key)
        .map(|(_, action)| action)
        .or_else(|| state.actions.get(&key))
}

fn contents(
    specs: &[BuildSpec],
    state: &GraphState,
    pending: &PendingTransaction,
    phase: Option<u32>,
) -> BTreeMap<String, Option<Arc<[u8]>>> {
    let mut parts = BTreeMap::<String, Vec<_>>::new();
    for spec in specs
        .iter()
        .filter(|spec| spec.instance.builder.adds_to_library)
    {
        let Some(id) = part_id(&spec.input) else {
            continue;
        };
        let entries = parts.entry(id).or_default();
        if phase.is_none_or(|phase| spec.instance.phase > phase) {
            continue;
        }
        if let Some(part) =
            action(spec, state, pending).and_then(|action| action.shared_part.as_ref())
            && !part.source.is_empty()
        {
            entries.push((spec.instance.phase, part));
        }
    }
    parts
        .into_iter()
        .map(|(id, mut entries)| {
            entries.sort_by_key(|(phase, _)| *phase);
            let bytes = entries.first().map(|(_, first)| {
                let mut content = first.header.clone();
                for (_, entry) in &entries {
                    content.push_str(&entry.imports);
                }
                for (_, entry) in &entries {
                    content.push_str(&entry.source);
                }
                Arc::from(content.into_bytes())
            });
            (id, bytes)
        })
        .collect()
}

pub(super) fn refresh(
    specs: &[BuildSpec],
    state: &GraphState,
    pending: &mut PendingTransaction,
    phase: Option<u32>,
) {
    for (id, content) in contents(specs, state, pending, phase) {
        match content {
            Some(bytes) => {
                let changed = pending.overlay.get(&id) != Some(&bytes)
                    || pending.deleted_overlay.contains(&id);
                pending.overlay.insert(id.clone(), bytes);
                pending.deleted_overlay.remove(&id);
                if changed {
                    pending.resolver.resolver_updated.insert(id.clone());
                    pending.resolver.resolver_deleted.remove(&id);
                }
            }
            None => {
                pending.overlay.remove(&id);
                if pending.deleted_overlay.insert(id.clone()) {
                    pending.resolver.resolver_deleted.insert(id.clone());
                    pending.resolver.resolver_updated.remove(&id);
                }
            }
        }
    }
}

/// Stage final parts and source edits. A source edit requests a complete replay
/// against the overlay before anything is published.
pub(super) fn finish(
    workspace: &Workspace,
    specs: &[BuildSpec],
    state: &GraphState,
    pending: &mut PendingTransaction,
) -> io::Result<bool> {
    let parts = contents(specs, state, pending, Some(u32::MAX));
    let mut edited = false;
    for spec in specs
        .iter()
        .filter(|spec| spec.instance.builder.adds_to_library)
    {
        let Some(id) = part_id(&spec.input) else {
            continue;
        };
        if !spec.outputs.contains(&id) {
            continue;
        } // final owner
        let content = parts.get(&id).and_then(Clone::clone);
        let mut owner = action(spec, state, pending)
            .cloned()
            .ok_or_else(|| io::Error::other("missing shared-part action result"))?;
        owner.outputs.retain(|output| output != &id);
        owner.output_digests.remove(&id);
        pending
            .pending_outputs
            .retain(|(_, output, _)| output != &id);
        if let Some(bytes) = &content {
            owner.outputs.push(id.clone());
            owner
                .output_digests
                .insert(id.clone(), crate::digest::digest_bytes(bytes));
            pending.pending_outputs.push((
                spec.instance.builder.clone(),
                id.clone(),
                bytes.clone(),
            ));
        } else {
            pending
                .pending_deletions
                .push((spec.instance.builder.clone(), id));
        }
        if pending.deleted_overlay.contains(&spec.input) {
            return Err(io::Error::other(
                "post-process deletion of a shared-library primary input is outside the supported subset",
            ));
        }
        pending.pending_actions.push((spec.action_key(), owner));
        // Generated libraries belong to their producer; stock never edits them.
        if specs
            .iter()
            .any(|other| other.outputs.contains(&spec.input))
        {
            continue;
        }
        let evidence = specs
            .iter()
            .rev()
            .filter(|other| other.input == spec.input && other.instance.builder.adds_to_library)
            .filter_map(|other| action(other, state, pending)?.shared_part.as_ref())
            .next();
        let Some(evidence) = evidence else {
            continue;
        };
        let replacement = if content.is_some() {
            &evidence.with_part
        } else {
            &evidence.without_part
        };
        let Some(replacement) = replacement else {
            continue;
        };
        let original = evidence.original.as_bytes();
        let current = pending
            .overlay
            .get(&spec.input)
            .cloned()
            .map(Ok)
            .unwrap_or_else(|| {
                std::fs::read(workspace.path_for_asset(&spec.input)?).map(Arc::from)
            })?;
        if current.as_ref() != original {
            return Err(io::Error::other(
                "shared-part source changed during the build; retry",
            ));
        }
        let bytes: Arc<[u8]> = Arc::from(replacement.as_bytes());
        if current == bytes {
            continue;
        }
        pending
            .source_edits
            .entry(spec.input.clone())
            .and_modify(|edit| edit.updated = bytes.clone())
            .or_insert(super::transaction::SourceEdit {
                original: current,
                updated: bytes.clone(),
            });
        pending.overlay.insert(spec.input.clone(), bytes);
        pending.resolver.resolver_updated.insert(spec.input.clone());
        pending.resolver.resolver_deleted.remove(&spec.input);
        edited = true;
    }
    Ok(edited)
}
