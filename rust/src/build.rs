use crate::assets::{
    add_current_generated_assets, add_tracked_dependency_assets, add_tracked_glob_assets,
    config_digest, write_atomic,
};
use crate::builder::{BuildTo, BuilderDefinition, BuilderKind, RustBuildConfig};
use crate::cli::Options;
use crate::digest::digest_bytes;
use crate::frontend::{run_dart_fallback, select_frontend, worker_executable};
use crate::graph::{ActionState, GRAPH_SCHEMA_VERSION, GraphState};
use crate::metrics::{
    FilesystemMetrics, graph_file_size, print_filesystem_metrics, print_graph_metrics,
    print_pool_metrics, print_workspace_read_metrics, runtime_metrics_enabled, snapshot_summary,
};
use crate::plan::{
    build_specs_for_kind, build_specs_for_phase, output_digest, output_path,
    scoped_action_key, validate_unique_outputs,
};
use crate::worker::{BuildRequest, WorkerPool};
use crate::workspace::Workspace;
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
    let (normal_specs, normal_planning_snapshot) = loop {
        let normal_phases = build_config
            .builders
            .iter()
            .filter(|builder| builder.definition.kind == BuilderKind::Normal)
            .map(|builder| builder.phase)
            .collect::<BTreeSet<_>>();
        let mut planning_snapshot = normal_snapshot.clone();
        let mut specs = Vec::new();
        for phase in normal_phases {
            let phase_specs = build_specs_for_phase(
                &workspace,
                &planning_snapshot,
                &build_config,
                BuilderKind::Normal,
                phase,
            )?;
            for spec in &phase_specs {
                // Optional builders are outside the dynamic subset today, but
                // keep this guard aligned with build_runner's lazy output
                // semantics if they are admitted in the future.
                if spec.builder.output_is_optional {
                    continue;
                }
                for output in &spec.outputs {
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
            .map(|spec| scoped_action_key(&spec.target, &spec.builder.id, &spec.input))
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
            break (specs, planning_snapshot);
        }
    };
    // A post-process action may consume an output that is created during this
    // build. The phase-aware planning snapshot includes outputs declared by all
    // normal phases, so post-process builders see every output that will exist
    // when their final phase starts.
    let post_snapshot = normal_planning_snapshot;
    let post_specs = build_specs_for_kind(
        &workspace,
        &post_snapshot,
        &build_config,
        Some(BuilderKind::PostProcess),
    )?;
    let mut specs = normal_specs;
    specs.extend(post_specs);

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
    let dirty_check_started = Instant::now();
    for spec in &specs {
        for output in &spec.outputs {
            if let Some(digest) = output_digest(&workspace, &spec.builder, output)? {
                current_output_digests.insert(output.clone(), digest);
            }
        }

        let key = scoped_action_key(&spec.target, &spec.builder.id, &spec.input);
        let needs_build = match state.actions.get(&key) {
            Some(action) if state.is_compatible(&config_digest) => {
                state.changed_since_previous(action, &current_snapshot, &current_output_digests)
            }
            _ => true,
        };
        if needs_build {
            dirty.push(spec.clone());
        }
    }
    expand_dirty_dependents(&mut dirty, &specs, &state);
    filesystem_metrics.dirty_check_us = dirty_check_started.elapsed().as_micros();

    let expected_keys: BTreeSet<String> = specs
        .iter()
        .map(|spec| scoped_action_key(&spec.target, &spec.builder.id, &spec.input))
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
            state.actions.get(&scoped_action_key(
                &spec.target,
                &spec.builder.id,
                &spec.input,
            ))
        })
        .flat_map(|action| action.outputs.iter().cloned())
        .collect::<BTreeSet<_>>();
    let mut pending_outputs: Vec<(Arc<BuilderDefinition>, String, Vec<u8>)> = Vec::new();
    let mut pending_deletions: Vec<(Arc<BuilderDefinition>, String)> = Vec::new();
    let mut pending_actions = Vec::new();
    if !dirty.is_empty() {
        let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
        let worker_command = worker_executable(options, &build_config)?;
        let phase_count = build_config
            .builders
            .iter()
            .map(|builder| builder.phase)
            .max()
            .unwrap_or(0)
            .saturating_add(1) as usize;
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
        )?;

        // Source outputs remain in the Rust overlay until the transaction commits.
        // Invalidate only the worker's Analyzer graph before a later phase so
        // resolver-backed builders can re-sync those overlay parts without
        // discarding the resident worker's asset-read cache.
        let mut resolver_needs_reset = false;
        let mut initialized_package = first_package;

        for post_process_phase in [false, true] {
            for configured_builder in &build_config.builders {
                let builder = configured_builder.definition.as_ref();
                if (builder.kind == BuilderKind::PostProcess) != post_process_phase {
                    continue;
                }
                let phase_specs = dirty
                    .iter()
                    .filter(|spec| {
                        spec.target == configured_builder.target && spec.builder.id == builder.id
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                let requests = phase_specs
                    .iter()
                    .map(|spec| BuildRequest {
                        builder: spec.builder.id.to_owned(),
                        input: spec.input.clone(),
                        outputs: spec.outputs.clone(),
                        options: spec.options.clone(),
                        phase: spec.phase,
                        instance_key: spec.instance_key.clone(),
                        post_process: builder.kind == BuilderKind::PostProcess,
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
                    )?;
                    initialized_package = configured_builder.package.clone();
                    resolver_needs_reset = false;
                } else if resolver_needs_reset {
                    active_pool.reset_resolver()?;
                    resolver_needs_reset = false;
                }
                let results = active_pool
                    .build_parallel(&workspace, &requests, &overlay, &deleted_overlay)?;

                for (spec, result) in phase_specs.into_iter().zip(results) {
                    if result.status != "success" {
                        return Err(io::Error::other(
                            result.error.unwrap_or_else(|| "Builder failed".to_owned()),
                        ));
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
                        if builder.kind == BuilderKind::Normal
                            && !allowed.contains(&generated.asset)
                        {
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
                            let previous_outputs = state
                                .actions
                                .get(&scoped_action_key(
                                    &spec.target,
                                    &spec.builder.id,
                                    &spec.input,
                                ))
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
                    // build_runner permits a normal builder to declare an output
                    // mapping and then emit no output for a particular input. A
                    // common example is source_gen's shared-part builders: they
                    // skip libraries without generated content. Remove outputs
                    // recorded by the previous action when that happens, just as
                    // build_runner's build state cleanup does.
                    if builder.kind == BuilderKind::Normal || builder.output_is_optional {
                        if let Some(previous) = state.actions.get(&scoped_action_key(
                            &spec.target,
                            &spec.builder.id,
                            &spec.input,
                        )) {
                            for previous_output in &previous.outputs {
                                if !actual_outputs.contains(previous_output.as_str()) {
                                    deleted_overlay.insert(previous_output.clone());
                                    pending_deletions
                                        .push((spec.builder.clone(), previous_output.clone()));
                                }
                            }
                        }
                    }
                    for generated in &result.outputs {
                        output_digests
                            .insert(generated.asset.clone(), digest_bytes(&generated.bytes));
                    }
                    pending_actions.push((
                        scoped_action_key(&spec.target, &spec.builder.id, &spec.input),
                        ActionState {
                            builder: spec.builder.id.to_owned(),
                            input: spec.input,
                            reads: result.reads,
                            resolver_reads: result.resolver_reads,
                            glob_reads: result.glob_reads,
                            outputs: result
                                .outputs
                                .into_iter()
                                .map(|output| output.asset)
                                .collect(),
                            output_digests,
                            status: "success".to_owned(),
                        },
                    ));
                }

                if builder.kind == BuilderKind::Normal && builder.build_to == BuildTo::Source {
                    resolver_needs_reset = true;
                }
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

fn expand_dirty_dependents(
    dirty: &mut Vec<crate::plan::BuildSpec>,
    specs: &[crate::plan::BuildSpec],
    state: &GraphState,
) {
    let specs_by_key = specs
        .iter()
        .map(|spec| {
            (
                scoped_action_key(&spec.target, &spec.builder.id, &spec.input),
                spec.clone(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let mut dependents_by_asset = BTreeMap::<String, Vec<String>>::new();
    for (action_key, action) in &state.actions {
        for dependency in action.reads.iter().chain(action.resolver_reads.iter()) {
            dependents_by_asset
                .entry(dependency.clone())
                .or_default()
                .push(action_key.clone());
        }
    }

    let mut dirty_keys = dirty
        .iter()
        .map(|spec| scoped_action_key(&spec.target, &spec.builder.id, &spec.input))
        .collect::<BTreeSet<_>>();
    let mut cursor = 0;
    while cursor < dirty.len() {
        let source_key = scoped_action_key(
            &dirty[cursor].target,
            &dirty[cursor].builder.id,
            &dirty[cursor].input,
        );
        if let Some(action) = state.actions.get(&source_key) {
            for output in &action.outputs {
                for dependent_key in dependents_by_asset
                    .get(output)
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
        }
        cursor += 1;
    }
}
