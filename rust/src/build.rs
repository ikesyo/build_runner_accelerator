use crate::assets::{
    add_current_generated_assets, add_tracked_dependency_assets, add_tracked_glob_assets,
    config_digest, write_atomic,
};
use crate::builder::{BuildTo, BuilderDefinition, BuilderKind, ConfiguredBuilder, RustBuildConfig};
use crate::cli::Options;
use crate::digest::digest_bytes;
use crate::frontend::{run_dart_fallback, select_frontend, worker_executable};
use crate::graph::{ActionState, GRAPH_SCHEMA_VERSION, GraphState};
use crate::metrics::{
    FilesystemMetrics, graph_file_size, print_filesystem_metrics, print_graph_metrics,
    print_pool_metrics, print_workspace_read_metrics, runtime_metrics_enabled, snapshot_summary,
};
use crate::plan::{
    BuildSpec, build_specs_for_kind_with_primary_inputs,
    build_specs_for_phase_with_primary_inputs, output_digest, output_path,
    validate_unique_outputs,
};
use crate::protocol::BuildResult;
use crate::worker::{BuildRequest, LazyBuildState, WorkerPool};
use crate::workspace::Workspace;
use crate::visibility::AssetVisibility;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

pub(crate) fn graph_path(workspace: &Workspace) -> PathBuf {
    workspace
        .root
        .join(".dart_tool/build_runner_accelerator/graph-v3.bin")
}
pub(crate) fn run(options: &Options, pool: Option<&mut WorkerPool>) -> io::Result<()> {
    let workspace = Workspace::load(options.root.clone())?;
    let build_config = match select_frontend(options, &workspace)? {
        Some(config) => config,
        None => return run_dart_fallback(options, &workspace),
    };
    run_with_config(options, pool, workspace, build_config)
}

