//! Phase barriers with a dependency-ready workspace action queue.
use super::execution::{ExecutionInputs, ExecutionResult, execution_order};
use super::part_directive::{
    empty_build_result, part_directive_filter_disabled, part_directive_skips,
};
use super::planning::PlannedActions;
use super::results::{record_build_result, record_missing_primary_input};
use super::transaction::PendingTransaction;
use super::workspace_ready::ReadyApplications;
use crate::builder::{BuilderKind, ConfiguredBuilder};
use crate::frontend::worker_executable;
use crate::graph::GraphState;
use crate::plan::BuildSpec;
use crate::worker::{
    BuildRequest, InputQueue, WorkerPool, WorkspaceBaseline, WorkspaceDispatch, WorkspaceLease,
    shared_analysis_cache_enabled,
};
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::sync::Arc;

/// SCC peers, package dependencies and same-package applications retain their
/// established order. Missing reachability evidence also serializes execution.
fn independent(left: &ConfiguredBuilder, right: &ConfiguredBuilder) -> bool {
    left.package != right.package
        && left.target_order != right.target_order
        && left
            .package_dependencies
            .as_ref()
            .is_some_and(|deps| !deps.contains(&right.package))
        && right
            .package_dependencies
            .as_ref()
            .is_some_and(|deps| !deps.contains(&left.package))
        && left
            .target_dependencies
            .as_ref()
            .is_some_and(|deps| !deps.contains(&right.target))
        && right
            .target_dependencies
            .as_ref()
            .is_some_and(|deps| !deps.contains(&left.target))
}

fn same_phase(left: &ConfiguredBuilder, right: &ConfiguredBuilder) -> bool {
    left.definition.kind == right.definition.kind && left.phase == right.phase
}

fn execution_dependencies(builders: &[ConfiguredBuilder]) -> Vec<Vec<usize>> {
    let order = execution_order(builders);
    let mut dependencies = vec![Vec::new(); builders.len()];
    for (position, &index) in order.iter().enumerate() {
        dependencies[index] = order[..position]
            .iter()
            .copied()
            .filter(|&earlier| {
                same_phase(&builders[earlier], &builders[index])
                    && !independent(&builders[earlier], &builders[index])
            })
            .collect();
    }
    dependencies
}

fn execution_phases(builders: &[ConfiguredBuilder]) -> Vec<Vec<usize>> {
    let mut phases: Vec<Vec<usize>> = Vec::new();
    for index in execution_order(builders) {
        if let Some(phase) = phases.last_mut()
            && same_phase(&builders[phase[0]], &builders[index])
        {
            phase.push(index);
        } else {
            phases.push(vec![index]);
        }
    }
    phases
}

struct PreparedApplication {
    specs: Vec<BuildSpec>,
    requests: Arc<Vec<BuildRequest>>,
    baseline: Option<Arc<WorkspaceBaseline>>,
}

#[derive(Default)]
struct Application {
    prepared: Option<PreparedApplication>,
    inputs: InputQueue,
    in_flight: usize,
    completed: usize,
    owner: Option<usize>,
}

struct Schedule<'a> {
    workspace: &'a Workspace,
    state: &'a mut GraphState,
    plan: &'a PlannedActions,
    dirty: &'a [BuildSpec],
    builders: &'a [ConfiguredBuilder],
    transaction: &'a mut PendingTransaction,
    part_filtered_actions: &'a mut usize,
}

