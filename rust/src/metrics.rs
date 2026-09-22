use crate::builder::{BuilderKind, RustBuildConfig};
use crate::graph::GraphState;
use crate::plan::BuildSpec;
use crate::snapshot::Snapshot;
use crate::worker::PoolMetrics;
use crate::workspace::WorkspaceReadMetrics;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::fmt::Display;
use std::path::Path;

pub(crate) fn runtime_metrics_enabled() -> bool {
    env::var("BUILD_RUNNER_ACCELERATOR_METRICS")
        .map(|value| value == "1")
        .unwrap_or(false)
}

/// Enables the pre-worker plan diagnostics used to investigate unexpectedly
/// large action graphs. The plan-only mode implies metrics so one environment
/// variable is sufficient when reproducing a large workspace.
pub(crate) fn plan_metrics_enabled() -> bool {
    runtime_metrics_enabled() || plan_only_enabled()
}

pub(crate) fn plan_only_enabled() -> bool {
    env::var("BUILD_RUNNER_ACCELERATOR_PLAN_ONLY")
        .map(|value| value == "1")
        .unwrap_or(false)
}

pub(crate) fn print_plan_stage(stage: &str, details: impl Display) {
    eprintln!(
        "Rust plan metrics: stage={stage} rss_kb={} {details}",
        process_rss_kb()
    );
}

/// Print a compact breakdown without cloning any BuildSpec-owned strings.
/// This is intentionally called before worker setup: the large-workspace
/// investigation must still produce useful output when action execution never
/// starts.
pub(crate) fn print_plan_spec_metrics(
    stage: &str,
    specs: &[BuildSpec],
    config: &RustBuildConfig,
) {
    let mut scopes = BTreeMap::<(&str, &str, &str, u32, bool, bool), usize>::new();
    let mut action_keys = BTreeSet::<(&str, &str, &str)>::new();
    let mut builder_inputs = BTreeSet::<(&str, &str, &str)>::new();
    let mut outputs = BTreeSet::<&str>::new();
    let mut required_input_definitions = BTreeSet::<&str>::new();
    let mut output_edges = 0;
    let mut normal_specs = 0;
    let mut post_process_specs = 0;
    let mut optional_specs = 0;
    let mut required_input_specs = 0;
    let mut duplicate_action_keys = 0;
    let mut duplicate_builder_inputs = 0;

    for spec in specs {
        let is_post_process = spec.builder.kind == BuilderKind::PostProcess;
        if is_post_process {
            post_process_specs += 1;
        } else {
            normal_specs += 1;
        }
        if spec.builder.is_optional {
            optional_specs += 1;
        }
        if !spec.builder.required_input_suffixes.is_empty() {
            required_input_specs += 1;
            required_input_definitions.insert(spec.builder.id.as_str());
        }
        output_edges += spec.outputs.len();
        outputs.extend(spec.outputs.iter().map(String::as_str));

        let action_key = (
            spec.target.as_str(),
            spec.instance_key.as_str(),
            spec.input.as_str(),
        );
        if !action_keys.insert(action_key) {
            duplicate_action_keys += 1;
        }
        let builder_input = (
            spec.builder.id.as_str(),
            spec.package.as_str(),
            spec.input.as_str(),
        );
        if !builder_inputs.insert(builder_input) {
            duplicate_builder_inputs += 1;
        }

        let scope = (
            spec.package.as_str(),
            spec.target.as_str(),
            spec.builder.id.as_str(),
            spec.phase,
            is_post_process,
            spec.builder.is_optional,
        );
        *scopes.entry(scope).or_default() += 1;
    }

    print_plan_stage(
        stage,
        format_args!(
            "specs={} normal_specs={} post_process_specs={} optional_specs={} required_input_specs={} required_input_definitions={} output_edges={} unique_outputs={} duplicate_action_keys={} duplicate_builder_inputs={}",
            specs.len(),
            normal_specs,
            post_process_specs,
            optional_specs,
            required_input_specs,
            required_input_definitions.len(),
            output_edges,
            outputs.len(),
            duplicate_action_keys,
            duplicate_builder_inputs,
        ),
    );

    for ((package, target, builder, phase, is_post_process, is_optional), count) in scopes {
        let required_inputs = config
            .definition(builder)
            .map(|definition| definition.required_input_suffixes.len())
            .unwrap_or(0);
        eprintln!(
            "Rust plan breakdown: stage={stage} package={package} target={target} builder={builder} phase={phase} kind={} optional={is_optional} required_inputs={required_inputs} specs={count}",
            if is_post_process { "post_process" } else { "normal" },
        );
    }
}

