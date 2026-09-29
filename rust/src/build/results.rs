use crate::builder::{BuildTo, BuilderKind};
use crate::digest::digest_bytes;
use crate::graph::{ActionState, GraphState};
use crate::plan::BuildSpec;
use crate::protocol::BuildResult;
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;

use super::transaction::PendingTransaction;

/// Record the build_runner equivalent of a generated primary input that was
/// planned but not emitted by its producer. Keeping the empty action in the
/// graph makes the missing-output state stable across no-op builds and removes
/// stale outputs from a previous successful run at the same commit boundary as
/// ordinary Builder results.
pub(super) fn record_missing_primary_input(
    workspace: &Workspace,
    state: &GraphState,
    spec: &BuildSpec,
    pending: &mut PendingTransaction,
) -> io::Result<()> {
    let key = spec.action_key();
    let mut outputs_to_delete = state
        .actions
        .get(&key)
        .map(|action| action.outputs.clone())
        .unwrap_or_default();
    for output in &spec.outputs {
        if !outputs_to_delete.contains(output) {
            outputs_to_delete.push(output.clone());
        }
    }
    for output in outputs_to_delete {
        pending.deleted_overlay.insert(output.clone());
        pending.overlay.remove(&output);
        if spec.builder.build_to == BuildTo::Source {
            pending.resolver.resolver_deleted.insert(output.clone());
            pending.resolver.resolver_updated.remove(&output);
        } else {
            pending.resolver.resolver_cache_deleted.insert(output.clone());
            pending.resolver.resolver_cache_updated.remove(&output);
        }
        if workspace.asset_exists_at(&output, spec.builder.build_to)? {
            pending
                .pending_deletions
                .push((spec.builder.clone(), output));
        }
    }
    pending.pending_actions.push((
        key,
        ActionState {
            builder: spec.builder.id.to_owned(),
            input: spec.input.clone(),
            reads: Vec::new(),
            resolver_reads: Vec::new(),
            resolver_entrypoints: Vec::new(),
            glob_reads: Vec::new(),
            outputs: Vec::new(),
            output_digests: BTreeMap::new(),
            status: "skipped_missing_input".to_owned(),
        },
    ));
    Ok(())
}

