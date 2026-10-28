//! Read-only workspace discovery delegated to Pub/build_runner's Dart APIs.
use crate::workspace::{canonicalize, resolve_uri};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct WorkspaceDiscovery {
    pub(crate) root: PathBuf,
    pub(crate) current_package: String,
    pub(crate) build_workspace: bool,
    pub(crate) output_packages: BTreeMap<String, PathBuf>,
}

/// Discovery is read-only. Re-run it after acquiring every returned lock before
/// using its paths or state: Pub configuration can change during acquisition.
pub(crate) fn discover(current: &Path, dart: &str) -> io::Result<WorkspaceDiscovery> {
    let current = canonicalize(current)?;
    let config = current
        .ancestors()
        .map(|dir| dir.join(".dart_tool/package_config.json"))
        .find(|path| path.is_file())
        .ok_or_else(|| io::Error::other("package_config.json not found; run dart pub get"))?;
    let value: serde_json::Value = serde_json::from_slice(&fs::read(&config)?)?;
    let entry = value["packages"]
        .as_array()
        .and_then(|packages| {
            packages
                .iter()
                .find(|entry| entry["name"] == "build_runner_accelerator")
        })
        .and_then(|entry| entry["rootUri"].as_str())
        .ok_or_else(|| {
            io::Error::other("build_runner_accelerator is absent from package_config.json")
        })?;
    let tool = resolve_uri(config.parent().unwrap(), entry).join("tool/resolve_workspace.dart");
    if !tool.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "workspace discovery helper is unavailable",
        ));
    }
    let output = Command::new(dart)
        .arg(format!("--packages={}", config.display()))
        .arg(tool)
        .arg(&current)
        .current_dir(&current)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "workspace discovery failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    validate(serde_json::from_slice(&output.stdout)?, &current)
}

fn validate(mut result: WorkspaceDiscovery, current: &Path) -> io::Result<WorkspaceDiscovery> {
    result.root = canonicalize(&result.root)?;
    let mut seen = std::collections::BTreeSet::new();
    for path in result.output_packages.values_mut() {
        *path = canonicalize(&*path)?;
        if !path.starts_with(&result.root) {
            return Err(io::Error::other(
                "workspace output package is outside the workspace root",
            ));
        }
        if !seen.insert(path.clone()) {
            return Err(io::Error::other(
                "workspace output packages share a physical root",
            ));
        }
    }
    if result
        .output_packages
        .get(&result.current_package)
        .map(PathBuf::as_path)
        != Some(current)
        || !result
            .output_packages
            .values()
            .any(|path| path == &result.root)
        || (!result.build_workspace
            && (result.root != current || result.output_packages.len() != 1))
    {
        return Err(io::Error::other(
            "workspace discovery returned inconsistent package roots",
        ));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discovery_rejects_duplicate_or_external_output_roots() {
        let root = std::env::temp_dir().join(format!("workspace-discovery-{}", std::process::id()));
        let member = root.join("member");
        fs::create_dir_all(&member).unwrap();
        let root = canonicalize(root).unwrap();
        let member = canonicalize(member).unwrap();
        let info = |outputs| WorkspaceDiscovery {
            root: root.clone(),
            current_package: "member".into(),
            build_workspace: true,
            output_packages: outputs,
        };
        let valid = BTreeMap::from([
            ("root".into(), root.clone()),
            ("member".into(), member.clone()),
        ]);
        assert!(validate(info(valid.clone()), &member).is_ok());
        let mut duplicate = valid.clone();
        duplicate.insert("alias".into(), member.clone());
        assert!(validate(info(duplicate), &member).is_err());
        let mut external = valid;
        external.insert("outside".into(), root.parent().unwrap().to_path_buf());
        assert!(validate(info(external), &member).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
