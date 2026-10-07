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

pub(super) struct CommitInputs<'a> {
    pub(super) workspace: &'a Workspace,
    pub(super) state_path: &'a Path,
    pub(super) build_config: &'a RustBuildConfig,
    pub(super) config_digest: String,
    pub(super) scanned_packages: &'a BTreeSet<String>,
    pub(super) expected_outputs: BTreeSet<String>,
    pub(super) transaction: PendingTransaction,
}

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
        transaction,
    } = inputs;

    // No phase or asset RPC can read the overlay once all actions have succeeded.
    // Release its references so committing each output can free its buffer.
    drop(transaction.overlay);
    let outputs = crate::wall::Span::new("output_commit");
    // Commit only after every dirty action succeeded. Cache-built part files
    // are kept below .dart_tool and are visible to later phases through the
    // overlay and the cache-aware reader.
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

    drop(outputs);
    let metadata = crate::wall::Span::new("commit_metadata");
    workspace.clear_asset_caches()?;
    state.schema_version = GRAPH_SCHEMA_VERSION;
    state.config_digest = config_digest;
    drop(metadata);
    let scan = crate::wall::Span::new("post_snapshot");
    let (post_snapshot, post_scan_us, post_assets_us) =
        snapshot::scan_committed(workspace, state, build_config, scanned_packages)?;
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
