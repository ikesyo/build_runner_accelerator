use crate::builder::{BuildTo, BuilderKind, RustBuildConfig};
use crate::digest::digest_bytes;
use crate::graph::GraphState;
use crate::metrics::{
    plan_metrics_enabled, plan_only_enabled, print_graph_action_metrics, print_plan_spec_metrics,
    print_plan_stage,
};
use crate::plan::{
    BuildSpec, build_specs_for_kind_with_primary_inputs, build_specs_for_phase_with_primary_inputs,
    validate_unique_outputs,
};
use crate::visibility::AssetVisibility;
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;

use super::part_directive::{part_directive_filter_disabled, part_directive_skips};

pub(super) struct PlannedActions {
    pub(super) specs: Vec<BuildSpec>,
    pub(super) generated_output_locations: BTreeMap<String, (BuildTo, bool)>,
    pub(super) visibility: AssetVisibility,
}

impl PlannedActions {
    pub(super) fn expected_outputs(&self) -> BTreeSet<String> {
        self.specs
            .iter()
            .flat_map(|spec| spec.outputs.iter().cloned())
            .collect()
    }
}

pub(super) fn create(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    current_snapshot: &BTreeMap<String, crate::snapshot::AssetSnapshot>,
) -> io::Result<PlannedActions> {
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
                workspace,
                &planning_snapshot,
                build_config,
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
        workspace,
        &post_snapshot,
        build_config,
        Some(BuilderKind::PostProcess),
        &normal_primary_inputs,
    )?;
    let generated_output_locations = normal_specs
        .iter()
        .flat_map(|spec| {
            spec.outputs.iter().cloned().map(|output| {
                (
                    output,
                    (
                        spec.instance.builder.build_to,
                        spec.instance.builder.is_optional,
                    ),
                )
            })
        })
        .collect::<BTreeMap<String, (BuildTo, bool)>>();
    let mut specs = normal_specs;
    specs.extend(post_specs);
    let visibility = AssetVisibility::from_specs(&specs, state, build_config);
    Ok(PlannedActions {
        specs,
        generated_output_locations,
        visibility,
    })
}

pub(super) fn report_metrics(
    plan: &PlannedActions,
    state: &GraphState,
    build_config: &RustBuildConfig,
) {
    let specs = &plan.specs;
    let visibility = &plan.visibility;
    if plan_metrics_enabled() {
        let normal_specs = specs
            .iter()
            .filter(|spec| spec.instance.builder.kind == BuilderKind::Normal)
            .count();
        let (visible_outputs, normal_phase_outputs, post_process_outputs) = visibility.summary();
        print_plan_stage(
            "action-plan",
            format_args!(
                "specs={} normal_specs={} post_process_specs={}",
                specs.len(),
                normal_specs,
                specs.len() - normal_specs,
            ),
        );
        print_plan_stage(
            "visibility",
            format_args!(
                "visible_output_locations={} normal_phase_outputs={} post_process_outputs={}",
                visible_outputs, normal_phase_outputs, post_process_outputs,
            ),
        );
        print_plan_spec_metrics("expected", specs, build_config);
        print_graph_action_metrics(state);
    }
}

pub(super) fn report_plan_only(workspace: &Workspace, plan: &PlannedActions) -> bool {
    if !plan_only_enabled() {
        return false;
    }
    let specs = &plan.specs;
    if part_directive_filter_disabled() {
        eprintln!(
            "Rust plan only: {} actions expected (part-directive filter disabled)",
            specs.len()
        );
    } else {
        // Plan-only runs before the dirty check and overlay resolution
        // (the empty overlay makes the filter read each input from disk,
        // matching a clean build's first pass), so this is a plan-level
        // clean-build estimate — phase-produced inputs and up-to-date
        // outputs are not accounted for.
        let overlay = BTreeMap::new();
        let filtered = specs
            .iter()
            .filter(|spec| part_directive_skips(workspace, &overlay, spec))
            .count();
        eprintln!(
            "Rust plan only: {} actions expected, {} filtered by part directives, ~{} would dispatch (clean-build estimate before dirty check)",
            specs.len(),
            filtered,
            specs.len() - filtered
        );
    }
    eprintln!("Rust plan only: worker startup and output commit skipped");
    true
}