pub(crate) fn run_with_config(
    options: &Options,
    pool: Option<&mut WorkerPool>,
    workspace: Workspace,
    build_config: RustBuildConfig,
) -> io::Result<()> {
    // Watch already resolved the workspace and manifest to initialize or
    // reuse its worker pool. Keep that resolution alive for the build itself.
    let state_path = graph_path(&workspace);
    let graph_load_started = Instant::now();
    let mut state = GraphState::load(&state_path)?;
    let graph_load_us = graph_load_started.elapsed().as_micros();
    let graph_load_bytes = graph_file_size(&state_path);
    let config_digest = config_digest(&workspace, &build_config)?;
    let mut filesystem_metrics = FilesystemMetrics::default();
    let scan_started = Instant::now();
    let scanned_packages = build_config
        .builders
        .iter()
        .map(|builder| builder.package.clone())
        .chain(std::iter::once(workspace.root_package.clone()))
        .collect::<BTreeSet<_>>();
    let mut current_snapshot = crate::snapshot::scan_packages(&workspace, &scanned_packages)?;
    filesystem_metrics.initial_scan_us = scan_started.elapsed().as_micros();
    let (initial_scan_assets, initial_scan_bytes) = snapshot_summary(&current_snapshot);
    filesystem_metrics.initial_scan_assets = initial_scan_assets;
    filesystem_metrics.initial_scan_bytes = initial_scan_bytes;

    let stage_started = Instant::now();
    add_current_generated_assets(&workspace, &state, &mut current_snapshot, &build_config)?;
    filesystem_metrics.initial_generated_us = stage_started.elapsed().as_micros();

    let stage_started = Instant::now();
    add_tracked_dependency_assets(&workspace, &state, &mut current_snapshot)?;
    filesystem_metrics.initial_dependencies_us = stage_started.elapsed().as_micros();

    let stage_started = Instant::now();
    add_tracked_glob_assets(&workspace, &state, &mut current_snapshot)?;
    filesystem_metrics.initial_globs_us = stage_started.elapsed().as_micros();
    // Post-process outputs are hidden from all normal Builder phases. Keep
    // them in the persisted snapshot for their own action bookkeeping, but
    // remove them from the candidate snapshot used by normal builders.
    let mut normal_snapshot = current_snapshot.clone();
    for action in state.actions.values() {
        if build_config
            .definition(&action.builder)
            .is_some_and(|builder| builder.kind == BuilderKind::PostProcess)
        {
            for output in &action.outputs {
                normal_snapshot.remove(output);
            }
        }
    }
    // A deleted normal action can leave its source-tree output on disk until
    // the transaction below removes it. Do not let that stale output become
    // a post-process input (or a normal input for a later phase) while
    // planning this build. Recompute until removing one stale output exposes
    // another stale action.
    let (normal_specs, normal_planning_snapshot, normal_primary_inputs) = loop {
        let normal_phases = build_config
            .builders
            .iter()
            .filter(|builder| builder.definition.kind == BuilderKind::Normal)
            .map(|builder| builder.phase)
            .collect::<BTreeSet<_>>();
        let mut planning_snapshot = normal_snapshot.clone();
        let mut specs = Vec::new();
        // build_runner applies targetSources to the original primary input
        // after following declared-output edges. Keep that relation for every
        // planned phase, including cache outputs which are not source files.
        let mut primary_inputs = BTreeMap::new();
        for phase in normal_phases {
            let phase_specs = build_specs_for_phase_with_primary_inputs(
                &workspace,
                &planning_snapshot,
                &build_config,
                BuilderKind::Normal,
                phase,
                &primary_inputs,
            )?;
            for spec in &phase_specs {
                for output in &spec.outputs {
                    primary_inputs
                        .entry(output.clone())
                        .or_insert_with(|| spec.input.clone());
                    let planned = crate::snapshot::AssetSnapshot {
                        exists: true,
                        digest: digest_bytes(b"<planned>"),
                        size: 0,
                    };
                    planning_snapshot
                        .entry(output.clone())
                        .and_modify(|entry| {
                            // A previous action may have tracked this path as
                            // missing. Once an earlier phase declares it, the
                            // planned output must become visible again.
                            if !entry.exists {
                                *entry = planned.clone();
                            }
                        })
                        .or_insert(planned);
                }
            }
            specs.extend(phase_specs);
        }
        validate_unique_outputs(&specs)?;
        let expected_keys = specs
            .iter()
            .map(|spec| spec.action_key())
            .collect::<BTreeSet<_>>();
        let expected_outputs = specs
            .iter()
            .flat_map(|spec| spec.outputs.iter().cloned())
            .collect::<BTreeSet<_>>();
        let mut removed = false;
        for (key, action) in &state.actions {
            if !build_config
                .definition(&action.builder)
                .is_some_and(|builder| builder.kind == BuilderKind::Normal)
                || expected_keys.contains(key)
            {
                continue;
            }
            for output in &action.outputs {
                if !expected_outputs.contains(output) && normal_snapshot.remove(output).is_some() {
                    removed = true;
                }
            }
        }
        if !removed {
            break (specs, planning_snapshot, primary_inputs);
        }
    };
    // A post-process action may consume an output that is created during this
    // build. The phase-aware planning snapshot includes outputs declared by all
    // normal phases, so post-process builders see every output that will exist
    // when their final phase starts.
    let post_snapshot = normal_planning_snapshot;
    let post_specs = build_specs_for_kind_with_primary_inputs(
        &workspace,
        &post_snapshot,
        &build_config,
        Some(BuilderKind::PostProcess),
        &normal_primary_inputs,
    )?;
    let generated_output_locations = normal_specs
        .iter()
        .flat_map(|spec| {
            spec.outputs
                .iter()
                .cloned()
                .map(|output| (output, (spec.builder.build_to, spec.builder.is_optional)))
        })
        .collect::<BTreeMap<String, (BuildTo, bool)>>();
    let mut specs = normal_specs;
    specs.extend(post_specs);
    let visibility = AssetVisibility::from_specs(&specs, &state, &build_config);

    let mut current_output_digests = BTreeMap::new();
    for action in state.actions.values() {
        if let Some(builder) = build_config.definition(&action.builder) {
            for output in &action.outputs {
                if let Some(digest) = output_digest(&workspace, builder, output)? {
                    current_output_digests.insert(output.clone(), digest);
                }
            }
        }
    }
    let mut dirty = Vec::new();
    let mut dirty_roots = Vec::new();
    let dirty_check_started = Instant::now();
    for spec in &specs {
        for output in &spec.outputs {
            if let Some(digest) = output_digest(&workspace, &spec.builder, output)? {
                current_output_digests.insert(output.clone(), digest);
            }
        }

        let key = spec.action_key();
        let needs_build = match state.actions.get(&key) {
            Some(action) if state.is_compatible(&config_digest) => {
                state.changed_since_previous(action, &current_snapshot, &current_output_digests)
            }
            _ => true,
        };
        if needs_build {
            dirty_roots.push(spec.clone());
            if !spec.builder.is_optional {
                dirty.push(spec.clone());
            }
        }
    }
    expand_dirty_dependents(&mut dirty_roots, &specs, &state);
    let mut dirty_keys = dirty
        .iter()
        .map(|spec| spec.action_key())
        .collect::<BTreeSet<_>>();
    let mut lazy_force_keys = BTreeSet::new();
    for spec in dirty_roots {
        let key = spec.action_key();
        if spec.builder.is_optional {
            lazy_force_keys.insert(key);
        } else if dirty_keys.insert(key) {
            dirty.push(spec);
        }
    }
    filesystem_metrics.dirty_check_us = dirty_check_started.elapsed().as_micros();

    let expected_keys: BTreeSet<String> = specs
        .iter()
        .map(|spec| spec.action_key())
        .collect();
    let deleted_actions: Vec<(String, ActionState)> = state
        .actions
        .iter()
        .filter(|(action_key, action)| {
            build_config.definition(&action.builder).is_some()
                && !expected_keys.contains(*action_key)
        })
        .map(|(key, action)| (key.clone(), action.clone()))
        .collect();

    if dirty.is_empty() && deleted_actions.is_empty() {
        println!("No work to do (Rust frontend)");
        let mut graph_save_us = 0;
        let graph_save_skipped =
            !state.update_metadata_if_changed(&config_digest, current_snapshot);
        let graph_save_bytes;
        if graph_save_skipped {
            graph_save_bytes = graph_load_bytes;
        } else {
            let graph_save_started = Instant::now();
            state.save(&state_path)?;
            graph_save_us = graph_save_started.elapsed().as_micros();
            graph_save_bytes = graph_file_size(&state_path);
        }
        if runtime_metrics_enabled() {
            print_filesystem_metrics(&filesystem_metrics);
            print_graph_metrics(
                graph_load_us,
                graph_save_us,
                graph_load_bytes,
                graph_save_bytes,
                graph_save_skipped,
            );
            print_workspace_read_metrics(workspace.read_metrics());
        }
        return Ok(());
    }

    eprintln!("Rust frontend: {} build action(s)", dirty.len());
    let mut worker_pool = pool;
    let mut pool_metrics = None;
    let mut overlay = BTreeMap::new();
    let expected_outputs = specs
        .iter()
        .flat_map(|spec| spec.outputs.iter().cloned())
        .collect::<BTreeSet<_>>();
    // Hide stale outputs of every dirty action until that action publishes its
    // new result. This matches build_runner's phased reader: an action must
    // not observe an old output from its current phase, while later phases
    // can see the fresh value as soon as it is placed in the overlay.
    let mut deleted_overlay = dirty
        .iter()
        .filter_map(|spec| {
            state.actions.get(&spec.action_key())
        })
        .flat_map(|action| action.outputs.iter().cloned())
        .collect::<BTreeSet<_>>();
    for (_, action) in &deleted_actions {
        deleted_overlay.extend(action.outputs.iter().cloned());
    }
    let mut pending_outputs: Vec<(Arc<BuilderDefinition>, String, Vec<u8>)> = Vec::new();
    let mut pending_deletions: Vec<(Arc<BuilderDefinition>, String)> = Vec::new();
    let mut pending_actions = Vec::new();
    let lazy_specs_by_output = specs
        .iter()
        .filter(|spec| spec.builder.is_optional && spec.builder.kind == BuilderKind::Normal)
        .flat_map(|spec| spec.outputs.iter().map(|output| (output.clone(), spec.clone())))
        .collect::<BTreeMap<_, _>>();
    let lazy_demand_possible =
        !lazy_force_keys.is_empty() && !lazy_specs_by_output.is_empty();
    let mut lazy_state = LazyBuildState::new(lazy_force_keys);
    if !dirty.is_empty() {
        let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
        let worker_command = worker_executable(options, &build_config)?;
        let phase_count = build_config.phase_count();
        let mut owned_pool = if worker_pool.is_none() {
            Some(WorkerPool::start(
                &workspace.root,
                dart_binary,
                &worker_command,
                options.jobs,
                options.worker.is_none(),
            )?)
        } else {
            None
        };
        if worker_pool.is_none() {
            worker_pool = owned_pool.as_mut();
        }
        let active_pool = worker_pool
            .as_deref_mut()
            .expect("worker pool was just initialized");
        let max_phase_requests = build_config
            .builders
            .iter()
            .map(|builder| {
                dirty
                    .iter()
                    .filter(|spec| spec.builder.id == builder.definition.id)
                    .count()
            })
            .max()
            .unwrap_or(0);
        active_pool.prepare_for_requests(&workspace.root, max_phase_requests)?;
        let first_package = dirty
            .first()
            .map(|spec| spec.package.clone())
            .expect("dirty actions have a package");
        active_pool.initialize(
            &workspace.root,
            &first_package,
            &config_digest,
            phase_count,
            lazy_demand_possible,
        )?;

        // Source outputs remain in the Rust overlay until the transaction commits.
        // Invalidate only the worker's Analyzer graph before a later phase so
        // resolver-backed builders can re-sync those overlay parts without
        // discarding the resident worker's asset-read cache.
        let mut resolver_needs_reset = false;
        let mut initialized_package = first_package;

        for configured_builder_index in execution_order(&build_config.builders) {
            let configured_builder = &build_config.builders[configured_builder_index];
            let builder = configured_builder.definition.as_ref();
            let phase_specs = dirty
                .iter()
                .filter(|spec| {
                    spec.target == configured_builder.target && spec.builder.id == builder.id
                })
                .cloned()
                .collect::<Vec<_>>();
            let mut runnable_phase_specs = Vec::with_capacity(phase_specs.len());
            for spec in phase_specs {
                if let Some((build_to, is_optional)) = generated_output_locations.get(&spec.input)
                {
                    // An optional producer may be invoked lazily by this
                    // consumer's BuildStep.readAsString. Keep the consumer
                    // request alive so the resident worker can satisfy that
                    // demand before deciding that the primary input is
                    // missing.
                    if !is_optional {
                        let output_is_visible = !deleted_overlay.contains(&spec.input)
                            && (overlay.contains_key(&spec.input)
                                || workspace.asset_exists_at(&spec.input, *build_to)?);
                        if !output_is_visible {
                            record_missing_primary_input(
                                &workspace,
                                &state,
                                &spec,
                                &mut overlay,
                                &mut deleted_overlay,
                                &mut pending_deletions,
                                &mut pending_actions,
                            )?;
                            continue;
                        }
                    }
                }
                runnable_phase_specs.push(spec);
            }
            let requests = runnable_phase_specs
                .iter()
                .map(|spec| BuildRequest {
                    builder: spec.builder.id.to_owned(),
                    input: spec.input.clone(),
                    outputs: spec.outputs.clone(),
                    options: spec.options.clone(),
                    phase: spec.phase,
                    instance_key: spec.instance_key.clone(),
                    is_root: configured_builder.is_root,
                    post_process: builder.kind == BuilderKind::PostProcess,
                    blocked_assets: visibility.blocked_assets(
                        spec.phase,
                        builder.kind,
                        &deleted_overlay,
                    ),
                    triggers: spec.builder.triggers.clone(),
                })
                .collect::<Vec<_>>();
            if requests.is_empty() {
                continue;
            }
            if configured_builder.package != initialized_package {
                active_pool.initialize(
                    &workspace.root,
                    &configured_builder.package,
                    &config_digest,
                    phase_count,
                    lazy_demand_possible,
                )?;
                initialized_package = configured_builder.package.clone();
                resolver_needs_reset = false;
            } else if resolver_needs_reset {
                active_pool.reset_resolver()?;
                resolver_needs_reset = false;
            }
            let results = if !lazy_demand_possible {
                active_pool.build_parallel(
                    &workspace,
                    &requests,
                    &overlay,
                    &deleted_overlay,
                    &visibility,
                )?
            } else {
                active_pool.build_parallel_lazy(
                    &workspace,
                    &requests,
                    &mut overlay,
                    &mut deleted_overlay,
                    &visibility,
                    &lazy_specs_by_output,
                    &mut lazy_state,
                )?
            };

            let lazy_results = lazy_state.take_results();
            let lazy_source_output = lazy_results
                .iter()
                .any(|lazy_result| lazy_result.spec.builder.build_to == BuildTo::Source);
            for lazy_result in lazy_results {
                record_build_result(
                    &workspace,
                    &state,
                    &lazy_result.spec,
                    lazy_result.result,
                    &mut overlay,
                    &mut deleted_overlay,
                    &mut pending_outputs,
                    &mut pending_deletions,
                    &mut pending_actions,
                )?;
            }
            if lazy_source_output {
                resolver_needs_reset = true;
            }

            for (spec, result) in runnable_phase_specs.into_iter().zip(results) {
                record_build_result(
                    &workspace,
                    &state,
                    &spec,
                    result,
                    &mut overlay,
                    &mut deleted_overlay,
                    &mut pending_outputs,
                    &mut pending_deletions,
                    &mut pending_actions,
                )?;
            }

            if builder.kind == BuilderKind::Normal && builder.build_to == BuildTo::Source {
                resolver_needs_reset = true;
            }
        }

        pool_metrics = Some(active_pool.metrics());
    }

    // Commit only after every dirty action succeeded. Cache-built part files
    // are kept below .dart_tool and are visible to later phases through the
    // overlay and the cache-aware reader.
    for (builder, asset) in pending_deletions {
        let path = output_path(&workspace, builder.as_ref(), &asset)?;
        if path.is_file() {
            fs::remove_file(path)?;
        }
    }
    for (builder, asset, bytes) in pending_outputs {
        write_atomic(&output_path(&workspace, builder.as_ref(), &asset)?, &bytes)?;
    }
    for (action_key, action) in deleted_actions {
        let builder = build_config
            .definition(&action.builder)
            .ok_or_else(|| io::Error::other(format!("unsupported builder: {}", action.builder)))?;
        for output in &action.outputs {
            if expected_outputs.contains(output) {
                continue;
            }
            let path = output_path(&workspace, builder, output)?;
            if path.is_file() {
                fs::remove_file(path)?;
            }
        }
        state.actions.remove(&action_key);
    }
    for (key, action) in pending_actions {
        state.actions.insert(key, action);
    }

    workspace.clear_asset_caches()?;
    state.schema_version = GRAPH_SCHEMA_VERSION;
    state.config_digest = config_digest;
    let post_scan_started = Instant::now();
    let mut post_snapshot = crate::snapshot::scan_packages(&workspace, &scanned_packages)?;
    filesystem_metrics.post_scan_us = post_scan_started.elapsed().as_micros();
    let post_assets_started = Instant::now();
    add_current_generated_assets(&workspace, &state, &mut post_snapshot, &build_config)?;
    add_tracked_dependency_assets(&workspace, &state, &mut post_snapshot)?;
    add_tracked_glob_assets(&workspace, &state, &mut post_snapshot)?;
    filesystem_metrics.post_assets_us = post_assets_started.elapsed().as_micros();
    state.update_assets(post_snapshot);
    let graph_save_started = Instant::now();
    state.save(&state_path)?;
    let graph_save_us = graph_save_started.elapsed().as_micros();
    let graph_save_bytes = graph_file_size(&state_path);
    if runtime_metrics_enabled() {
        if let Some(pool_metrics) = pool_metrics {
            print_pool_metrics(pool_metrics);
        }
        print_filesystem_metrics(&filesystem_metrics);
        print_graph_metrics(
            graph_load_us,
            graph_save_us,
            graph_load_bytes,
            graph_save_bytes,
            false,
        );
        print_workspace_read_metrics(workspace.read_metrics());
    }
    println!("Build completed (Rust frontend)");
    Ok(())
}