impl Schedule<'_> {
    fn prepare(&mut self, dirty: &[&BuildSpec]) -> io::Result<PreparedApplication> {
        let mut specs = Vec::new();
        for &spec in dirty {
            if let Some((build_to, _)) = self.plan.generated_output_locations.get(&spec.input)
                && (self.transaction.deleted_overlay.contains(&spec.input)
                    || (!self.transaction.overlay.contains_key(&spec.input)
                        && !self.workspace.asset_exists_at(&spec.input, *build_to)?))
            {
                record_missing_primary_input(self.workspace, self.state, spec, self.transaction)?;
                continue;
            }
            if !part_directive_filter_disabled()
                && part_directive_skips(self.workspace, &self.transaction.overlay, spec)
            {
                *self.part_filtered_actions += 1;
                record_build_result(
                    self.workspace,
                    self.state,
                    spec,
                    empty_build_result(spec),
                    self.transaction,
                )?;
            } else {
                specs.push(spec.clone());
            }
        }
        let requests = Arc::new(
            specs
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
                .collect::<Vec<_>>(),
        );

        Ok(PreparedApplication {
            specs,
            requests,
            baseline: None,
        })
    }

    fn run(&mut self, dispatch: &WorkspaceDispatch) -> io::Result<()> {
        let dependencies = execution_dependencies(self.builders);
        let mut applications = (0..self.builders.len())
            .map(|_| Application::default())
            .collect::<Vec<_>>();
        let mut running = vec![None; dispatch.worker_count()];
        let mut packages: Vec<Option<String>> = vec![None; dispatch.worker_count()];
        let shared_analysis = shared_analysis_cache_enabled();
        let mut dirty_by_application: BTreeMap<_, Vec<_>> = BTreeMap::new();
        for spec in self.dirty {
            dirty_by_application
                .entry((
                    spec.instance.target.as_str(),
                    spec.instance.builder.id.as_str(),
                    spec.instance.phase,
                ))
                .or_default()
                .push(spec);
        }
        for phase in execution_phases(self.builders) {
            let mut ready = ReadyApplications::new(&dependencies, &phase);
            let first = &self.builders[phase[0]];
            let hidden = self
                .plan
                .visibility
                .blocked_assets(first.phase, first.definition.kind, &BTreeSet::new())
                .into_iter()
                .collect::<BTreeSet<_>>();
            let mut baseline: Option<Arc<WorkspaceBaseline>> = None;
            let mut remaining = phase.len();
            while remaining > 0 {
                while let Some(index) = ready.newly_ready.pop_front() {
                    let builder = &self.builders[index];
                    let dirty = dirty_by_application
                        .get(&(
                            builder.target.as_str(),
                            builder.definition.id.as_str(),
                            builder.phase,
                        ))
                        .map(Vec::as_slice)
                        .unwrap_or(&[]);
                    let prepared = self.prepare(dirty)?;
                    if prepared.requests.is_empty() {
                        remaining -= 1;
                        ready.finish(index);
                    } else {
                        applications[index].inputs = InputQueue::new(prepared.requests.len());
                        applications[index].prepared = Some(prepared);
                        ready.inputs.insert(
                            index,
                            &self.builders[index].package,
                            applications[index].inputs.remaining(),
                            0,
                            None,
                        );
                    }
                }
                if remaining == 0 {
                    break;
                }
                for worker in 0..running.len() {
                    if running[worker].is_some() {
                        continue;
                    }
                    let Some(index) = ready.inputs.choose(worker, packages[worker].as_deref())
                    else {
                        continue;
                    };
                    ready.inputs.remove(index);
                    let app = &mut applications[index];
                    let prepared = app.prepared.as_mut().unwrap();
                    if prepared.baseline.is_none() {
                        if !baseline.as_ref().is_some_and(|baseline| {
                            baseline.matches(
                                &self.transaction.overlay,
                                &self.transaction.deleted_overlay,
                                &hidden,
                            )
                        }) {
                            baseline = Some(WorkspaceBaseline::new(
                                self.workspace,
                                &self.transaction.overlay,
                                &self.transaction.deleted_overlay,
                                &self.plan.visibility,
                                &hidden,
                            )?);
                        }
                        prepared.baseline = baseline.clone();
                    }
                    let width = if shared_analysis { running.len() } else { 1 };
                    let range = app.inputs.take(width).expect("ready input queue");
                    dispatch.send(
                        worker,
                        WorkspaceLease {
                            application: index,
                            package: self.builders[index].package.clone(),
                            requests: prepared.requests.clone(),
                            range: range.clone(),
                            baseline: prepared.baseline.as_ref().unwrap().clone(),
                        },
                    )?;
                    app.owner.get_or_insert(worker);
                    app.in_flight += 1;
                    ready.inputs.insert(
                        index,
                        &self.builders[index].package,
                        app.inputs.remaining(),
                        app.in_flight,
                        if shared_analysis { None } else { app.owner },
                    );
                    packages[worker] = Some(self.builders[index].package.clone());
                    running[worker] = Some((index, range));
                }
                if running.iter().all(Option::is_none) {
                    return Err(io::Error::other(
                        "workspace scheduler has pending work without a runnable action",
                    ));
                }
                let completed = dispatch.receive()?;
                let lease = running
                    .get_mut(completed.worker)
                    .ok_or_else(|| io::Error::other("invalid workspace completion worker"))?
                    .take();
                if lease != Some((completed.application, completed.range.clone())) {
                    return Err(io::Error::other(
                        "workspace completion does not match its lease",
                    ));
                }
                let results = completed.results?;
                if results.len() != completed.range.len() {
                    return Err(io::Error::other("workspace lease result count mismatch"));
                }
                self.state.resolver_dep_graph.extend(completed.dep_graph);
                ready.inputs.remove(completed.application);
                let app = &mut applications[completed.application];
                app.inputs.observe(completed.elapsed, completed.range.len());
                let prepared = app.prepared.as_ref().unwrap();
                for (spec, result) in prepared.specs[completed.range.clone()].iter().zip(results) {
                    record_build_result(
                        self.workspace,
                        self.state,
                        spec,
                        result,
                        self.transaction,
                    )?;
                }
                app.completed += completed.range.len();
                app.in_flight -= 1;
                ready.inputs.insert(
                    completed.application,
                    &self.builders[completed.application].package,
                    app.inputs.remaining(),
                    app.in_flight,
                    if shared_analysis { None } else { app.owner },
                );
                if app.completed == prepared.requests.len() {
                    app.prepared = None;
                    remaining -= 1;
                    ready.finish(completed.application);
                }
            }
        }
        Ok(())
    }
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
        let builders = build_config
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
        let width = if shared_analysis_cache_enabled() {
            dirty.len()
        } else {
            builders
                .iter()
                .map(|builder| &builder.package)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
        };
        pool.with_workspace_dispatch(
            workspace,
            build_config.phase_count(),
            width,
            &plan.visibility,
            |dispatch| {
                Schedule {
                    workspace,
                    state,
                    plan,
                    dirty: &dirty,
                    builders: &builders,
                    transaction: &mut transaction,
                    part_filtered_actions: &mut part_filtered_actions,
                }
                .run(dispatch)
            },
        )?;
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

    fn builder(package: &str, target_order: u32, phase: u32) -> ConfiguredBuilder {
        let mut builder =
            configured_builder("copy", &format!("{package}:{package}"), target_order, phase);
        builder.package = package.into();
        builder.target_dependencies = Some(BTreeSet::new());
        builder
    }

    #[test]
    fn dependencies_release_successors_without_waiting_for_independent_peers() {
        let mut builders = vec![
            builder("a", 0, 0),
            builder("b", 1, 0),
            builder("c", 2, 0),
            builder("d", 3, 1),
        ];
        builders[2].package_dependencies = Some(BTreeSet::from(["a".into()]));
        assert_eq!(
            execution_dependencies(&builders),
            vec![vec![], vec![], vec![0], vec![]]
        );
        assert_eq!(execution_phases(&builders), vec![vec![0, 1, 2], vec![3]]);
        // C can run after A even while B is still active. Missing evidence
        // restores a predecessor rather than assuming independence.
        builders[1].target_dependencies = None;
        assert_eq!(execution_dependencies(&builders)[2], vec![0, 1]);
    }

    #[test]
    fn ready_queue_releases_each_successor_only_after_all_predecessors() {
        let mut queue =
            ReadyApplications::new(&[vec![], vec![], vec![0], vec![0, 1]], &[0, 1, 2, 3]);
        assert_eq!(queue.newly_ready.drain(..).collect::<Vec<_>>(), vec![0, 1]);
        queue.finish(0);
        assert_eq!(queue.newly_ready.drain(..).collect::<Vec<_>>(), vec![2]);
        queue.finish(2);
        assert!(queue.newly_ready.is_empty());
        queue.finish(1);
        assert_eq!(queue.newly_ready.drain(..).collect::<Vec<_>>(), vec![3]);
    }

    #[test]
    fn same_package_and_scc_peers_retain_order_and_posts_have_a_barrier() {
        let left = builder("a", 0, 0);
        let mut right = builder("b", 0, 0);
        assert_eq!(
            execution_dependencies(&[left.clone(), right.clone()]),
            vec![vec![], vec![0]]
        );
        right.target_order = 1;
        right.package = "a".into();
        assert_eq!(
            execution_dependencies(&[left.clone(), right.clone()]),
            vec![vec![], vec![0]]
        );
        Arc::make_mut(&mut right.definition).kind = BuilderKind::PostProcess;
        assert_eq!(execution_phases(&[left, right]), vec![vec![0], vec![1]]);
    }
}
