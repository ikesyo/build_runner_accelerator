use crate::builder::RustBuildConfig;
use crate::digest::digest_bytes;
use crate::graph::GraphState;
use crate::plan::output_path;
use crate::snapshot::{AssetSnapshot, Snapshot, glob_asset_key, glob_digest};
use crate::workspace::Workspace;
use std::collections::BTreeSet;
use std::fs;
use std::io;

pub(crate) fn add_current_generated_assets(
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

pub(crate) fn add_tracked_dependency_assets(
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

pub(crate) fn add_tracked_glob_assets(
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
