use crate::digest::digest_bytes;
use crate::protocol::GlobRead;
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssetSnapshot {
    pub exists: bool,
    pub digest: String,
    pub size: u64,
}
pub type Snapshot = BTreeMap<String, AssetSnapshot>;

/// A stable internal snapshot key for a `findAssets` query.
///
/// This is intentionally not an `AssetId`: build_runner represents globs as
/// graph nodes, while the accelerator stores the node alongside ordinary asset
/// snapshots.
pub fn glob_asset_key(glob: &GlobRead) -> String {
    format!("__glob__|{}|{}", glob.package, glob.pattern)
}

pub fn glob_digest(matches: &[String]) -> String {
    digest_bytes(matches.join(" ").as_bytes())
}

pub fn scan_packages(workspace: &Workspace, packages: &BTreeSet<String>) -> io::Result<Snapshot> {
    let mut snapshot = Snapshot::new();
    for package in packages {
        for (asset, path) in workspace.list_package_assets(package)? {
            if crate::placeholders::is_placeholder_asset(&asset) {
                return Err(io::Error::other(format!(
                    "Unsupported native source at a virtual primary path: {asset}"
                )));
            }
            let bytes = std::fs::read(&path)?;
            snapshot.insert(
                asset,
                AssetSnapshot {
                    exists: true,
                    digest: digest_bytes(&bytes),
                    size: bytes.len() as u64,
                },
            );
        }
        // Stock adds these IDs to the plan independently of filesystem sources.
        // A constant snapshot is primary-input evidence, not readable content.
        for path in crate::placeholders::PATHS {
            snapshot.insert(
                format!("{package}|{path}"),
                AssetSnapshot {
                    exists: true,
                    digest: digest_bytes(b"<virtual-primary>"),
                    size: 0,
                },
            );
        }
    }
    Ok(snapshot)
}
