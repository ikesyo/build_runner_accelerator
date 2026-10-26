use crate::builder::RustBuildConfig;
use crate::graph::{GRAPH_SCHEMA_VERSION, GraphState};
use crate::metrics::graph_file_size;
use crate::plan::output_path;
use crate::snapshot::AssetSnapshot;
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::Path;
use std::time::Instant;

use super::snapshot;
use super::transaction::PendingTransaction;

pub(super) struct GraphSaveMetrics {
    pub(super) graph_save_us: u128,
    pub(super) graph_save_bytes: u64,
    pub(super) graph_save_skipped: bool,
    pub(super) post_scan_us: u128,
    pub(super) post_assets_us: u128,
}

/// All plan and staged-state evidence needed to publish one successful build.
pub(super) struct CommitInputs<'a> {
    pub(super) only_check: bool,
    pub(super) keep_modified_outputs: bool,
    /// Only the explicit CLI policy creates persistent demand-reuse history.
    pub(super) explicit_keep_modified_outputs: bool,
    pub(super) workspace: &'a Workspace,
    pub(super) state_path: &'a Path,
    pub(super) build_config: &'a RustBuildConfig,
    pub(super) config_digest: String,
    pub(super) scanned_packages: &'a BTreeSet<String>,
    pub(super) expected_outputs: BTreeSet<String>,
    /// Ordinary watch builds must keep source evidence from build start so
    /// edits that arrive after an action read are still dirty next cycle.
    pub(super) source_snapshot_evidence:
        Option<(&'a crate::snapshot::Snapshot, &'a BTreeSet<String>)>,
    /// Filtered watch builds must not mark source changes that arrived after
    /// their initial snapshot as already incorporated by the completed build.
    pub(super) filtered_snapshot_evidence: Option<(
        &'a crate::snapshot::Snapshot,
        &'a BTreeSet<String>,
        &'a crate::snapshot::Snapshot,
    )>,
    pub(super) transaction: PendingTransaction,
}

/// Persists changed configuration/snapshot metadata without running actions.
/// The graph is left untouched on an exact metadata match; read, encode, and
/// filesystem errors propagate to the caller.
pub(super) fn save_no_work(
    state: &mut GraphState,
    state_path: &Path,
    config_digest: &str,
    current_snapshot: BTreeMap<String, AssetSnapshot>,
    graph_load_bytes: u64,
) -> io::Result<GraphSaveMetrics> {
    let _no_work = crate::wall::Span::new("no_work_metadata");
    let skipped = !state.update_metadata_if_changed(config_digest, current_snapshot);
    if skipped {
        return Ok(GraphSaveMetrics {
            graph_save_us: 0,
            graph_save_bytes: graph_load_bytes,
            graph_save_skipped: true,
            post_scan_us: 0,
            post_assets_us: 0,
        });
    }
    let graph_save_started = Instant::now();
    let save = crate::wall::Span::new("graph_save");
    state.save(state_path)?;
    drop(save);
    Ok(GraphSaveMetrics {
        graph_save_us: graph_save_started.elapsed().as_micros(),
        graph_save_bytes: graph_file_size(state_path),
        graph_save_skipped: false,
        post_scan_us: 0,
        post_assets_us: 0,
    })
}

/// Publishes staged outputs, deletions, and graph state after all actions pass.
/// Publication is protected by an undo journal, recovered before graph reuse.
/// Individual files are atomic; the output tree is not simultaneously atomic.
pub(super) fn commit(
    state: &mut GraphState,
    inputs: CommitInputs<'_>,
) -> io::Result<GraphSaveMetrics> {
    let path = inputs.state_path.to_owned();
    commit_inner(state, inputs).map_err(|error| {
        if super::recovery::pending(&path) {
            io::Error::other(format!("commit publication failed: {error}. Undo journal preserved; retry the same native command to restore the previous outputs and graph before rebuilding. Do not clear native state."))
        } else {
            error
        }
    })
}

