use crate::snapshot::Snapshot;
use crate::worker::PoolMetrics;
use crate::workspace::WorkspaceReadMetrics;
use std::env;
use std::fs;
use std::path::Path;

pub(crate) fn runtime_metrics_enabled() -> bool {
    env::var("FAST_BUILD_RUNNER_METRICS")
        .map(|value| value == "1")
        .unwrap_or(false)
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
