mod commit;
mod dirty;
mod execution;
mod filtered;
mod part_directive;
mod planning;
pub(crate) mod recovery;
mod results;
mod snapshot;
mod transaction;

#[cfg(test)]
mod tests;

use crate::cli::Options;
use crate::frontend::{NativeFrontend, prepare_native_frontend};
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

/// One validated graph load shared by selection and execution.
pub(crate) struct LoadedGraph {
    pub state: GraphState,
    load_us: u128,
    load_bytes: u64,
}

impl LoadedGraph {
    pub fn resident(state: GraphState, path: &std::path::Path) -> Self {
        let _reuse = crate::wall::Span::new("graph_reuse");
        Self {
            state,
            load_us: 0,
            load_bytes: graph_file_size(path),
        }
    }

    pub fn load(workspace: &Workspace) -> io::Result<Self> {
        let _load = crate::wall::Span::new("graph_load");
        let started = Instant::now();
        let path = graph_path(workspace);
        let state = GraphState::load(&path)?;
        Ok(Self {
            state,
            load_us: started.elapsed().as_micros(),
            load_bytes: graph_file_size(&path),
        })
    }
}

/// Scoped to one selection attempt and its unchanged workspace/config/graph.
/// Watch revalidates the snapshot after subscribing and starting its workers.
pub(crate) struct Preflight {
    config_digest: String,
    snapshot: crate::snapshot::Snapshot,
    plan: planning::PlannedActions,
    packages: std::collections::BTreeSet<String>,
    filesystem_metrics: FilesystemMetrics,
}

impl Preflight {
    fn prepare<'a>(
        slot: &'a mut Option<Self>,
        workspace: &Workspace,
        config: &crate::builder::RustBuildConfig,
        state: &GraphState,
    ) -> io::Result<&'a Self> {
        if slot.is_none() {
            let config_digest = snapshot::config_digest(workspace, config)?;
            let packages = snapshot::scanned_packages(workspace, config);
            let mut filesystem_metrics = FilesystemMetrics::default();
            let current = snapshot::scan_initial(
                workspace,
                state,
                config,
                &packages,
                &mut filesystem_metrics,
            )?;
            let plan = planning::create(workspace, state, config, &current)?;
            *slot = Some(Self {
                config_digest,
                snapshot: current,
                plan,
                packages,
                filesystem_metrics,
            });
        }
        Ok(slot.as_ref().unwrap())
    }
}

pub(crate) fn run(options: &Options) -> io::Result<()> {
    let load = crate::wall::Span::new("workspace_load");
    let workspace = Workspace::load(options.root.clone())?;
    drop(load);
    if options.settings.only_check {
        recovery::require_clean_verification(&graph_path(&workspace))?;
    }
    let loaded_graph = LoadedGraph::load(&workspace)?;
    let selection = crate::wall::Span::new("manifest_select");
    let build_config = prepare_native_frontend(options, &workspace, &loaded_graph.state)?;
    drop(selection);
    run_with_config_session(
        options,
        None,
        workspace,
        build_config,
        loaded_graph,
        true,
        &crate::watch::WatchChanges::default(),
    )
    .map(|_| ())
}

