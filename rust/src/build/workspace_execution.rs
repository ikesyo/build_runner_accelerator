//! Phase barriers with bounded parallelism across independent packages.
use super::execution::{ExecutionInputs, ExecutionResult, execution_order};
use super::part_directive::{
    empty_build_result, part_directive_filter_disabled, part_directive_skips,
};
use super::results::{record_build_result, record_missing_primary_input};
use super::transaction::PendingTransaction;
use crate::builder::{BuilderKind, ConfiguredBuilder};
use crate::frontend::worker_executable;
use crate::worker::{BuildRequest, WorkerPool, WorkspaceBatch};
use std::io;

/// Preserve the established order for related targets, every same-package
/// application, and SCC peers. Missing reachability evidence serializes too.
fn independent(left: &ConfiguredBuilder, right: &ConfiguredBuilder) -> bool {
    left.package != right.package
        && left.target_order != right.target_order
        && left
            .package_dependencies
            .as_ref()
            .is_some_and(|dependencies| !dependencies.contains(&right.package))
        && right
            .package_dependencies
            .as_ref()
            .is_some_and(|dependencies| !dependencies.contains(&left.package))
        && left
            .target_dependencies
            .as_ref()
            .is_some_and(|dependencies| !dependencies.contains(&right.target))
        && right
            .target_dependencies
            .as_ref()
            .is_some_and(|dependencies| !dependencies.contains(&left.target))
}

pub(super) fn execution_waves(builders: &[ConfiguredBuilder], jobs: usize) -> Vec<Vec<usize>> {
    let mut remaining = execution_order(builders);
    let mut waves = Vec::new();
    while let Some(&first) = remaining.first() {
        let head = &builders[first];
        let mut wave = Vec::new();
        for (position, &index) in remaining.iter().enumerate() {
            let candidate = &builders[index];
            if candidate.definition.kind != head.definition.kind || candidate.phase != head.phase {
                break;
            }
            // A predecessor stays a predecessor even if it was skipped because
            // this wave is full or it waits on a different package.
            if remaining[..position]
                .iter()
                .all(|&earlier| independent(&builders[earlier], candidate))
            {
                wave.push(index);
                if wave.len() == jobs.max(1) {
                    break;
                }
            }
        }
        remaining.retain(|index| !wave.contains(index));
        waves.push(wave);
    }
    waves
}