/// Record the build_runner equivalent of a generated primary input which was
/// planned but not emitted by its producer. Keeping the empty action in the
/// graph makes the missing-output state stable across no-op builds and removes
/// any stale outputs from a previous successful run at the same commit
/// boundary as ordinary Builder results.
fn record_missing_primary_input(
    workspace: &Workspace,
    state: &GraphState,
    spec: &BuildSpec,
    overlay: &mut BTreeMap<String, Vec<u8>>,
    deleted_overlay: &mut BTreeSet<String>,
    pending_deletions: &mut Vec<(Arc<BuilderDefinition>, String)>,
    pending_actions: &mut Vec<(String, ActionState)>,
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
        deleted_overlay.insert(output.clone());
        overlay.remove(&output);
        if workspace.asset_exists_at(&output, spec.builder.build_to)? {
            pending_deletions.push((spec.builder.clone(), output));
        }
    }
    pending_actions.push((
        key,
        ActionState {
            builder: spec.builder.id.to_owned(),
            input: spec.input.clone(),
            reads: Vec::new(),
            resolver_reads: Vec::new(),
            glob_reads: Vec::new(),
            outputs: Vec::new(),
            output_digests: BTreeMap::new(),
            status: "skipped_missing_input".to_owned(),
        },
    ));
    Ok(())
}

