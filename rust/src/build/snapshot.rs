use crate::assets::{
    add_current_generated_assets, add_tracked_dependency_assets, add_tracked_glob_assets,
    config_digest as build_config_digest,
};
use crate::builder::RustBuildConfig;
use crate::graph::GraphState;

use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::time::Instant;

pub(super) fn config_digest(
    workspace: &Workspace,
    build_config: &RustBuildConfig,
) -> io::Result<String> {
    build_config_digest(workspace, build_config)
}

pub(super) fn scanned_packages(
    workspace: &Workspace,
    build_config: &RustBuildConfig,
) -> BTreeSet<String> {
    build_config
        .builders
        .iter()
        .map(|builder| builder.package.clone())
        .chain(std::iter::once(workspace.root_package.clone()))
        .collect()
}

pub(super) fn scan_initial(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    scanned_packages: &BTreeSet<String>,
    filesystem_metrics: &mut FilesystemMetrics,
) -> io::Result<BTreeMap<String, crate::snapshot::AssetSnapshot>> {
    let scan_started = Instant::now();
    let mut current_snapshot = crate::snapshot::scan_packages(workspace, scanned_packages)?;
    filesystem_metrics.initial_scan_us = scan_started.elapsed().as_micros();
    let (initial_scan_assets, initial_scan_bytes) = snapshot_summary(&current_snapshot);
    filesystem_metrics.initial_scan_assets = initial_scan_assets;
    filesystem_metrics.initial_scan_bytes = initial_scan_bytes;
    if plan_metrics_enabled() {
        print_plan_stage(
            "workspace-scan",
            format_args!(
                "packages={} assets={} bytes={} elapsed_us={}",
                scanned_packages.len(),
                initial_scan_assets,
                initial_scan_bytes,
                filesystem_metrics.initial_scan_us,
            ),
        );
    }

    let stage_started = Instant::now();
    add_current_generated_assets(workspace, state, &mut current_snapshot, build_config)?;
    filesystem_metrics.initial_generated_us = stage_started.elapsed().as_micros();

    let stage_started = Instant::now();
    add_tracked_dependency_assets(workspace, state, &mut current_snapshot)?;
    filesystem_metrics.initial_dependencies_us = stage_started.elapsed().as_micros();

    let stage_started = Instant::now();
    add_tracked_glob_assets(workspace, state, &mut current_snapshot)?;
    filesystem_metrics.initial_globs_us = stage_started.elapsed().as_micros();

    Ok(current_snapshot)
}

pub(super) fn scan_committed(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    scanned_packages: &BTreeSet<String>,
) -> io::Result<(BTreeMap<String, crate::snapshot::AssetSnapshot>, u128, u128)> {
    let post_scan_started = Instant::now();
    let mut post_snapshot = crate::snapshot::scan_packages(workspace, scanned_packages)?;
    let post_scan_us = post_scan_started.elapsed().as_micros();

    let post_assets_started = Instant::now();
    add_current_generated_assets(workspace, state, &mut post_snapshot, build_config)?;
    add_tracked_dependency_assets(workspace, state, &mut post_snapshot)?;
    add_tracked_glob_assets(workspace, state, &mut post_snapshot)?;
    let post_assets_us = post_assets_started.elapsed().as_micros();

    Ok((post_snapshot, post_scan_us, post_assets_us))
}
