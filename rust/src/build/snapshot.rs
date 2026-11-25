use crate::builder::RustBuildConfig;
use crate::digest::digest_bytes;
use crate::graph::GraphState;
use crate::metrics::{FilesystemMetrics, plan_metrics_enabled, print_plan_stage, snapshot_summary};
use crate::plan::output_path;
use crate::snapshot::{AssetSnapshot, Snapshot, glob_asset_key, glob_digest};
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::time::Instant;

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
    let scan = crate::wall::Span::new("workspace_scan");
    let scan_started = Instant::now();
    let mut current_snapshot = crate::snapshot::scan_packages(workspace, scanned_packages)?;
    filesystem_metrics.initial_scan_us = scan_started.elapsed().as_micros();
    let (initial_scan_assets, initial_scan_bytes) = snapshot_summary(&current_snapshot);
    scan.attribute("scan.assets", initial_scan_assets as u64);
    scan.attribute("scan.bytes", initial_scan_bytes);
    drop(scan);
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
    let timer = crate::wall::Span::new("initial_generated");
    add_current_generated_assets(workspace, state, &mut current_snapshot, build_config)?;
    drop(timer);
    filesystem_metrics.initial_generated_us = stage_started.elapsed().as_micros();

    let stage_started = Instant::now();
    let timer = crate::wall::Span::new("initial_dependencies");
    add_tracked_dependency_assets(workspace, state, &mut current_snapshot)?;
    drop(timer);
    filesystem_metrics.initial_dependencies_us = stage_started.elapsed().as_micros();

    let stage_started = Instant::now();
    let timer = crate::wall::Span::new("initial_globs");
    add_tracked_glob_assets(workspace, state, &mut current_snapshot)?;
    drop(timer);
    filesystem_metrics.initial_globs_us = stage_started.elapsed().as_micros();

    Ok(current_snapshot)
}

pub(super) fn scan_committed(
    workspace: &Workspace,
    state: &GraphState,
    build_config: &RustBuildConfig,
    scanned_packages: &BTreeSet<String>,
) -> io::Result<(BTreeMap<String, crate::snapshot::AssetSnapshot>, u128, u128)> {
    let scan = crate::wall::Span::new("post_scan");
    let post_scan_started = Instant::now();
    let mut post_snapshot = crate::snapshot::scan_packages(workspace, scanned_packages)?;
    let post_scan_us = post_scan_started.elapsed().as_micros();

    drop(scan);
    let _assets = crate::wall::Span::new("post_assets");
    let post_assets_started = Instant::now();
    add_current_generated_assets(workspace, state, &mut post_snapshot, build_config)?;
    add_tracked_dependency_assets(workspace, state, &mut post_snapshot)?;
    add_tracked_glob_assets(workspace, state, &mut post_snapshot)?;
    let post_assets_us = post_assets_started.elapsed().as_micros();

    Ok((post_snapshot, post_scan_us, post_assets_us))
}

fn add_current_generated_assets(
    workspace: &Workspace,
    state: &GraphState,
    snapshot: &mut Snapshot,
    config: &RustBuildConfig,
) -> io::Result<()> {
    for action in state.actions.values() {
        let Some(builder) = config.definition(&action.builder) else {
            continue;
        };
        for output in &action.outputs {
            let path = output_path(workspace, builder, output)?;
            if let Ok(bytes) = fs::read(&path) {
                snapshot.insert(
                    output.clone(),
                    AssetSnapshot {
                        exists: true,
                        digest: digest_bytes(&bytes),
                        size: bytes.len() as u64,
                    },
                );
            }
        }
    }
    Ok(())
}

fn add_tracked_dependency_assets(
    workspace: &Workspace,
    state: &GraphState,
    snapshot: &mut Snapshot,
) -> io::Result<()> {
    let dependencies = state.actions.values().flat_map(|action| {
        std::iter::once(&action.input)
            .chain(action.reads.iter())
            .chain(action.resolver_reads.iter())
    });
    for asset in dependencies {
        if snapshot.contains_key(asset) {
            continue;
        }
        match workspace.read_asset_or_cache(asset) {
            Ok(bytes) => {
                snapshot.insert(
                    asset.clone(),
                    AssetSnapshot {
                        exists: true,
                        digest: digest_bytes(&bytes),
                        size: bytes.len() as u64,
                    },
                );
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                snapshot.insert(
                    asset.clone(),
                    AssetSnapshot {
                        exists: false,
                        digest: digest_bytes(b"<missing>"),
                        size: 0,
                    },
                );
            }
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn add_tracked_glob_assets(
    workspace: &Workspace,
    state: &GraphState,
    snapshot: &mut Snapshot,
) -> io::Result<()> {
    let globs = state
        .actions
        .values()
        .flat_map(|action| action.glob_reads.iter())
        .cloned()
        .collect::<BTreeSet<_>>();

    for glob in globs {
        let assets = match workspace.find_assets(&glob.package, &glob.pattern) {
            Ok(assets) => assets,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error),
        };
        let mut matched = Vec::with_capacity(assets.len());
        for asset in assets {
            let digest = if let Some(entry) = snapshot.get(&asset) {
                entry.digest.clone()
            } else {
                match workspace.read_asset_or_cache(&asset) {
                    Ok(bytes) => {
                        let digest = digest_bytes(&bytes);
                        snapshot.insert(
                            asset.clone(),
                            AssetSnapshot {
                                exists: true,
                                digest: digest.clone(),
                                size: bytes.len() as u64,
                            },
                        );
                        digest
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                }
            };
            matched.push(format!("{asset}\0{digest}"));
        }
        matched.sort();
        let serialized_size = matched.iter().map(String::len).sum::<usize>();
        snapshot.insert(
            glob_asset_key(&glob),
            AssetSnapshot {
                exists: true,
                digest: glob_digest(&matched),
                size: serialized_size as u64,
            },
        );
    }
    Ok(())
}
