use crate::builder::{BuildTo, BuilderKind, ConfiguredBuilder, RustBuildConfig};
use crate::cli::Options;
use crate::frontend::worker_executable;
use crate::graph::GraphState;
use crate::plan::BuildSpec;
use crate::worker::{BuildRequest, LazyBuildState, PoolMetrics, WorkerPool};
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;

use super::dirty::DirtyPlan;
use super::part_directive::{
    empty_build_result, part_directive_filter_disabled, part_directive_skips,
};
use super::planning::PlannedActions;
use super::results::{record_build_result, record_missing_primary_input};
use super::transaction::PendingTransaction;

pub(super) struct ExecutionInputs<'a> {
    pub(super) options: &'a Options,
    pub(super) workspace: &'a Workspace,
    /// Workers add resolver dependency edges here. Action and asset state
    /// stays staged until commit.
    pub(super) state: &'a mut GraphState,
    pub(super) build_config: &'a RustBuildConfig,
    pub(super) config_digest: &'a str,
    pub(super) plan: &'a PlannedActions,
    pub(super) dirty_plan: DirtyPlan,
}

pub(super) struct ExecutionResult {
    pub(super) transaction: PendingTransaction,
    pub(super) expected_outputs: BTreeSet<String>,
    pub(super) pool_metrics: Option<PoolMetrics>,
    pub(super) part_filtered_actions: usize,
}