pub(crate) fn print_graph_action_metrics(state: &GraphState) {
    let mut builder_inputs = BTreeSet::<(&str, &str)>::new();
    let mut statuses = BTreeMap::<&str, usize>::new();
    let mut duplicate_builder_inputs = 0;
    for action in state.actions.values() {
        if !builder_inputs.insert((action.builder.as_str(), action.input.as_str())) {
            duplicate_builder_inputs += 1;
        }
        *statuses.entry(action.status.as_str()).or_default() += 1;
    }
    print_plan_stage(
        "graph-actions",
        format_args!(
            "actions={} unique_builder_inputs={} duplicate_builder_inputs={} statuses={:?}",
            state.actions.len(),
            builder_inputs.len(),
            duplicate_builder_inputs,
            statuses,
        ),
    );
}

#[cfg(target_os = "linux")]
fn process_rss_kb() -> u64 {
    let Ok(status) = fs::read_to_string("/proc/self/status") else {
        return 0;
    };
    status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))
        .and_then(|value| value.split_whitespace().next())
        .and_then(|value| value.parse().ok())
        .unwrap_or(0)
}

#[cfg(not(target_os = "linux"))]
fn process_rss_kb() -> u64 {
    0
}

pub(crate) fn print_pool_metrics(metrics: PoolMetrics) {
    eprintln!(
        "Rust metrics: workers_active={} worker_starts_total={} worker_initializes_total={} worker_resets_total={} resolver_resets_total={} worker_start_us={} worker_initialize_us={} worker_reset_us={} resolver_reset_us={} build_us={} asset_rpc_us={} ipc_frames_sent={} ipc_frames_received={} ipc_bytes_sent={} ipc_bytes_received={} build_result_frames={} build_result_bytes={} build_result_json_bytes={} asset_requests={} read_requests={} read_bytes={} binary_read_responses={} can_read_requests={} find_assets_requests={} find_assets_results={}",
        metrics.active_workers,
        metrics.worker_starts,
        metrics.worker_initializes,
        metrics.worker_resets,
        metrics.resolver_resets,
        metrics.worker_start_us,
        metrics.worker_initialize_us,
        metrics.worker_reset_us,
        metrics.resolver_reset_us,
        metrics.build_us,
        metrics.asset_rpc_us,
        metrics.ipc_frames_sent,
        metrics.ipc_frames_received,
        metrics.ipc_bytes_sent,
        metrics.ipc_bytes_received,
        metrics.build_result_frames,
        metrics.build_result_bytes,
        metrics.build_result_json_bytes,
        metrics.asset_requests,
        metrics.read_requests,
        metrics.read_bytes,
        metrics.binary_read_responses,
        metrics.can_read_requests,
        metrics.find_assets_requests,
        metrics.find_assets_results,
    );
}

pub(crate) fn print_workspace_read_metrics(metrics: WorkspaceReadMetrics) {
    eprintln!(
        "Rust workspace metrics: asset_read_cache_hits={} asset_read_cache_misses={}",
        metrics.asset_read_cache_hits, metrics.asset_read_cache_misses,
    );
}

#[derive(Debug, Default)]
pub(crate) struct FilesystemMetrics {
    pub(crate) initial_scan_us: u128,
    pub(crate) initial_scan_assets: usize,
    pub(crate) initial_scan_bytes: u64,
    pub(crate) initial_generated_us: u128,
    pub(crate) initial_dependencies_us: u128,
    pub(crate) initial_globs_us: u128,
    pub(crate) dirty_check_us: u128,
    pub(crate) post_scan_us: u128,
    pub(crate) post_assets_us: u128,
}

pub(crate) fn snapshot_summary(snapshot: &Snapshot) -> (usize, u64) {
    (
        snapshot.len(),
        snapshot.values().map(|asset| asset.size).sum(),
    )
}

pub(crate) fn print_filesystem_metrics(metrics: &FilesystemMetrics) {
    eprintln!(
        "Rust filesystem metrics: initial_scan_us={} initial_scan_assets={} initial_scan_bytes={} initial_generated_us={} initial_dependencies_us={} initial_globs_us={} dirty_check_us={} post_scan_us={} post_assets_us={}",
        metrics.initial_scan_us,
        metrics.initial_scan_assets,
        metrics.initial_scan_bytes,
        metrics.initial_generated_us,
        metrics.initial_dependencies_us,
        metrics.initial_globs_us,
        metrics.dirty_check_us,
        metrics.post_scan_us,
        metrics.post_assets_us,
    );
}

pub(crate) fn graph_file_size(path: &Path) -> u64 {
    fs::metadata(path)
        .map(|metadata| metadata.len())
        .unwrap_or(0)
}

pub(crate) fn print_graph_metrics(
    load_us: u128,
    save_us: u128,
    load_bytes: u64,
    save_bytes: u64,
    save_skipped: bool,
) {
    eprintln!(
        "Rust graph metrics: load_us={} save_us={} load_bytes={} save_bytes={} save_skipped={}",
        load_us, save_us, load_bytes, save_bytes, save_skipped
    );
}