fn record_build_result(
    workspace: &Workspace,
    state: &GraphState,
    spec: &BuildSpec,
    result: BuildResult,
    overlay: &mut BTreeMap<String, Vec<u8>>,
    deleted_overlay: &mut BTreeSet<String>,
    pending_outputs: &mut Vec<(Arc<BuilderDefinition>, String, Vec<u8>)>,
    pending_deletions: &mut Vec<(Arc<BuilderDefinition>, String)>,
    pending_actions: &mut Vec<(String, ActionState)>,
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
            deleted_overlay.insert(deleted.clone());
            overlay.remove(deleted);
            pending_deletions.push((spec.builder.clone(), deleted.clone()));
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
                && !deleted_overlay.contains(&generated.asset)
                && (overlay.contains_key(&generated.asset)
                    || workspace.asset_exists_or_cache(&generated.asset)?)
            {
                return Err(io::Error::other(format!(
                    "post-process output conflicts with an existing asset: {}",
                    generated.asset
                )));
            }
        }
        overlay.insert(generated.asset.clone(), generated.bytes.clone());
        deleted_overlay.remove(&generated.asset);
        pending_outputs.push((
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
                    deleted_overlay.insert(previous_output.clone());
                    pending_deletions.push((spec.builder.clone(), previous_output.clone()));
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
            deleted_overlay.insert(expected.clone());
            if workspace.asset_exists_at(expected, builder.build_to)? {
                pending_deletions.push((spec.builder.clone(), expected.clone()));
            }
        }
    }
    for generated in &result.outputs {
        output_digests.insert(generated.asset.clone(), digest_bytes(&generated.bytes));
    }
    pending_actions.push((
        spec.action_key(),
        ActionState {
            builder: spec.builder.id.to_owned(),
            input: spec.input.clone(),
            reads: result.reads,
            resolver_reads: result.resolver_reads,
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

/// Return the order in which configured builders may observe each other's
/// outputs. Manifest entries retain target-first ordering for stable planning,
/// but execution must complete every normal phase before moving to the next
/// target order so cross-target phase dependencies see fresh overlay outputs.
fn execution_order(builders: &[ConfiguredBuilder]) -> Vec<usize> {
    let mut order = (0..builders.len()).collect::<Vec<_>>();
    order.sort_by(|left_index, right_index| {
        let left = &builders[*left_index];
        let right = &builders[*right_index];
        (left.definition.kind == BuilderKind::PostProcess)
            .cmp(&(right.definition.kind == BuilderKind::PostProcess))
            .then_with(|| left.phase.cmp(&right.phase))
            .then_with(|| left.target_order.cmp(&right.target_order))
            .then_with(|| left.target.cmp(&right.target))
            .then_with(|| left.definition.id.cmp(&right.definition.id))
            .then_with(|| left.package.cmp(&right.package))
    });
    order
}

fn expand_dirty_dependents(
    dirty: &mut Vec<crate::plan::BuildSpec>,
    specs: &[crate::plan::BuildSpec],
    state: &GraphState,
) {
    let specs_by_key = specs
        .iter()
        .map(|spec| {
            (
                spec.action_key(),
                spec.clone(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut dependents_by_asset = BTreeMap::<String, Vec<String>>::new();
    for (action_key, action) in &state.actions {
        for dependency in std::iter::once(&action.input)
            .chain(action.reads.iter())
            .chain(action.resolver_reads.iter())
        {
            dependents_by_asset
                .entry(dependency.clone())
                .or_default()
                .push(action_key.clone());
        }
    }

    let mut dirty_keys = dirty
        .iter()
        .map(|spec| spec.action_key())
        .collect::<BTreeSet<_>>();
    let mut cursor = 0;
    while cursor < dirty.len() {
        let source_key = dirty[cursor].action_key();
        let mut source_outputs = BTreeSet::new();
        if let Some(spec) = specs_by_key.get(&source_key) {
            // Use the current plan so a producer that was previously skipped
            // still exposes the output that it may emit in this build.
            source_outputs.extend(spec.outputs.iter().cloned());
        }
        if let Some(action) = state.actions.get(&source_key) {
            // Keep prior outputs as well for builders whose runtime output
            // inventory is not known until execution (for example
            // post-process builders), and to retire old mappings.
            source_outputs.extend(action.outputs.iter().cloned());
        }
        for output in source_outputs {
            for dependent_key in dependents_by_asset
                .get(&output)
                .into_iter()
                .flatten()
            {
                if dirty_keys.insert(dependent_key.clone()) {
                    if let Some(spec) = specs_by_key.get(dependent_key) {
                        dirty.push(spec.clone());
                    }
                }
            }
        }
        cursor += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::{execution_order, expand_dirty_dependents};
    use crate::builder::{BuildTo, BuilderDefinition, BuilderKind, ConfiguredBuilder};
    use crate::graph::{ActionState, GraphState};
    use crate::plan::BuildSpec;
    use std::collections::BTreeMap;
    use std::sync::Arc;

    fn configured_builder(
        id: &str,
        target: &str,
        target_order: u32,
        phase: u32,
    ) -> ConfiguredBuilder {
        ConfiguredBuilder {
            definition: Arc::new(BuilderDefinition {
                id: id.to_owned(),
                kind: BuilderKind::Normal,
                extensions: Vec::new(),
                post_process_input_extensions: Vec::new(),
                build_to: BuildTo::Source,
                phase,
                is_optional: false,
                output_is_optional: false,
                required_input_suffixes: Vec::new(),
                excluded_input_suffixes: Vec::new(),
                applies_builder: None,
                triggers: Vec::new(),
            }),
            target: target.to_owned(),
            package: "app".to_owned(),
            is_root: true,
            target_order,
            phase,
            excluded_input_suffixes: Vec::new(),
            generate_for: vec!["**".to_owned()],
            generate_for_exclude: Vec::new(),
            target_sources: vec!["**".to_owned()],
            target_sources_exclude: Vec::new(),
            options: BTreeMap::new(),
            runtime_extensions: None,
            runtime_post_process_input_extensions: None,
        }
    }

    fn build_spec(
        builder: &ConfiguredBuilder,
        input: &str,
        outputs: &[&str],
    ) -> BuildSpec {
        BuildSpec {
            builder: builder.definition.clone(),
            target: builder.target.clone(),
            package: builder.package.clone(),
            is_root: builder.is_root,
            phase: builder.phase,
            instance_key: format!(
                "{}|{}|{}|{}",
                builder.target, builder.definition.id, builder.phase, builder.package
            ),
            input: input.to_owned(),
            outputs: outputs.iter().map(|output| (*output).to_owned()).collect(),
            options: builder.options.clone(),
        }
    }

    #[test]
    fn execution_order_runs_cross_target_producer_before_consumer() {
        let builders = vec![
            // Target 0 consumes an output produced by target 1 in an earlier
            // phase. Phase order must win over target order.
            configured_builder("consumer", "app:consumer", 0, 1),
            configured_builder("producer", "app:producer", 1, 0),
        ];

        assert_eq!(execution_order(&builders), vec![1, 0]);
    }

    #[test]
    fn dirty_dependents_use_planned_outputs_and_primary_inputs() {
        let producer_builder = configured_builder("producer", "app:producer", 0, 0);
        let consumer_builder = configured_builder("consumer", "app:consumer", 1, 1);
        let producer = build_spec(
            &producer_builder,
            "app|lib/seed.dart",
            &["app|lib/generated.dart"],
        );
        let consumer = build_spec(
            &consumer_builder,
            "app|lib/generated.dart",
            &["app|lib/consumer.txt"],
        );
        let state = GraphState {
            actions: BTreeMap::from([
                (
                    producer.action_key(),
                    ActionState {
                        builder: producer.builder.id.clone(),
                        input: producer.input.clone(),
                        status: "not_triggered".to_owned(),
                        ..ActionState::default()
                    },
                ),
                (
                    consumer.action_key(),
                    ActionState {
                        builder: consumer.builder.id.clone(),
                        input: consumer.input.clone(),
                        status: "skipped_missing_input".to_owned(),
                        ..ActionState::default()
                    },
                ),
            ]),
            ..GraphState::default()
        };
        let mut dirty = vec![producer.clone()];

        expand_dirty_dependents(&mut dirty, &[producer, consumer.clone()], &state);

        assert!(dirty
            .iter()
            .any(|spec| spec.action_key() == consumer.action_key()));
    }
}
