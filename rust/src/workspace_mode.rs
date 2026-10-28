//! Conservative state separation until cross-root graph transitions are modeled.
use crate::workspace_discovery::WorkspaceDiscovery;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

const MARKER: &str = ".dart_tool/build_runner_accelerator/workspace-mode";

/// Prewarm is allowed alongside ordinary package builds. Its separate shared
/// coordination lock conflicts only with whole-workspace execution.
pub(crate) fn coordination_root(root: &Path) -> io::Result<PathBuf> {
    let root = crate::workspace::canonicalize(root)?;
    let reference = root.join(".dart_tool/pub/workspace_ref.json");
    let candidate = fs::read(reference)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|value| value["workspaceRoot"].as_str().map(str::to_owned))
        .and_then(|path| {
            crate::workspace::canonicalize(root.join(".dart_tool/pub").join(path)).ok()
        });
    Ok(candidate
        .filter(|candidate| root.starts_with(candidate))
        .unwrap_or(root))
}

fn marker_content(info: &WorkspaceDiscovery) -> io::Result<Vec<u8>> {
    let members = info
        .output_packages
        .iter()
        .map(|(name, path)| {
            Ok((
                name,
                path.strip_prefix(&info.root)
                    .map_err(|_| io::Error::other("workspace member is outside root"))?,
            ))
        })
        .collect::<io::Result<std::collections::BTreeMap<_, _>>>()?;
    serde_json::to_vec(&serde_json::json!({"version": 1, "members": members}))
        .map_err(io::Error::other)
}

fn exists(path: &Path) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Called with locks for every output package, before graph reuse or recovery.
pub(crate) fn prepare(info: &WorkspaceDiscovery) -> io::Result<()> {
    let marker = info.root.join(MARKER);
    let has_marker = exists(&marker)?;
    let expected = marker_content(info)?;
    if has_marker && fs::read(&marker)? != expected {
        return Err(io::Error::other(
            "workspace package topology changed or state marker is invalid; preserve state and follow docs/compatibility-cleanup.md#safe-recovery",
        ));
    }
    for root in info.output_packages.values() {
        let state = root.join(".dart_tool/build_runner_accelerator");
        if exists(&state.join(crate::worker_kernel::AOT_COMPILE_LOCK_NAME))? {
            return Err(io::Error::other(format!(
                "background worker compilation lock exists at {}; wait for it to finish or follow the recovery guide before building the workspace",
                root.display()
            )));
        }
        let graph = state.join("graph-v3.bin");
        let journal = state.join("graph-v3.commit-undo/journal.json");
        if (root != &info.root || !has_marker) && (exists(&graph)? || exists(&journal)?) {
            return Err(io::Error::other(format!(
                "cannot switch between individual and workspace native build state at {}; stop builders and follow docs/compatibility-cleanup.md#safe-recovery",
                root.display()
            )));
        }
    }
    if !has_marker {
        crate::assets::write_atomic(&marker, &expected)?;
    }
    Ok(())
}

/// Called under the individual package lock. A workspace build locks this same
/// package, so the marker cannot race with a concurrent publication.
pub(crate) fn reject_individual_after_workspace(root: &Path) -> io::Result<()> {
    let marker = root.join(MARKER);
    if exists(&marker)? {
        return Err(io::Error::other(
            "individual build after workspace state requires recovery; stop builders and follow docs/compatibility-cleanup.md#safe-recovery",
        ));
    }
    let reference = root.join(".dart_tool/pub/workspace_ref.json");
    let bytes = match fs::read(reference) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    let path = value["workspaceRoot"]
        .as_str()
        .ok_or_else(|| io::Error::other("invalid pub workspace reference"))?;
    let workspace = root.join(".dart_tool/pub").join(PathBuf::from(path));
    if exists(&workspace.join(MARKER))? {
        return Err(io::Error::other(
            "individual build after workspace state requires recovery; stop builders and follow docs/compatibility-cleanup.md#safe-recovery",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn workspace_state_rejects_switches_and_topology_changes() {
        let root =
            std::env::temp_dir().join(format!("accelerator-workspace-mode-{}", std::process::id()));
        let member = root.join("member");
        fs::create_dir_all(member.join(".dart_tool/pub")).unwrap();
        fs::create_dir_all(root.join(".dart_tool/build_runner_accelerator")).unwrap();
        fs::write(
            member.join(".dart_tool/pub/workspace_ref.json"),
            r#"{"workspaceRoot":"../../.."}"#,
        )
        .unwrap();
        assert_eq!(
            coordination_root(&member).unwrap(),
            fs::canonicalize(&root).unwrap()
        );
        let mut info = WorkspaceDiscovery {
            root: root.clone(),
            current_package: "member".into(),
            build_workspace: true,
            output_packages: BTreeMap::from([
                ("root".into(), root.clone()),
                ("member".into(), member.clone()),
            ]),
        };
        let graph = member.join(".dart_tool/build_runner_accelerator/graph-v3.bin");
        fs::create_dir_all(graph.parent().unwrap()).unwrap();
        fs::write(&graph, b"individual state").unwrap();
        assert!(prepare(&info).is_err());
        assert!(!root.join(MARKER).exists());
        fs::remove_file(graph).unwrap();
        let root_graph = root.join(".dart_tool/build_runner_accelerator/graph-v3.bin");
        fs::write(&root_graph, b"root individual state").unwrap();
        assert!(prepare(&info).is_err());
        assert!(!root.join(MARKER).exists());
        assert_eq!(fs::read(&root_graph).unwrap(), b"root individual state");
        fs::remove_file(root_graph).unwrap();
        let aot_lock = root
            .join(".dart_tool/build_runner_accelerator")
            .join(crate::worker_kernel::AOT_COMPILE_LOCK_NAME);
        fs::write(&aot_lock, b"background compilation").unwrap();
        assert!(prepare(&info).is_err());
        assert!(!root.join(MARKER).exists());
        fs::remove_file(aot_lock).unwrap();
        prepare(&info).unwrap();
        prepare(&info).unwrap();
        assert!(reject_individual_after_workspace(&root).is_err());
        assert!(reject_individual_after_workspace(&member).is_err());
        info.output_packages.remove("member");
        assert!(prepare(&info).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