pub(super) fn record_build_result(
    workspace: &Workspace,
    state: &GraphState,
    spec: &BuildSpec,
    result: BuildResult,
    pending: &mut PendingTransaction,
) -> io::Result<()> {
    let builder = spec.builder.as_ref();
    if result.status != "success" && result.status != "not_triggered" {
        return Err(io::Error::other(
            result.error.unwrap_or_else(|| "Builder failed".to_owned()),
        ));
    }
    if result.status == "not_triggered" && builder.kind != BuilderKind::Normal {
        return Err(io::Error::other(format!(
            "trigger skip is only supported for normal builders: {}",
            spec.builder.id
        )));
    }
    for diagnostic in &result.diagnostics {
        eprintln!("{}: {}", diagnostic.level, diagnostic.message);
    }
    if !result.deleted.is_empty() {
        if builder.kind != BuilderKind::PostProcess {
            return Err(io::Error::other(format!(
                "deletePrimaryInput is only supported for post-process builders: {}",
                result.deleted.join(", ")
            )));
        }
        for deleted in &result.deleted {
            if deleted != &spec.input {
                return Err(io::Error::other(format!(
                    "post-process builder {} deleted an asset other than its primary input: {}",
                    spec.builder.id, deleted
                )));
            }
            pending.deleted_overlay.insert(deleted.clone());
            pending.overlay.remove(deleted);
            if builder.build_to == BuildTo::Source {
                pending.resolver.resolver_deleted.insert(deleted.clone());
                pending.resolver.resolver_updated.remove(deleted);
            } else {
                pending.resolver.resolver_cache_deleted.insert(deleted.clone());
                pending.resolver.resolver_cache_updated.remove(deleted);
            }
            pending.pending_deletions.push((spec.builder.clone(), deleted.clone()));
        }
    }

    let allowed = spec.outputs.iter().cloned().collect::<BTreeSet<_>>();
    for generated in &result.outputs {
        if builder.kind == BuilderKind::Normal && !allowed.contains(&generated.asset) {
            return Err(io::Error::other(format!(
                "unexpected output from {}: {}",
                spec.builder.id, generated.asset
            )));
        }
        if builder.kind == BuilderKind::PostProcess {
            let (package, path) = generated.asset.split_once('|').ok_or_else(|| {
                io::Error::other(format!(
                    "post-process output is not a valid AssetId: {}",
                    generated.asset
                ))
            })?;
            if package != spec.package
                || path.is_empty()
                || path.starts_with('/')
                || path.contains("..")
                || generated.asset == spec.input
            {
                return Err(io::Error::other(format!(
                    "invalid post-process output from {}: {}",
                    spec.builder.id, generated.asset
                )));
            }
            let previous_outputs = state.actions.get(&spec.action_key())
                .map(|action| action.outputs.contains(&generated.asset))
                .unwrap_or(false);
            if !previous_outputs
                && !pending.deleted_overlay.contains(&generated.asset)
                && (pending.overlay.contains_key(&generated.asset)
                    || workspace.asset_exists_or_cache(&generated.asset)?)
            {
                return Err(io::Error::other(format!(
                    "post-process output conflicts with an existing asset: {}",
                    generated.asset
                )));
            }
        }
        pending.overlay.insert(generated.asset.clone(), generated.bytes.clone());
        pending.deleted_overlay.remove(&generated.asset);
        if builder.build_to == BuildTo::Source {
            pending.resolver.resolver_updated.insert(generated.asset.clone());
            pending.resolver.resolver_deleted.remove(&generated.asset);
        } else {
            pending.resolver.resolver_cache_updated.insert(generated.asset.clone());
            pending.resolver.resolver_cache_deleted.remove(&generated.asset);
        }
        pending.pending_outputs.push((
            spec.builder.clone(),
            generated.asset.clone(),
            generated.bytes.clone(),
        ));
    }
    let mut output_digests = BTreeMap::new();
    let actual_outputs = result
        .outputs
        .iter()
        .map(|output| output.asset.as_str())
        .collect::<BTreeSet<_>>();
    // build_runner permits a normal builder to declare an output mapping and
    // then emit no output for a particular input. Remove outputs recorded by
    // the previous action when that happens.
    if builder.kind == BuilderKind::Normal || builder.output_is_optional {
        if let Some(previous) = state.actions.get(&spec.action_key()) {
            for previous_output in &previous.outputs {
                if !actual_outputs.contains(previous_output.as_str()) {
                    pending.deleted_overlay.insert(previous_output.clone());
                    if builder.build_to == BuildTo::Source {
                        pending.resolver.resolver_deleted.insert(previous_output.clone());
                        pending.resolver.resolver_updated.remove(previous_output);
                    } else {
                        pending.resolver.resolver_cache_deleted.insert(previous_output.clone());
                        pending.resolver.resolver_cache_updated.remove(previous_output);
                    }
                    pending.pending_deletions.push((spec.builder.clone(), previous_output.clone()));
                }
            }
        }
    }
    if builder.kind == BuilderKind::Normal {
        // A declared output may already exist on disk even when the previous
        // graph did not record it. Keep it out of later phases and remove it
        // at the commit boundary when this action emits nothing.
        for expected in &spec.outputs {
            if actual_outputs.contains(expected.as_str()) {
                continue;
            }
            pending.deleted_overlay.insert(expected.clone());
            if builder.build_to == BuildTo::Source {
                pending.resolver.resolver_deleted.insert(expected.clone());
                pending.resolver.resolver_updated.remove(expected);
            } else {
                pending.resolver.resolver_cache_deleted.insert(expected.clone());
                pending.resolver.resolver_cache_updated.remove(expected);
            }
            if workspace.asset_exists_at(expected, builder.build_to)? {
                pending.pending_deletions.push((spec.builder.clone(), expected.clone()));
            }
        }
    }
    for generated in &result.outputs {
        output_digests.insert(generated.asset.clone(), digest_bytes(&generated.bytes));
    }
    pending.pending_actions.push((
        spec.action_key(),
        ActionState {
            builder: spec.builder.id.to_owned(),
            input: spec.input.clone(),
            reads: result.reads,
            resolver_reads: result.resolver_reads,
            resolver_entrypoints: result.resolver_entrypoints,
            glob_reads: result.glob_reads,
            outputs: result
                .outputs
                .into_iter()
                .map(|output| output.asset)
                .collect(),
            output_digests,
            status: result.status,
        },
    ));
    Ok(())
}
