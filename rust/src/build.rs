mod commit;
mod dirty;
mod execution;
mod part_directive;
mod planning;
mod results;
mod snapshot;
mod transaction;

#[cfg(test)]
mod tests;

use crate::cli::Options;
use crate::frontend::{run_dart_fallback, select_frontend};
use crate::graph::GraphState;
use crate::metrics::{
    FilesystemMetrics, graph_file_size, print_filesystem_metrics, print_graph_metrics,
    print_pool_metrics, print_workspace_read_metrics, runtime_metrics_enabled,
};
use crate::worker::WorkerPool;
use crate::workspace::Workspace;
use std::io;
use std::path::PathBuf;
use std::time::Instant;

pub(crate) fn graph_path(workspace: &Workspace) -> PathBuf {
    workspace
        .root
        .join(".dart_tool/build_runner_accelerator/graph-v3.bin")
}

pub(crate) fn run(options: &Options, pool: Option<&mut WorkerPool>) -> io::Result<()> {
    let _wall = crate::wall::Session::new();
    let load = crate::wall::Span::new("workspace_load");
    let workspace = Workspace::load(options.root.clone())?;
    drop(load);
    let selection = crate::wall::Span::new("manifest_select");
    let build_config = match select_frontend(options, &workspace)? {
        Some(config) => config,
        None => {
            drop(selection);
            let _fallback = crate::wall::Span::new("dart_fallback");
            return run_dart_fallback(options, &workspace);
        }
    };
    drop(selection);
    run_with_config(options, pool, workspace, build_config)
}

pub(crate) fn run_with_config(
    options: &Options,
    pool: Option<&mut WorkerPool>,
    workspace: Workspace,
    build_config: crate::builder::RustBuildConfig,
) -> io::Result<()> {
    // Watch already resolved the workspace and manifest to initialize or
    // reuse its worker pool. Keep that resolution alive for the build itself.
    let _wall = crate::wall::Session::new();
    let _build = crate::wall::Span::new("build_with_config");
    let state_path = graph_path(&workspace);
    let load = crate::wall::Span::new("graph_load");
    let graph_load_started = Instant::now();
    let mut state = GraphState::load(&state_path)?;
    let graph_load_us = graph_load_started.elapsed().as_micros();
    let graph_load_bytes = graph_file_size(&state_path);
    drop(load);
    let digest = crate::wall::Span::new("config_digest");
    let config_digest = snapshot::config_digest(&workspace, &build_config)?;
    drop(digest);
    let mut filesystem_metrics = FilesystemMetrics::default();

    let scanned_packages = snapshot::scanned_packages(&workspace, &build_config);
    let scan = crate::wall::Span::new("initial_snapshot");
    let current_snapshot = snapshot::scan_initial(
        &workspace,
        &state,
        &build_config,
        &scanned_packages,
        &mut filesystem_metrics,
    )?;
    drop(scan);
    let planning = crate::wall::Span::new("planning");
    let plan = planning::create(&workspace, &state, &build_config, &current_snapshot)?;
    drop(planning);
    planning::report_metrics(&plan, &state, &build_config);
    if planning::report_plan_only(&workspace, &plan) {
        return Ok(());
    }

    let dirty = crate::wall::Span::new("dirty_check");
    let dirty_plan = dirty::analyze(
        &workspace,
        &state,
        &build_config,
        &config_digest,
        &current_snapshot,
        &plan,
        &mut filesystem_metrics,
    )?;
    drop(dirty);
    if !dirty_plan.has_work() {
        println!("No work to do (Rust frontend)");
        let graph_metrics = commit::save_no_work(
            &mut state,
            &state_path,
            &config_digest,
            current_snapshot,
            graph_load_bytes,
        )?;
        if runtime_metrics_enabled() {
            print_filesystem_metrics(&filesystem_metrics);
            print_graph_metrics(
                graph_load_us,
                graph_metrics.graph_save_us,
                graph_load_bytes,
                graph_metrics.graph_save_bytes,
                graph_metrics.graph_save_skipped,
            );
            print_workspace_read_metrics(workspace.read_metrics());
        }
        return Ok(());
    }

    let executing = crate::wall::Span::new("execution");
    let execution = execution::run(
        pool,
        execution::ExecutionInputs {
            options,
            workspace: &workspace,
            state: &mut state,
            build_config: &build_config,
            config_digest: &config_digest,
            plan: &plan,
            dirty_plan,
        },
    )?;
    drop(executing);
    let execution::ExecutionResult {
        transaction,
        expected_outputs,
        pool_metrics,
        part_filtered_actions,
    } = execution;
    let committing = crate::wall::Span::new("commit");
    let graph_metrics = commit::commit(
        &mut state,
        commit::CommitInputs {
            workspace: &workspace,
            state_path: &state_path,
            build_config: &build_config,
            config_digest,
            scanned_packages: &scanned_packages,
            expected_outputs,
            transaction,
        },
    )?;
    drop(committing);
    filesystem_metrics.post_scan_us = graph_metrics.post_scan_us;
    filesystem_metrics.post_assets_us = graph_metrics.post_assets_us;

    if runtime_metrics_enabled() {
        if let Some(pool_metrics) = pool_metrics {
            print_pool_metrics(pool_metrics);
        }
        print_filesystem_metrics(&filesystem_metrics);
        print_graph_metrics(
            graph_load_us,
            graph_metrics.graph_save_us,
            graph_load_bytes,
            graph_metrics.graph_save_bytes,
            graph_metrics.graph_save_skipped,
        );
        print_workspace_read_metrics(workspace.read_metrics());
        if part_filtered_actions > 0 {
            eprintln!("part_filtered={part_filtered_actions}");
        }
    }
    println!("Build completed (Rust frontend)");
    Ok(())
}