fn commit_inner(state: &mut GraphState, inputs: CommitInputs<'_>) -> io::Result<GraphSaveMetrics> {
    // Stock verify publishes neither artifacts nor graph, even on success.
    if inputs.only_check {
        verify_outputs(state, &inputs)?;
        return Ok(GraphSaveMetrics {
            graph_save_us: 0,
            graph_save_bytes: graph_file_size(inputs.state_path),
            graph_save_skipped: true,
            post_scan_us: 0,
            post_assets_us: 0,
        });
    }
    let CommitInputs {
        only_check: _,
        keep_modified_outputs,
        explicit_keep_modified_outputs,
        workspace,
        state_path,
        build_config,
        config_digest,
        scanned_packages,
        expected_outputs,
        source_snapshot_evidence,
        filtered_snapshot_evidence,
        transaction,
    } = inputs;

    let undo = crate::wall::Span::new("commit_undo_prepare");
    let mut changes = BTreeMap::new();
    if transaction.clean_artifact_tree {
        collect_cache_deletions(
            &workspace
                .root
                .join(".dart_tool/build_runner_accelerator/cache"),
            &mut changes,
        )?;
    }
    for (location, asset) in &transaction.pending_location_deletions {
        let path = match location {
            crate::builder::BuildTo::Source => workspace.path_for_asset(asset)?,
            crate::builder::BuildTo::Cache => workspace.cache_path_for_asset(asset)?,
        };
        changes.insert(path, None);
    }
    for (builder, asset) in &transaction.pending_deletions {
        changes.insert(output_path(workspace, builder, asset)?, None);
    }
    for (_, action) in &transaction.deleted_actions {
        let builder = build_config
            .definition(&action.builder)
            .ok_or_else(|| io::Error::other("previous builder unavailable"))?;
        for asset in &action.outputs {
            if !expected_outputs.contains(asset) {
                changes.insert(output_path(workspace, builder, asset)?, None);
            }
        }
    }
    for (asset, (builder, bytes)) in &transaction.pending_outputs {
        changes.insert(
            output_path(workspace, builder, asset)?,
            Some(crate::digest::digest_bytes(bytes)),
        );
    }
    for (asset, edit) in &transaction.source_edits {
        let (original, bytes) = (&edit.original, &edit.updated);
        let path = workspace.path_for_asset(asset)?;
        if fs::read(&path)?.as_slice() != original.as_ref() {
            return Err(io::Error::other(
                "shared-part source changed before publication; retry",
            ));
        }
        changes.insert(path, Some(crate::digest::digest_bytes(bytes)));
    }
    let journaled = !changes.is_empty();
    if journaled {
        super::recovery::prepare(state_path, changes)?;
    }
    drop(undo);

    // No phase or asset RPC can read the overlay once all actions have succeeded.
    // Release its references so committing each output can free its buffer.
    let written_outputs: BTreeSet<_> = if keep_modified_outputs {
        transaction.pending_outputs.keys().cloned().collect()
    } else {
        BTreeSet::new()
    };
    drop(transaction.overlay);
    let outputs = crate::wall::Span::new("output_commit");
    boundary("before_deletions")?;
    // Commit only after every dirty action succeeded. Cache-built part files
    // are kept below .dart_tool and are visible to later phases through the
    // overlay and the cache-aware reader.
    if transaction.clean_artifact_tree {
        let path = workspace
            .root
            .join(".dart_tool/build_runner_accelerator/cache");
        match fs::remove_dir_all(path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    for (location, asset) in transaction.pending_location_deletions {
        let path = match location {
            crate::builder::BuildTo::Source => workspace.path_for_asset(&asset)?,
            crate::builder::BuildTo::Cache => workspace.cache_path_for_asset(&asset)?,
        };
        remove_output(&path)?;
    }
    for (builder, asset) in transaction.pending_deletions {
        let path = output_path(workspace, builder.as_ref(), &asset)?;
        remove_output(&path)?;
    }
    // Remove obsolete action outputs before publishing new results: a new
    // post-process action may reuse a dynamic output from a deleted action.
    for (action_key, action) in transaction.deleted_actions {
        let builder = build_config
            .definition(&action.builder)
            .ok_or_else(|| io::Error::other(format!("unsupported builder: {}", action.builder)))?;
        for output in &action.outputs {
            if expected_outputs.contains(output) {
                continue;
            }
            let path = output_path(workspace, builder, output)?;
            remove_output(&path)?;
        }
        state.actions.remove(&action_key);
    }
    boundary("after_deletions")?;
    for (asset, (builder, bytes)) in transaction.pending_outputs {
        super::recovery::write_output(&output_path(workspace, builder.as_ref(), &asset)?, &bytes)?;
        boundary("after_output")?;
    }
    for (key, action) in transaction.pending_actions {
        state.actions.insert(key, action);
    }
    for (asset, edit) in &transaction.source_edits {
        let bytes = &edit.updated;
        let path = workspace.path_for_asset(asset)?;
        if fs::read(&path)?.as_slice() != edit.original.as_ref() {
            return Err(io::Error::other(
                "shared-part source changed during publication; undo evidence preserved",
            ));
        }
        super::recovery::write_output(&path, bytes)?;
        boundary("after_output")?;
    }
    for (key, inputs) in transaction.pending_stock_inputs {
        if let Some(inputs) = inputs {
            state.stock_input_order.insert(key, inputs);
        } else {
            state.stock_input_order.remove(&key);
        }
    }
    for (key, globs) in transaction.pending_stock_globs {
        state.stock_glob_members.insert(key, globs);
    }
    state
        .stock_glob_members
        .retain(|key, _| state.actions.contains_key(key));

    // Record location from the producing action, rather than rediscovering it
    // from files during a later configuration/filter transition.
    let actual_outputs: BTreeSet<_> = state.actions.values().flat_map(|a| &a.outputs).collect();
    state
        .stock_input_order
        .retain(|key, _| state.actions.contains_key(key));
    state
        .output_locations
        .retain(|asset, _| actual_outputs.contains(asset));
    for action in state.actions.values() {
        if let Some(builder) = build_config.definition(&action.builder) {
            for asset in &action.outputs {
                state.output_locations.insert(
                    asset.clone(),
                    builder.build_to == crate::builder::BuildTo::Cache,
                );
            }
        }
    }
    drop(outputs);
    let metadata = crate::wall::Span::new("commit_metadata");
    workspace.clear_asset_caches()?;
    // Retain demand reuse even after ordinary builds repair upstream bytes.
    // Only explicit demand policy creates sticky history. Both ordinary and
    // filtered builds re-select implicit legacy retention from the resolved
    // runner on every invocation, including after a version upgrade.
    state.retained_output_state |= explicit_keep_modified_outputs;
    state.schema_version = GRAPH_SCHEMA_VERSION;
    state.config_digest = config_digest;
    drop(metadata);
    let scan = crate::wall::Span::new("post_snapshot");
    let (mut post_snapshot, post_scan_us, post_assets_us) =
        snapshot::scan_committed(workspace, state, build_config, scanned_packages)?;
    if let Some((initial_snapshot, generated_assets)) = source_snapshot_evidence {
        // A watcher event can arrive after an action reads a source but before
        // this post-build scan. Keep build-start digests for existing source
        // files so the queued event still makes them dirty next cycle. Leave
        // newly observed files and glob membership at their post-build values:
        // ordinary workers can consume first-seen external assets or generated
        // outputs during this transaction.
        for (asset, initial) in initial_snapshot {
            if transaction.source_edits.contains_key(asset) {
                continue;
            }
            if !generated_assets.contains(asset) && !asset.starts_with("__glob__|") {
                post_snapshot.insert(asset.clone(), initial.clone());
            }
        }
    }
    if let Some((initial_snapshot, generated_assets, observed_snapshot_delta)) =
        filtered_snapshot_evidence
    {
        // Drop source entries first discovered by a post-build scan. New
        // external reads are added back below from the bytes actually served
        // to workers, while generated outputs and glob evidence keep their
        // own transaction semantics.
        post_snapshot.retain(|asset, _snapshot| {
            generated_assets.contains(asset)
                || initial_snapshot.contains_key(asset)
                || asset.starts_with("__glob__|")
        });
        // Keep build-start evidence for every source asset, including deleted
        // files. The queued event must still see a delta on the next filtered
        // iteration. Generated outputs retain their committed post-scan bytes.
        for (asset, initial) in initial_snapshot {
            if !generated_assets.contains(asset) {
                post_snapshot.insert(asset.clone(), initial.clone());
            }
        }
        // Build-start snapshots do not cover a first-time external source.
        // Its first observed bytes/missing result came through lazy asset RPC;
        // using the later filesystem scan here could hide an edit in-flight.
        for (asset, observed) in observed_snapshot_delta {
            if !generated_assets.contains(asset) {
                post_snapshot.insert(asset.clone(), observed.clone());
            }
        }
    }
    let retained_snapshot = filtered_snapshot_evidence
        .map(|(initial, _, _)| initial)
        .or_else(|| source_snapshot_evidence.map(|(initial, _)| initial));
    if keep_modified_outputs && let Some(initial) = retained_snapshot {
        // Retained bytes may differ from their logical digest. Keep that
        // evidence until the producer actually runs, including across restarts.
        for action in state.actions.values() {
            for output in &action.outputs {
                if !written_outputs.contains(output)
                    && let Some(retained) = initial.get(output)
                {
                    post_snapshot.insert(output.clone(), retained.clone());
                }
            }
        }
    }
    drop(scan);
    let update = crate::wall::Span::new("graph_update_assets");
    state.update_assets(post_snapshot);
    drop(update);
    let graph_save_started = Instant::now();
    let save = crate::wall::Span::new("graph_save");
    boundary("before_graph")?;
    state.save(state_path)?;
    boundary("after_graph")?;
    if journaled {
        super::recovery::finish(state_path)?;
    }
    drop(save);
    Ok(GraphSaveMetrics {
        graph_save_us: graph_save_started.elapsed().as_micros(),
        graph_save_bytes: graph_file_size(state_path),
        graph_save_skipped: false,
        post_scan_us,
        post_assets_us,
    })
}

/// Compare the final transaction's package-path mutations. Artifact-tree
/// changes are intentionally excluded, matching stock's presubmit contract.
fn verify_outputs(state: &GraphState, inputs: &CommitInputs<'_>) -> io::Result<()> {
    use crate::builder::BuildTo;
    let workspace = inputs.workspace;
    let transaction = &inputs.transaction;
    let mut changes = BTreeMap::new();
    for (location, asset) in &transaction.pending_location_deletions {
        if *location == BuildTo::Source {
            changes.insert(asset.clone(), None);
        }
    }
    for (builder, asset) in &transaction.pending_deletions {
        if builder.build_to == BuildTo::Source {
            changes.insert(asset.clone(), None);
        }
    }
    for (_, action) in &transaction.deleted_actions {
        let builder = inputs
            .build_config
            .definition(&action.builder)
            .ok_or_else(|| io::Error::other("previous builder unavailable"))?;
        for asset in &action.outputs {
            let cache = state
                .output_locations
                .get(asset)
                .copied()
                .unwrap_or(builder.build_to == BuildTo::Cache);
            if !cache && !inputs.expected_outputs.contains(asset) {
                changes.insert(asset.clone(), None);
            }
        }
    }
    for (asset, (builder, bytes)) in &transaction.pending_outputs {
        if builder.build_to == BuildTo::Source {
            changes.insert(asset.clone(), Some(bytes.as_ref()));
        }
    }
    for (asset, edit) in &transaction.source_edits {
        let bytes = &edit.updated;
        changes.insert(asset.clone(), Some(bytes.as_ref()));
    }
    let mut lines = Vec::new();
    for (asset, expected) in changes {
        let existing = match fs::read(workspace.path_for_asset(&asset)?) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        let kind = match (expected, existing.as_deref()) {
            (Some(_), None) => Some('M'),
            (None, Some(_)) => Some('U'),
            (Some(expected), Some(actual)) if expected != actual => Some('I'),
            _ => None,
        };
        if let Some(kind) = kind {
            let (package, path) = asset
                .split_once('|')
                .ok_or_else(|| io::Error::other("invalid output asset"))?;
            let rendered = if package == workspace.root_package {
                path.to_owned()
            } else {
                format!("{package}|{path}")
            };
            lines.push(format!("{kind} {rendered}"));
        }
    }
    lines.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    if !lines.is_empty() {
        eprintln!(
            "Verify failed due to Incorrect|Missing|Unexpected:\n\n{}",
            lines.join("\n")
        );
        return Err(io::Error::other("output verification failed"));
    }
    Ok(())
}

// `is_file`/`exists` turn metadata I/O errors into false. Only an absent
// destination is a successful no-op; all other deletion errors must journal.
fn remove_output(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

// The private cache tree is disposable, but rollback must preserve it too.
fn collect_cache_deletions(
    path: &Path,
    changes: &mut BTreeMap<std::path::PathBuf, Option<String>>,
) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if metadata.file_type().is_symlink() {
        return Err(io::Error::other("refusing symlink in artifact tree"));
    }
    if metadata.is_dir() {
        for entry in fs::read_dir(path)? {
            collect_cache_deletions(&entry?.path(), changes)?;
        }
    } else {
        changes.insert(path.to_owned(), None);
    }
    Ok(())
}

#[cfg(test)]
type BoundaryHook = fn(&str) -> io::Result<()>;

#[cfg(test)]
thread_local! {
    pub(super) static COMMIT_BOUNDARY: std::cell::RefCell<Option<BoundaryHook>> = const { std::cell::RefCell::new(None) };
}

pub(super) fn boundary(_name: &str) -> io::Result<()> {
    #[cfg(test)]
    COMMIT_BOUNDARY.with(|hook| {
        if let Some(hook) = *hook.borrow() {
            hook(_name)
        } else {
            Ok(())
        }
    })?;
    Ok(())
}