pub(super) fn run(inputs: ExecutionInputs<'_>) -> io::Result<ExecutionResult> {
    let ExecutionInputs {
        options,
        workspace,
        state,
        build_config,
        plan,
        dirty_plan,
        retained_output_guard,
        ..
    } = inputs;
    // Workspace admission enforces this boundary before actions. Keep it here
    // too so a future caller cannot silently bypass the demand/replay paths.
    if build_config.builders.iter().any(|builder| {
        builder.definition.is_optional
            || builder.definition.adds_to_library
            || !builder.definition.triggers.is_empty()
    }) {
        return Err(io::Error::other(
            "workspace scheduler requires non-optional builders without shared parts or triggers",
        ));
    }
    let dirty = dirty_plan.dirty;
    eprintln!("Rust frontend: {} build action(s)", dirty.len());
    let mut transaction = PendingTransaction::new(&dirty, state, dirty_plan.deleted_actions);
    let mut part_filtered_actions = 0;
    let mut pool_metrics = None;
    if !dirty.is_empty() {
        let command = worker_executable(options, build_config)?;
        let mut pool = WorkerPool::start_deferred(
            workspace,
            options.dart_binary.as_deref().unwrap_or("dart"),
            &command,
            options.jobs,
            options.worker.is_none(),
        )?;
        pool.set_retained_output_guard(retained_output_guard);
        let active_builders = build_config
            .builders
            .iter()
            .filter(|builder| {
                dirty.iter().any(|spec| {
                    spec.instance.target == builder.target
                        && spec.instance.builder.id == builder.definition.id
                        && spec.instance.phase == builder.phase
                })
            })
            .cloned()
            .collect::<Vec<_>>();
        for wave in execution_waves(&active_builders, options.jobs) {
            let mut batches = Vec::new();
            let mut batch_specs = Vec::new();
            for index in wave {
                let configured = &active_builders[index];
                let mut runnable = Vec::new();
                for spec in dirty.iter().filter(|spec| {
                    spec.instance.target == configured.target
                        && spec.instance.builder.id == configured.definition.id
                        && spec.instance.phase == configured.phase
                }) {
                    if let Some((build_to, _)) = plan.generated_output_locations.get(&spec.input)
                        && (transaction.deleted_overlay.contains(&spec.input)
                            || (!transaction.overlay.contains_key(&spec.input)
                                && !workspace.asset_exists_at(&spec.input, *build_to)?))
                    {
                        record_missing_primary_input(workspace, state, spec, &mut transaction)?;
                        continue;
                    }
                    if !part_directive_filter_disabled()
                        && part_directive_skips(workspace, &transaction.overlay, spec)
                    {
                        part_filtered_actions += 1;
                        record_build_result(
                            workspace,
                            state,
                            spec,
                            empty_build_result(spec),
                            &mut transaction,
                        )?;
                    } else {
                        runnable.push(spec.clone());
                    }
                }
                if runnable.is_empty() {
                    continue;
                }
                batches.push(WorkspaceBatch {
                    package: configured.package.clone(),
                    requests: runnable
                        .iter()
                        .map(|spec| BuildRequest {
                            part_phase_index: None,
                            builder: spec.instance.builder.id.clone(),
                            input: spec.input.clone(),
                            outputs: spec.outputs.clone(),
                            options: spec.instance.options.clone(),
                            phase: spec.instance.phase,
                            instance_key: spec.instance.instance_key.clone(),
                            is_root: spec.instance.is_root,
                            post_process: spec.instance.builder.kind == BuilderKind::PostProcess,
                            triggers: spec.instance.builder.triggers.clone(),
                        })
                        .collect(),
                });
                batch_specs.push(runnable);
            }
            if batches.is_empty() {
                continue;
            }
            let results = pool.build_workspace_batches(
                workspace,
                &batches,
                build_config.phase_count(),
                &transaction.overlay,
                &transaction.deleted_overlay,
                &plan.visibility,
            )?;
            state.resolver_dep_graph.extend(pool.take_dep_graph());
            // No result in this wave can become visible to its peers. Join
            // every worker before recording anything into the next baseline.
            for (specs, results) in batch_specs.into_iter().zip(results) {
                for (spec, result) in specs.into_iter().zip(results) {
                    record_build_result(workspace, state, &spec, result, &mut transaction)?;
                }
            }
        }
        pool_metrics = Some(pool.metrics());
    }
    Ok(ExecutionResult {
        transaction,
        expected_outputs: plan.expected_outputs(),
        pool_metrics,
        part_filtered_actions,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::build::tests::configured_builder;
    use std::collections::BTreeSet;

    #[test]
    fn waves_preserve_dependencies_packages_phases_and_missing_metadata() {
        let mut builders = (0..5)
            .map(|i| {
                let mut builder = configured_builder("copy", &format!("p{i}:p{i}"), i, 0);
                builder.package = format!("p{i}");
                builder.target_dependencies = Some(BTreeSet::new());
                builder
            })
            .collect::<Vec<_>>();
        builders[2].target_dependencies = Some(BTreeSet::from(["p0:p0".into()]));
        builders[3].package = "p1".into();
        builders[4].phase = 1;
        assert_eq!(
            execution_waves(&builders, 3),
            vec![vec![0, 1], vec![2, 3], vec![4]]
        );
        assert!(
            execution_waves(&builders, 1)
                .iter()
                .all(|wave| wave.len() == 1)
        );
        builders[1].target_dependencies = None;
        assert_eq!(execution_waves(&builders, 3)[0], vec![0]);
    }

    #[test]
    fn scc_peers_and_post_process_have_barriers() {
        let mut left = configured_builder("copy", "a:a", 0, 0);
        let mut right = configured_builder("copy", "b:b", 0, 0);
        left.package = "a".into();
        right.package = "b".into();
        left.target_dependencies = Some(BTreeSet::new());
        right.target_dependencies = Some(BTreeSet::new());
        assert_eq!(
            execution_waves(&[left.clone(), right.clone()], 2),
            vec![vec![0], vec![1]]
        );
        right.target_order = 1;
        Arc::make_mut(&mut right.definition).kind = BuilderKind::PostProcess;
        assert_eq!(execution_waves(&[left, right], 2), vec![vec![0], vec![1]]);
    }
    #[test]
    fn package_dependencies_serialize_other_targets_in_that_package() {
        let mut left = configured_builder("copy", "a:extra", 0, 0);
        let mut right = configured_builder("copy", "b:custom", 1, 0);
        left.package = "a".into();
        right.package = "b".into();
        left.target_dependencies = Some(BTreeSet::new());
        right.target_dependencies = Some(BTreeSet::new());
        right.package_dependencies = Some(BTreeSet::from(["a".into()]));
        assert_eq!(execution_waves(&[left, right], 2), vec![vec![0], vec![1]]);
    }
    use std::sync::Arc;
}
