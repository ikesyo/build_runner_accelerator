use crate::assets::write_atomic;
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

/// Persists changed configuration and snapshot metadata without running actions.
/// An exact metadata match skips the graph write; read, encoding and filesystem
/// errors propagate to the caller.
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

/// Publishes staged outputs, deletions and graph state after all actions pass.
/// This is an all-success boundary, not a crash-atomic filesystem transaction:
/// deletions and per-file atomic writes precede the graph rename, with no
/// journal or rollback. An I/O error or interruption can leave some files
/// changed while the previous graph remains on disk.
pub(super) fn commit(
    state: &mut GraphState,
    inputs: CommitInputs<'_>,
) -> io::Result<GraphSaveMetrics> {
    let CommitInputs {
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

    // No phase or asset RPC can read the overlay once all actions have succeeded.
    // Release its references so committing each output can free its buffer.
    drop(transaction.overlay);
    let outputs = crate::wall::Span::new("output_commit");
    // Commit only after every dirty action succeeded. Cache-built part files
    // are kept below .dart_tool and are visible to later phases through the
    // overlay and the cache-aware reader.
    if transaction.clean_artifact_tree {
        let path = workspace
            .root
            .join(".dart_tool/build_runner_accelerator/cache");
        if path.exists() {
            fs::remove_dir_all(path)?;
        }
    }
    for (location, asset) in transaction.pending_location_deletions {
        let path = match location {
            crate::builder::BuildTo::Source => workspace.path_for_asset(&asset)?,
            crate::builder::BuildTo::Cache => workspace.cache_path_for_asset(&asset)?,
        };
        if path.is_file() {
            fs::remove_file(path)?;
        }
    }
    for (builder, asset) in transaction.pending_deletions {
        let path = output_path(workspace, builder.as_ref(), &asset)?;
        if path.is_file() {
            fs::remove_file(path)?;
        }
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
            if path.is_file() {
                fs::remove_file(path)?;
            }
        }
        state.actions.remove(&action_key);
    }
    for (builder, asset, bytes) in transaction.pending_outputs {
        write_atomic(&output_path(workspace, builder.as_ref(), &asset)?, &bytes)?;
    }
    for (key, action) in transaction.pending_actions {
        state.actions.insert(key, action);
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
    drop(scan);
    let update = crate::wall::Span::new("graph_update_assets");
    state.update_assets(post_snapshot);
    drop(update);
    let graph_save_started = Instant::now();
    let save = crate::wall::Span::new("graph_save");
    state.save(state_path)?;
    drop(save);
    Ok(GraphSaveMetrics {
        graph_save_us: graph_save_started.elapsed().as_micros(),
        graph_save_bytes: graph_file_size(state_path),
        graph_save_skipped: false,
        post_scan_us,
        post_assets_us,
    })
}