pub(crate) fn run_with_config_session(
    options: &Options,
    pool: Option<&mut WorkerPool>,
    workspace: Workspace,
    frontend: NativeFrontend,
    loaded_graph: LoadedGraph,
    session_start: bool,
    changed_paths: &crate::watch::WatchChanges,
) -> io::Result<Option<GraphState>> {
    // Watch already resolved the workspace and manifest to initialize or
    // reuse its worker pool. Keep that resolution alive for the build itself.
    let _wall = crate::wall::Session::new();
    let _build = crate::wall::Span::new("build_with_config");
    let NativeFrontend {
        config: build_config,
        preflight,
    } = frontend;
    let state_path = graph_path(&workspace);
    workspace.configure_sources(build_config.asset_sources.as_ref());
    let LoadedGraph {
        mut state,
        load_us: graph_load_us,
        load_bytes: graph_load_bytes,
    } = loaded_graph;
    let digest = crate::wall::Span::new("config_digest");
    let config_digest = snapshot::config_digest(&workspace, &build_config)?;
    drop(digest);
    let preflight = preflight.filter(|preflight| preflight.config_digest == config_digest);
    let scanned_packages = preflight.as_ref().map_or_else(
        || snapshot::scanned_packages(&workspace, &build_config),
        |preflight| preflight.packages.clone(),
    );
    let scan = crate::wall::Span::new("initial_snapshot");
    let (mut current_snapshot, mut filesystem_metrics, reusable_plan) = match preflight {
        Some(preflight) if options.command != "watch" => (
            preflight.snapshot,
            preflight.filesystem_metrics,
            Some(preflight.plan),
        ),
        preflight => {
            let mut metrics = FilesystemMetrics::default();
            let current = snapshot::scan_initial(
                &workspace,
                &state,
                &build_config,
                &scanned_packages,
                &mut metrics,
            )?;
            let plan = preflight
                .and_then(|preflight| (preflight.snapshot == current).then_some(preflight.plan));
            (current, metrics, plan)
        }
    };
    drop(scan);
    let settings = &options.settings;
    let mut filters = settings.build_filters.clone();
    let mut retained_output_guard = false;
    if settings.only_check || settings.keep_modified_outputs || state.retained_output_state {
        if filters.is_empty() {
            filters.push(crate::build_filter::BuildFilter::parse("asset:**/**")?);
        }
        if settings.keep_modified_outputs && state.is_compatible(&config_digest) {
            // Stock retains existing output bytes with their previous digest.
            // Missing outputs are NOT retained and must trigger their producer.
            for action in state.actions.values() {
                for output in &action.outputs {
                    if let Some(current) = current_snapshot.get(output)
                        && current.exists
                        && let Some(previous) = state.assets.get(output)
                    {
                        retained_output_guard |= current.digest != previous.digest;
                        current_snapshot.insert(output.clone(), previous.clone());
                    }
                }
            }
        }
    }
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
    let plan = match reusable_plan.filter(|_| filters.is_empty()) {
        Some(plan) => plan,
        None => planning::create(
            &workspace,
            &state,
            &build_config,
            planning_snapshot.as_ref().unwrap_or(&current_snapshot),
        )?,
    };
    planning::report_metrics(&plan, &state, &build_config);
    if planning::report_plan_only(&workspace, &plan) {
        return Ok(None);
    }

    if !filters.is_empty() {
        filtered::run(
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
            retained_output_guard,
        )?;
        return Ok((!settings.only_check).then_some(state));
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
    let no_work = !dirty_plan.has_work();
    // Cache outputs own their package paths too. Verify deliberately leaves
    // conflicts there, so an ordinary build must stage their removal even
    // when every action is reusable. Do not delete until all actions succeed.
    let mut cache_source_conflicts = std::collections::BTreeSet::new();
    for spec in &plan.specs {
        if spec.instance.builder.build_to == crate::builder::BuildTo::Cache
            && !spec.instance.builder.is_optional
        {
            for output in &spec.outputs {
                if workspace.asset_exists_at(output, crate::builder::BuildTo::Source)? {
                    cache_source_conflicts.insert(output.clone());
                }
            }
        }
    }
    if no_work
        && !state.config_digest.is_empty()
        && !state.was_filtered
        && cache_source_conflicts.is_empty()
    {
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
        return Ok(Some(state));
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
        mut transaction,
        expected_outputs,
        pool_metrics,
        part_filtered_actions,
    } = execution;
    if state.was_filtered {
        let _reconcile = crate::wall::Span::new("cache_reconcile");
        for (package, _) in workspace.packages() {
            for (asset, _) in workspace.list_cached_package_assets(package)? {
                if state.output_locations.get(&asset) != Some(&true) {
                    transaction
                        .pending_location_deletions
                        .push((crate::builder::BuildTo::Cache, asset));
                }
            }
        }
        state.was_filtered = false;
    }
    transaction.pending_location_deletions.extend(
        cache_source_conflicts
            .into_iter()
            .map(|asset| (crate::builder::BuildTo::Source, asset)),
    );
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
            only_check: false,
            keep_modified_outputs: false,
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
    if no_work {
        println!("No work to do (Rust frontend)");
    } else {
        println!("Build completed (Rust frontend)");
    }
    Ok(Some(state))
}

pub(crate) fn empty_filtered_result(spec: &crate::plan::BuildSpec) -> crate::protocol::BuildResult {
    part_directive::empty_build_result(spec)
}

/// Old private state cannot supply output locations after a configuration change.
/// Removing previous declarations exceeds the supported source reclassification.
pub(crate) fn filtered_transition_reason(
    workspace: &Workspace,
    config: &crate::builder::RustBuildConfig,
    output_policy: bool,
    state: &GraphState,
    preflight: &mut Option<Preflight>,
) -> io::Result<Option<&'static str>> {
    workspace.configure_sources(config.asset_sources.as_ref());
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
    if output_policy && !state.config_digest.is_empty() && state.config_digest != digest {
        return Ok(Some(
            "output-policy configuration transitions are outside the supported subset",
        ));
    }
    if let Some(reason) = dependency_output_conflict_reason(workspace, config, state, preflight)? {
        return Ok(Some(reason));
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
    let plan = &Preflight::prepare(preflight, workspace, config, state)?.plan;
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

pub(crate) fn dependency_output_conflict_reason(
    workspace: &Workspace,
    config: &crate::builder::RustBuildConfig,
    state: &GraphState,
    preflight: &mut Option<Preflight>,
) -> io::Result<Option<&'static str>> {
    if config
        .builders
        .iter()
        .any(|builder| builder.package != workspace.root_package)
    {
        let plan = &Preflight::prepare(preflight, workspace, config, state)?.plan;
        for spec in &plan.specs {
            for output in &spec.outputs {
                if output
                    .split_once('|')
                    .is_some_and(|(package, _)| package != workspace.root_package)
                    && workspace.asset_exists_at(output, crate::builder::BuildTo::Source)?
                {
                    return Ok(Some(
                        "package-path output conflicts in dependencies are outside the supported subset",
                    ));
                }
            }
        }
    }
    Ok(None)
}
