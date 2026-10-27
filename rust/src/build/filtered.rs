//! Build filters select roots, not the graph or the set of allowed outputs.
use super::{
    commit, planning::PlannedActions, results::record_build_result, transaction::PendingTransaction,
};
use crate::{
    build_filter::BuildFilter,
    builder::RustBuildConfig,
    cli::Options,
    frontend::worker_executable,
    graph::GraphState,
    metrics::{print_pool_metrics, runtime_metrics_enabled},
    plan::BuildSpec,
    worker::{LazyBuildState, PoolMetrics, WorkerPool},
    workspace::Workspace,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    io,
    path::Path,
};

/// Executes selected output roots against the complete planned action graph.
/// The starting snapshot and compatible graph provide reuse evidence; recorded
/// output locations provide the old-path evidence for cleanup across config
/// changes. Only demanded actions enter the next graph, while each demanded
/// action publishes all of its sibling outputs together. A worker/probe error
/// returns before filesystem commit; an error during commit can still leave
/// partial filesystem changes until undo recovery runs before graph reuse.
#[expect(
    clippy::too_many_arguments,
    reason = "Filtered execution consumes the same planned transaction inputs as ordinary execution"
)]
pub(super) fn run(
    options: &Options,
    pool: Option<&mut WorkerPool>,
    workspace: &Workspace,
    state: &mut GraphState,
    config: &RustBuildConfig,
    config_digest: &str,
    state_path: &Path,
    scanned_packages: &BTreeSet<String>,
    plan: &PlannedActions,
    filters: &[BuildFilter],
    session_start: bool,
    current_snapshot: &crate::snapshot::Snapshot,
    changed_paths: &BTreeSet<std::path::PathBuf>,
    retained_output_guard: bool,
) -> io::Result<()> {
    let settings = &options.settings;
    let mut pool = pool;
    // Preserve only source-state evidence from the start of a filtered build.
    // Old and current outputs are refreshed from the committed filesystem,
    // including outputs removed by this transition.
    let mut generated_assets: BTreeSet<String> = state.output_locations.keys().cloned().collect();
    generated_assets.extend(state.watch_generated_sources.iter().cloned());
    generated_assets.extend(
        state
            .actions
            .values()
            .flat_map(|action| action.outputs.iter().cloned()),
    );
    generated_assets.extend(plan.expected_outputs());
    let previous_declared = if !session_start && state.is_compatible(config_digest) {
        // An unchanged file can become a generated-output conflict when an
        // added input restores its producer chain (stock misclassifiedSources).
        let mut sources = state.assets.clone();
        for asset in &state.watch_generated_sources {
            sources.remove(asset);
        }
        super::planning::create(workspace, state, config, &sources)?.expected_outputs()
    } else {
        BTreeSet::new()
    };
    let specs: BTreeMap<String, BuildSpec> = plan
        .specs
        .iter()
        .flat_map(|spec| {
            spec.outputs
                .iter()
                .map(move |output| (output.clone(), spec.clone()))
        })
        .collect();
    let mut roots = Vec::new();
    for spec in &plan.specs {
        let selected = spec.outputs.iter().any(|output| {
            filters
                .iter()
                .any(|filter| filter.matches(output, &workspace.root_package))
        });
        if selected {
            // One action publishes every sibling output as a single unit.
            // Multiple matched siblings must therefore schedule one root.
            roots.push(spec.outputs[0].clone());
        }
    }
    let expected_keys: BTreeSet<String> = plan.specs.iter().map(|spec| spec.action_key()).collect();
    let deleted_actions = state
        .actions
        .iter()
        .filter(|(key, action)| {
            config.definition(&action.builder).is_some() && !expected_keys.contains(*key)
        })
        .map(|(key, action)| (key.clone(), action.clone()))
        .collect();
    let mut transaction = PendingTransaction::new(&[], state, deleted_actions);
    transaction.deleted_overlay.extend(
        state
            .watch_generated_sources
            .iter()
            .filter(|asset| !specs.contains_key(*asset))
            .cloned(),
    );
    transaction.clean_artifact_tree = !state.is_compatible(config_digest);
    if transaction.clean_artifact_tree {
        // Stock clean plans read source files and freshly demanded artifacts,
        // then replace the entire artifact tree on successful commit.
        for package in scanned_packages {
            for (asset, _) in workspace.list_cached_package_assets(package)? {
                if plan.visibility.location(&asset) == Some(crate::builder::BuildTo::Cache)
                    || !workspace.asset_exists_at(&asset, crate::builder::BuildTo::Source)?
                {
                    transaction.deleted_overlay.insert(asset);
                }
            }
        }
    }
    // The stock file index never treats an undeclared artifact as a source.
    // Hide such files before reads/canRead, including compatible incremental
    // builds; their physical retention is a separate session-dependent rule.
    for package in scanned_packages {
        for (asset, _) in workspace.list_cached_package_assets(package)? {
            if plan.visibility.location(&asset).is_none()
                && !workspace.asset_exists_at(&asset, crate::builder::BuildTo::Source)?
            {
                transaction.deleted_overlay.insert(asset);
            }
        }
    }
    let mut demand_snapshot = current_snapshot.clone();
    // Outputs of deleted producers are logically missing before commit. Their
    // old physical bytes must invalidate reused consumers, including canRead.
    for asset in &transaction.deleted_overlay {
        demand_snapshot.insert(
            asset.clone(),
            crate::snapshot::AssetSnapshot {
                exists: false,
                digest: crate::digest::digest_bytes(b"<missing>"),
                size: 0,
            },
        );
    }
    let mut lazy = LazyBuildState::filtered(
        state.clone(),
        demand_snapshot,
        state.is_compatible(config_digest),
    );
    lazy.keep_modified_outputs = settings.keeps_modified_outputs();
    let mut owned_pool = None;
    let dirty_roots = lazy.probe_filtered_roots(
        workspace,
        &roots,
        &mut transaction.overlay,
        &mut transaction.deleted_overlay,
        &plan.visibility,
        &specs,
    )?;
    let mut pool_metrics = PoolMetrics::default();
    if !dirty_roots.is_empty() {
        if pool.is_none() {
            let worker = worker_executable(options, config)?;
            owned_pool = Some(WorkerPool::start(
                workspace,
                options.dart_binary.as_deref().unwrap_or("dart"),
                &worker,
                options.jobs,
                options.worker.is_none(),
            )?);
        }
        let active = pool
            .as_deref_mut()
            .or(owned_pool.as_mut())
            .expect("pool is available");
        // Resolver metadata from a failed earlier filtered cycle must not be
        // committed by a later successful build. Drain it before any operation
        // on the resident pool can fail.
        drop(active.take_dep_graph());
        active.prepare_for_filtered_roots(workspace, dirty_roots.len())?;
        active.set_retained_output_guard(retained_output_guard);
        active.initialize(
            workspace,
            &workspace.root_package,
            config_digest,
            config.phase_count(),
            true,
        )?;
        // A watch worker must not expose an overlay retained from the preceding
        // build, including files that were generated but are no longer demanded.
        active.reset_resolver(
            &workspace.root,
            &transaction.overlay,
            BTreeSet::new(),
            BTreeSet::new(),
            BTreeSet::new(),
            BTreeSet::new(),
            false,
        )?;
        let built = active.build_filtered(
            workspace,
            &dirty_roots,
            &mut transaction.overlay,
            &mut transaction.deleted_overlay,
            &plan.visibility,
            &specs,
            &mut lazy,
        );
        let dep_graph = active.take_dep_graph();
        built?;
        state.resolver_dep_graph.extend(dep_graph);
        pool_metrics = active.metrics();
    } else if let Some(active) = pool.as_deref() {
        // A filtered watch pool may be resident but intentionally unstarted.
        pool_metrics = active.metrics();
    }
    for result in lazy.take_results() {
        record_build_result(
            workspace,
            state,
            &result.spec,
            result.result,
            &mut transaction,
        )?;
    }
    let demanded = lazy.demanded_keys();
    let rebuilt: BTreeSet<&String> = transaction.pending_actions.keys().collect();
    let actual_outputs: BTreeSet<String> = state
        .actions
        .iter()
        .filter(|(key, _)| demanded.contains(*key) && !rebuilt.contains(key))
        .flat_map(|(_, action)| action.outputs.iter().cloned())
        .chain(
            transaction
                .pending_actions
                .values()
                .flat_map(|action| action.outputs.iter().cloned()),
        )
        .collect();
    let compatible = state.is_compatible(config_digest);
    let declared = plan.expected_outputs();
    for action in state.actions.values() {
        for output in &action.outputs {
            let previous_location = state
                .output_locations
                .get(output)
                .map(|cache| {
                    if *cache {
                        crate::builder::BuildTo::Cache
                    } else {
                        crate::builder::BuildTo::Source
                    }
                })
                .or_else(|| {
                    compatible
                        .then(|| config.definition(&action.builder).map(|b| b.build_to))
                        .flatten()
                })
                .ok_or_else(|| io::Error::other("previous output location is unavailable"))?;
            if !declared.contains(output)
                || (!compatible
                    && ((previous_location == crate::builder::BuildTo::Source
                        && !actual_outputs.contains(output))
                        || plan.visibility.location(output) != Some(previous_location)))
            {
                transaction
                    .pending_location_deletions
                    .push((previous_location, output.clone()));
            }
        }
    }
    let recorded: BTreeSet<&String> = if compatible {
        state
            .actions
            .values()
            .flat_map(|action| &action.outputs)
            .collect()
    } else {
        BTreeSet::new()
    };
    if session_start && compatible {
        // Stock scans the artifact tree on restart. Unlike package-path
        // files, unrecorded artifacts are conflicts even if their producing
        // input disappeared and they are no longer declared outputs.
        for package in scanned_packages {
            for (asset, _) in workspace.list_cached_package_assets(package)? {
                let previously_actual_cache =
                    recorded.contains(&asset) && state.output_locations.get(&asset) == Some(&true);
                let currently_actual_cache = actual_outputs.contains(&asset)
                    && plan.visibility.location(&asset) == Some(crate::builder::BuildTo::Cache);
                if !previously_actual_cache && !currently_actual_cache {
                    transaction
                        .pending_location_deletions
                        .push((crate::builder::BuildTo::Cache, asset));
                }
            }
        }
    }
    // On restart, declared outputs absent from the previous incremental
    // state are conflicts, not reusable source inputs. Continuing watch also
    // classifies newly created/modified unrecorded package files as conflicts.
    // Delete only after the demanded build succeeded, keeping every actual sibling.
    for spec in &plan.specs {
        for output in &spec.outputs {
            if spec.instance.builder.build_to == crate::builder::BuildTo::Cache
                && workspace.asset_exists_at(output, crate::builder::BuildTo::Source)?
            {
                let mut source_builder = (*spec.instance.builder).clone();
                source_builder.build_to = crate::builder::BuildTo::Source;
                transaction
                    .pending_deletions
                    .push((std::sync::Arc::new(source_builder), output.clone()));
            }
            if spec.instance.builder.build_to == crate::builder::BuildTo::Source
                && (session_start || !compatible)
                && workspace.asset_exists_at(output, crate::builder::BuildTo::Cache)?
            {
                transaction
                    .pending_location_deletions
                    .push((crate::builder::BuildTo::Cache, output.clone()));
            }
            let source_conflict_changed = spec.instance.builder.build_to
                == crate::builder::BuildTo::Source
                && !state.watch_generated_sources.contains(output)
                && (state.assets.get(output) != current_snapshot.get(output)
                    || changed_paths.contains(&crate::watch::normalized_watch_path(
                        &workspace.path_for_asset(output)?,
                    )));
            let newly_declared_source = !session_start
                && spec.instance.builder.build_to == crate::builder::BuildTo::Source
                && !state.watch_generated_sources.contains(output)
                && !previous_declared.contains(output);
            if (session_start || source_conflict_changed || newly_declared_source)
                && !recorded.contains(output)
                && !actual_outputs.contains(output)
                && workspace.asset_exists_at(output, spec.instance.builder.build_to)?
            {
                transaction
                    .pending_deletions
                    .push((spec.instance.builder.clone(), output.clone()));
            }
        }
    }
    // Undemanded but still-declared normal outputs survive this build on disk.
    // They are omitted from the next incremental state, exactly as stock does.
    state.actions.retain(|key, _| demanded.contains(key));
    state.was_filtered = true;
    state.watch_generated_sources.extend(
        plan.generated_output_locations
            .iter()
            .filter(|(_, (location, _))| *location == crate::builder::BuildTo::Source)
            .map(|(asset, _)| asset.clone()),
    );
    commit::commit(
        state,
        commit::CommitInputs {
            only_check: settings.only_check,
            keep_modified_outputs: settings.keeps_modified_outputs(),
            explicit_keep_modified_outputs: settings.keep_modified_outputs,
            workspace,
            state_path,
            build_config: config,
            config_digest: config_digest.to_owned(),
            scanned_packages,
            expected_outputs: plan.expected_outputs(),
            source_snapshot_evidence: None,
            filtered_snapshot_evidence: Some((
                current_snapshot,
                &generated_assets,
                lazy.filtered_snapshot_delta(),
            )),
            transaction,
        },
    )?;
    if runtime_metrics_enabled() {
        print_pool_metrics(pool_metrics);
    }
    println!("Build completed (Rust frontend)");
    Ok(())
}
