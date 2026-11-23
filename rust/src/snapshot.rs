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

/// Optional clean-build snapshot of selected external libraries. Workers
/// use it for cache lookups, and only observed assets enter the graph.
pub(crate) fn scan_external_digest_sources(
    workspace: &Workspace,
    snapshot: &Snapshot,
    declared_outputs: &BTreeSet<String>,
) -> Snapshot {
    let mut external = Snapshot::new();
    let Ok(packages) = std::env::var("BUILD_RUNNER_ACCELERATOR_EXTERNAL_DIGEST_PACKAGES") else {
        return external;
    };
    let started = std::time::Instant::now();
    let (mut files, mut bytes) = (0, 0);
    for package in packages.split(',').map(str::trim).collect::<BTreeSet<_>>() {
        let Ok(root) = workspace
            .package_root(package)
            .and_then(crate::workspace::canonicalize)
        else {
            continue;
        };
        let pub_root = workspace.pub_resolution_root();
        if root.starts_with(pub_root) || pub_root.starts_with(&root) {
            continue;
        }
        // Discovery excludes symlinks and honors source restrictions. Resolve
        // through the same source path used by the worker's asset RPC.
        let Ok(assets) = workspace.list_package_assets(package) else {
            continue;
        };
        for (asset, discovered_path) in assets {
            if !asset
                .split_once('|')
                .is_some_and(|(_, path)| path.starts_with("lib/") && path.ends_with(".dart"))
                || snapshot.contains_key(&asset)
                || declared_outputs.contains(&asset)
            {
                continue;
            }
            let Ok(path) = workspace.source_path_for_asset(&asset) else {
                continue;
            };
            if path != discovered_path {
                continue;
            }
            let Ok(content) = std::fs::read(path) else {
                continue;
            };
            external.insert(
                asset,
                AssetSnapshot {
                    exists: true,
                    digest: digest_bytes(&content),
                    size: content.len() as u64,
                },
            );
            files += 1;
            bytes += content.len();
        }
    }
    if crate::metrics::runtime_metrics_enabled() {
        eprintln!(
            "Rust external asset digests: files={files} bytes={bytes} elapsed_us={}",
            started.elapsed().as_micros()
        );
    }
    external
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
            (
                glob_asset_key(&crate::protocol::GlobRead {
                    package: "pkg".to_owned(),
                    pattern: "lib/**".to_owned(),
                }),
                entry("b3-cccc"),
            ),
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