pub(super) fn run(
    pool: Option<&mut WorkerPool>,
    inputs: ExecutionInputs<'_>,
) -> io::Result<ExecutionResult> {
    let ExecutionInputs {
        options,
        workspace,
        state,
        build_config,
        config_digest,
        plan,
        dirty_plan,
    } = inputs;
    let DirtyPlan {
        dirty,
        lazy_force_keys,
        deleted_actions,
    } = dirty_plan;
    let specs = &plan.specs;
    eprintln!("Rust frontend: {} build action(s)", dirty.len());
    let mut worker_pool = pool;
    let mut pool_metrics = None;
    let mut part_filtered_actions: usize = 0;
    let expected_outputs = plan.expected_outputs();
    let mut transaction = PendingTransaction::new(&dirty, state, deleted_actions);
    let lazy_specs_by_output = specs
        .iter()
        .filter(|spec| spec.builder.is_optional && spec.builder.kind == BuilderKind::Normal)
        .flat_map(|spec| {
            spec.outputs
                .iter()
                .map(|output| (output.clone(), spec.clone()))
        })
        .collect::<BTreeMap<_, _>>();
    let lazy_demand_possible = !lazy_force_keys.is_empty() && !lazy_specs_by_output.is_empty();
    // The optional-builder capability flag is part of the pool signature, so
    // derive it from the plan rather than the dirty set: an optional spec
    // leaving the dirty set must not restart the resident workers.
    let optional_builder_capability_required = !lazy_specs_by_output.is_empty();
    let mut lazy_state = LazyBuildState::new(lazy_force_keys);
    if !dirty.is_empty() {
        let dart_binary = options.dart_binary.as_deref().unwrap_or("dart");
        let worker_command = worker_executable(options, build_config)?;
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
        let first_package = dirty
            .first()
            .map(|spec| spec.package.clone())
            .expect("dirty actions have a package");
        active_pool.initialize(
            &workspace.root,
            &first_package,
            config_digest,
            phase_count,
            optional_builder_capability_required,
        )?;

        // Outputs remain in the Rust overlay until the transaction commits.
        let mut resolver_needs_reset = false;
        // Source-tree and cache-tree deltas both ride the incremental reset:
        // the worker applies them to its Analyzer filesystem and read caches
        // without dropping the loaded library-cycle graph. A committed Dart
        // asset whose directive set changed is detected by the worker itself,
        // which clears the cached graph only then.
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
                if let Some((build_to, is_optional)) =
                    plan.generated_output_locations.get(&spec.input)
                {
                    // An optional producer may be invoked lazily by this
                    // consumer's BuildStep.readAsString. Keep the consumer
                    // request alive so the resident worker can satisfy that
                    // demand before deciding that the primary input is
                    // missing.
                    if !is_optional {
                        let output_is_visible = !transaction.deleted_overlay.contains(&spec.input)
                            && (transaction.overlay.contains_key(&spec.input)
                                || workspace.asset_exists_at(&spec.input, *build_to)?);
                        if !output_is_visible {
                            record_missing_primary_input(
                                workspace,
                                state,
                                &spec,
                                &mut transaction,
                            )?;
                            continue;
                        }
                    }
                }
                runnable_phase_specs.push(spec);
            }
            if transaction.resolver.has_changes() {
                resolver_needs_reset = true;
            }
            // A part-family builder provably emits nothing when its input
            // does not declare the generated file in a `part` directive, so
            // dispatching it to a worker only pays IPC, resolver setup, and
            // generator warmup to arrive at the same empty result. Skip those
            // actions here and record the empty result directly.
            let (skipped_specs, runnable_phase_specs): (Vec<BuildSpec>, Vec<BuildSpec>) =
                if part_directive_filter_disabled() {
                    (Vec::new(), runnable_phase_specs)
                } else {
                    runnable_phase_specs.into_iter().partition(|spec| {
                        part_directive_skips(workspace, &transaction.overlay, spec)
                    })
                };
            part_filtered_actions += skipped_specs.len();
            for spec in skipped_specs {
                record_build_result(
                    workspace,
                    state,
                    &spec,
                    empty_build_result(&spec),
                    &mut transaction,
                )?;
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
                    config_digest,
                    phase_count,
                    optional_builder_capability_required,
                )?;
                initialized_package = configured_builder.package.clone();
                resolver_needs_reset = false;
                transaction.resolver.clear();
            } else if resolver_needs_reset {
                active_pool.reset_resolver(
                    &workspace.root,
                    &transaction.overlay,
                    std::mem::take(&mut transaction.resolver.resolver_updated),
                    std::mem::take(&mut transaction.resolver.resolver_deleted),
                    std::mem::take(&mut transaction.resolver.resolver_cache_updated),
                    std::mem::take(&mut transaction.resolver.resolver_cache_deleted),
                    true,
                )?;
                resolver_needs_reset = false;
            }
            let results = if !lazy_demand_possible {
                active_pool.build_parallel(
                    workspace,
                    &requests,
                    &transaction.overlay,
                    &transaction.deleted_overlay,
                    &plan.visibility,
                )?
            } else {
                active_pool.build_parallel_lazy(
                    workspace,
                    &requests,
                    &mut transaction.overlay,
                    &mut transaction.deleted_overlay,
                    &plan.visibility,
                    &lazy_specs_by_output,
                    &mut lazy_state,
                )?
            };

            // Merge resolver dependency edges the workers reported with
            // these results so dirty checks can expand entrypoints through
            // them, like stock's previousLibraryCycleGraphLoader.
            state
                .resolver_dep_graph
                .extend(active_pool.take_dep_graph());

            let lazy_results = lazy_state.take_results();
            let lazy_source_output = lazy_results
                .iter()
                .any(|lazy_result| lazy_result.spec.builder.build_to == BuildTo::Source);
            for lazy_result in lazy_results {
                record_build_result(
                    workspace,
                    state,
                    &lazy_result.spec,
                    lazy_result.result,
                    &mut transaction,
                )?;
            }
            if lazy_source_output {
                resolver_needs_reset = true;
            }

            for (spec, result) in runnable_phase_specs.into_iter().zip(results) {
                record_build_result(workspace, state, &spec, result, &mut transaction)?;
            }

            if transaction.resolver.has_changes() {
                resolver_needs_reset = true;
            }

            if builder.kind == BuilderKind::Normal && builder.build_to == BuildTo::Source {
                resolver_needs_reset = true;
            }
        }

        pool_metrics = Some(active_pool.metrics());
    }
    Ok(ExecutionResult {
        transaction,
        expected_outputs,
        pool_metrics,
        part_filtered_actions,
    })
}

/// Return the order in which configured builders may observe each other's
/// outputs. Manifest entries retain target-first ordering for stable planning,
/// but execution completes each normal phase before moving to the next target
/// so cross-target phase dependencies see fresh overlay outputs.
pub(super) fn execution_order(builders: &[ConfiguredBuilder]) -> Vec<usize> {
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
