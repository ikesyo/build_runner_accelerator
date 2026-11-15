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

/// The per-build digest map staged for workers under `asset-digests-v1`
/// (ADR 0054): bare BLAKE3 hex for every existing snapshot asset that is
/// not a declared build output. Glob keys and placeholder primaries are not
/// readable assets and are excluded; declared outputs are excluded because
/// their current content is overlay state, not snapshot state.
pub fn asset_digests(
    snapshot: &Snapshot,
    declared_outputs: &BTreeSet<String>,
) -> BTreeMap<String, String> {
    snapshot
        .iter()
        .filter(|(asset, entry)| {
            entry.exists
                && !asset.starts_with("__glob__|")
                && !declared_outputs.contains(*asset)
                && !crate::placeholders::is_placeholder_asset(asset)
        })
        .map(|(asset, entry)| {
            (
                asset.clone(),
                entry
                    .digest
                    .strip_prefix("b3-")
                    .unwrap_or(&entry.digest)
                    .to_owned(),
            )
        })
        .collect()
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_digests_exclude_outputs_globs_placeholders_and_missing() {
        let entry = |digest: &str| AssetSnapshot {
            exists: true,
            digest: digest.to_owned(),
            size: 1,
        };
        let snapshot = Snapshot::from([
            ("pkg|lib/a.dart".to_owned(), entry("b3-aaaa")),
            ("pkg|lib/out.g.dart".to_owned(), entry("b3-bbbb")),
            (glob_asset_key(&crate::protocol::GlobRead {
                package: "pkg".to_owned(),
                pattern: "lib/**".to_owned(),
            }), entry("b3-cccc")),
            ("pkg|lib/$lib$".to_owned(), entry("b3-dddd")),
            (
                "pkg|lib/gone.dart".to_owned(),
                AssetSnapshot {
                    exists: false,
                    digest: "b3-eeee".to_owned(),
                    size: 0,
                },
            ),
        ]);
        let declared = BTreeSet::from(["pkg|lib/out.g.dart".to_owned()]);
        let digests = asset_digests(&snapshot, &declared);
        assert_eq!(
            digests,
            BTreeMap::from([("pkg|lib/a.dart".to_owned(), "aaaa".to_owned())])
        );
    }
}

pub fn scan_packages(workspace: &Workspace, packages: &BTreeSet<String>) -> io::Result<Snapshot> {
    let mut snapshot = Snapshot::new();
    let virtual_primary = std::cell::LazyCell::new(|| AssetSnapshot {
        exists: true,
        digest: digest_bytes(b"<virtual-primary>"),
        size: 0,
    });
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
            snapshot.insert(format!("{package}|{path}"), (*virtual_primary).clone());
        }
    }
    Ok(snapshot)
}
