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
/// graph nodes, while this PoC stores the node alongside ordinary asset
/// snapshots.
pub fn glob_asset_key(glob: &GlobRead) -> String {
    format!("__glob__|{}|{}", glob.package, glob.pattern)
}

pub fn glob_digest(matches: &[String]) -> String {
    digest_bytes(matches.join(" ").as_bytes())
}

pub fn scan_packages(
    workspace: &Workspace,
    packages: &BTreeSet<String>,
) -> io::Result<Snapshot> {
    let mut snapshot = Snapshot::new();
    for package in packages {
        for (asset, path) in workspace.list_package_assets(package)? {
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
    }
    Ok(snapshot)
}
