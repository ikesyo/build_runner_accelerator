mod commit;
mod dirty;
mod execution;
mod filtered;
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
use crate::workspace_lock::WorkspaceLock;
use std::io;
use std::path::PathBuf;
use std::time::Instant;

pub(crate) fn graph_path(workspace: &Workspace) -> PathBuf {
    workspace
        .root
        .join(".dart_tool/build_runner_accelerator/graph-v3.bin")
}

pub(crate) fn run(
    options: &Options,
    pool: Option<&mut WorkerPool>,
    workspace_lock: Option<&WorkspaceLock>,
) -> io::Result<()> {
    let load = crate::wall::Span::new("workspace_load");
    let workspace = Workspace::load(options.root.clone())?;
    drop(load);
    let selection = crate::wall::Span::new("manifest_select");
    let build_config = match select_frontend(options, &workspace)? {
        Some(config) => config,
        None => {
            drop(selection);
            let _fallback = crate::wall::Span::new("dart_fallback");
            return run_dart_fallback(options, workspace_lock);
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
    run_with_config_session(
        options,
        pool,
        workspace,
        build_config,
        true,
        &crate::watch::WatchChanges::default(),
    )
}

pub(crate) fn run_with_config_session(
    options: &Options,
    pool: Option<&mut WorkerPool>,
    workspace: Workspace,
    build_config: crate::builder::RustBuildConfig,
    session_start: bool,
    changed_paths: &crate::watch::WatchChanges,
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
    let filters = crate::cli::BuildSettings::parse(&options.stock_arguments)?.build_filters;
    let mut planning_snapshot = None;
    if !filters.is_empty() {
        if session_start || !state.is_compatible(&config_digest) {
            state.watch_generated_sources.clear();
        } else {
            let mut previous_sources = state.assets.clone();
            for asset in &state.watch_generated_sources {
                previous_sources.remove(asset);
            }
            let previous_declared =
                planning::create(&workspace, &state, &build_config, &previous_sources)?
                    .expected_outputs();
            state.watch_generated_sources.retain(|asset| {
                let path = workspace
                    .path_for_asset(asset)
                    .ok()
                    .map(|path| crate::watch::normalized_watch_path(&path));
                if previous_declared.contains(asset) {
                    state.assets.get(asset) == current_snapshot.get(asset)
                        && !path
                            .as_ref()
                            .is_some_and(|path| changed_paths.paths.contains(path))
                } else {
                    // Stock ignores modifications/removals of unknown assets;
                    // only an ADD can introduce a new plain source here.
                    !path
                        .as_ref()
                        .is_some_and(|path| changed_paths.added_paths.contains(path))
                }
            });
            let mut sources = current_snapshot.clone();
            for asset in &state.watch_generated_sources {
                sources.remove(asset);
            }
            planning_snapshot = Some(sources);
        }
    }
    let planning = crate::wall::Span::new("planning");
    let plan = planning::create(
        &workspace,
        &state,
        &build_config,
        planning_snapshot.as_ref().unwrap_or(&current_snapshot),
    )?;
    drop(planning);
    planning::report_metrics(&plan, &state, &build_config);
    if planning::report_plan_only(&workspace, &plan) {
        return Ok(());
    }

    if !filters.is_empty() {
        return filtered::run(
            options,
            pool,
            &workspace,
            &mut state,
            &build_config,
            &config_digest,
            &state_path,
            &scanned_packages,
            &plan,
            &filters,
            session_start,
            &current_snapshot,
            &changed_paths.paths,
        );
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
    let mut generated_assets: std::collections::BTreeSet<String> =
        state.output_locations.keys().cloned().collect();
    generated_assets.extend(state.watch_generated_sources.iter().cloned());
    generated_assets.extend(
        state
            .actions
            .values()
            .flat_map(|action| action.outputs.iter().cloned()),
    );
    generated_assets.extend(expected_outputs.iter().cloned());
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
            source_snapshot_evidence: Some((&current_snapshot, &generated_assets)),
            filtered_snapshot_evidence: None,
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

pub(crate) fn empty_filtered_result(spec: &crate::plan::BuildSpec) -> crate::protocol::BuildResult {
    part_directive::empty_build_result(spec)
}

/// Old private state cannot supply output locations after a configuration change.
/// Changes removing previous declarations also require stock's source reclassification.
pub(crate) fn filtered_transition_reason(
    workspace: &Workspace,
    config: &crate::builder::RustBuildConfig,
) -> io::Result<Option<&'static str>> {
    let state = GraphState::load(&graph_path(workspace))?;
    if state.has_resolver_cycle() {
        return Ok(Some(
            "filtered incremental resolver cycles are outside the supported subset",
        ));
    }
    if state
        .actions
        .keys()
        .any(|key| !state.stock_input_order.contains_key(key))
    {
        return Ok(Some(
            "filtered legacy state lacks ordered stock input evidence",
        ));
    }
    if state.actions.values().any(|action| {
        !config
            .builders
            .iter()
            .any(|builder| builder.definition.id == action.builder)
    }) {
        return Ok(Some(
            "filtered configuration removed a previous builder application",
        ));
    }
    if state.actions.iter().any(|(key, action)| {
        action.glob_reads.iter().any(|glob| {
            !state.stock_glob_members.get(key).is_some_and(|globs| {
                globs.contains_key(&format!("{}|{}", glob.package, glob.pattern))
            })
        })
    }) {
        return Ok(Some(
            "filtered legacy state lacks per-action stock glob evidence",
        ));
    }
    let digest = snapshot::config_digest(workspace, config)?;
    if config
        .builders
        .iter()
        .any(|builder| builder.package != workspace.root_package)
    {
        let packages = snapshot::scanned_packages(workspace, config);
        let current = snapshot::scan_initial(
            workspace,
            &state,
            config,
            &packages,
            &mut FilesystemMetrics::default(),
        )?;
        let plan = planning::create(workspace, &state, config, &current)?;
        for spec in &plan.specs {
            for output in &spec.outputs {
                if output
                    .split_once('|')
                    .is_some_and(|(package, _)| package != workspace.root_package)
                    && workspace.asset_exists_at(output, crate::builder::BuildTo::Source)?
                {
                    return Ok(Some(
                        "filtered package-path output conflicts in dependencies are outside the supported subset",
                    ));
                }
            }
        }
    }
    if state.config_digest.is_empty() || state.is_compatible(&digest) {
        return Ok(None);
    }
    if state
        .actions
        .values()
        .flat_map(|action| &action.outputs)
        .any(|output| !state.output_locations.contains_key(output))
    {
        return Ok(Some(
            "filtered configuration change requires previous output locations missing from legacy state",
        ));
    }
    let packages = snapshot::scanned_packages(workspace, config);
    let current = snapshot::scan_initial(
        workspace,
        &state,
        config,
        &packages,
        &mut FilesystemMetrics::default(),
    )?;
    let plan = planning::create(workspace, &state, config, &current)?;
    let declared = plan.expected_outputs();
    if state
        .actions
        .values()
        .flat_map(|action| &action.outputs)
        .any(|output| !declared.contains(output))
    {
        return Ok(Some(
            "filtered configuration change removed previous output declarations",
        ));
    }
    if !state.output_locations.iter().any(|(asset, cache)| {
        let previous = if *cache {
            crate::builder::BuildTo::Cache
        } else {
            crate::builder::BuildTo::Source
        };
        plan.visibility.location(asset) != Some(previous)
    }) {
        return Ok(Some(
            "filtered configuration changes without a source/cache layout transition are outside the supported subset",
        ));
    }
    Ok(None)
}
