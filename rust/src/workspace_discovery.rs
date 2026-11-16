//! Workspace discovery in the frontend (ADR 0055).
//!
//! Replicates the semantics of the Dart path it replaces: stock's
//! `BuildPaths.load` decides the workspace root from
//! `.dart_tool/pub/workspace_ref.json` and the current pubspec, and the
//! output packages are the package-graph roots with paths taken from
//! `package_config.json`.
use crate::workspace::{canonicalize, package_name, resolve_uri};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct WorkspaceDiscovery {
    pub(crate) root: PathBuf,
    pub(crate) current_package: String,
    pub(crate) build_workspace: bool,
    pub(crate) output_packages: BTreeMap<String, PathBuf>,
}

/// Discovery is read-only. Re-run it after acquiring every returned lock before
/// using its paths or state: Pub configuration can change during acquisition.
pub(crate) fn discover(current: &Path) -> io::Result<WorkspaceDiscovery> {
    let current = canonicalize(current)?;
    let current_pubspec = current.join("pubspec.yaml");
    let current_package = package_name(&current_pubspec)?;
    // BuildPaths.load: the workspace root applies only when the reference
    // file exists and the current pubspec opts into the workspace (a member
    // via `resolution: workspace`, the root via a `workspace:` section). A
    // stale reference falls back to a single-package build at the current
    // package, keeping the same graph/configuration identity as stock.
    let mut workspace_root = None;
    let reference = current.join(".dart_tool/pub/workspace_ref.json");
    if reference.is_file() && pubspec_opts_into_workspace(&current_pubspec)? {
        let value: serde_json::Value = serde_json::from_slice(&fs::read(&reference)?)?;
        let relative = value
            .get("workspaceRoot")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| io::Error::other("workspace_ref.json has no workspaceRoot"))?;
        workspace_root = Some(canonicalize(reference.parent().unwrap().join(relative))?);
    }
    let build_workspace = workspace_root.is_some();
    let root = workspace_root.unwrap_or_else(|| current.clone());
    let root_package = package_name(&root.join("pubspec.yaml"))?;
    let config_path = root
        .ancestors()
        .map(|dir| dir.join(".dart_tool/package_config.json"))
        .find(|path| path.is_file())
        .ok_or_else(|| io::Error::other("package_config.json not found; run dart pub get"))?;
    let config: serde_json::Value = serde_json::from_slice(&fs::read(&config_path)?)?;
    let config_dir = config_path.parent().unwrap();
    let mut package_paths = BTreeMap::new();
    if let Some(packages) = config["packages"].as_array() {
        for entry in packages {
            if let (Some(name), Some(uri)) = (entry["name"].as_str(), entry["rootUri"].as_str()) {
                package_paths.insert(name.to_owned(), resolve_uri(config_dir, uri));
            }
        }
    }
    let mut output_names = BTreeSet::from([root_package.clone()]);
    if build_workspace {
        let graph_path = root.join(".dart_tool/package_graph.json");
        let graph: serde_json::Value = serde_json::from_slice(&fs::read(&graph_path)?)?;
        let roots = graph["roots"]
            .as_array()
            .filter(|roots| roots.iter().all(|name| name.is_string()))
            .ok_or_else(|| {
                io::Error::other(format!(
                    "invalid workspace package graph: {}",
                    graph_path.display()
                ))
            })?;
        if !roots
            .iter()
            .any(|name| name.as_str() == Some(&root_package))
        {
            return Err(io::Error::other(format!(
                "workspace package graph does not contain {root_package}"
            )));
        }
        output_names.extend(roots.iter().map(|name| name.as_str().unwrap().to_owned()));
    }
    let mut output_packages = BTreeMap::new();
    for name in &output_names {
        let path = package_paths.get(name).ok_or_else(|| {
            io::Error::other(format!(
                "package {name} is absent from package_config.json; run dart pub get"
            ))
        })?;
        output_packages.insert(name.clone(), path.clone());
    }
    if build_workspace
        && output_packages
            .get(&current_package)
            .map(canonicalize)
            .transpose()?
            .as_deref()
            != Some(&current)
    {
        return Err(io::Error::other(format!(
            "workspace package graph does not contain the current package \
             {current_package} at {}; run dart pub get first",
            current.display()
        )));
    }
    validate(
        WorkspaceDiscovery {
            root,
            current_package,
            build_workspace,
            output_packages,
        },
        &current,
    )
}

/// Whether a pubspec opts into its workspace, as the YAML-level check in
/// stock's `BuildPaths.load`: `resolution: workspace`, or a `workspace:`
/// section with a non-null value. The pubspec is parsed as YAML (see
/// `workspace::pubspec_yaml`), so every shape pub accepts is honored.
fn pubspec_opts_into_workspace(path: &Path) -> io::Result<bool> {
    let root = crate::workspace::pubspec_yaml(path)?;
    let Some(map) = root.as_hash() else {
        return Ok(false);
    };
    if map
        .get(&yaml_rust2::Yaml::String("resolution".to_owned()))
        .and_then(yaml_rust2::Yaml::as_str)
        == Some("workspace")
    {
        return Ok(true);
    }
    Ok(!matches!(
        map.get(&yaml_rust2::Yaml::String("workspace".to_owned())),
        None | Some(yaml_rust2::Yaml::Null | yaml_rust2::Yaml::BadValue)
    ))
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

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        /// A pub workspace: root package `ws_root` with members `a` (ws_a)
        /// and `b` (ws_b), plus a hosted dependency that is not a member.
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir()
                .join(format!("workspace-discovery-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            for member in ["a", "b"] {
                let dir = root.join(member);
                fs::create_dir_all(dir.join(".dart_tool/pub")).unwrap();
                fs::write(
                    dir.join("pubspec.yaml"),
                    format!("name: ws_{member}\nresolution: workspace\n"),
                )
                .unwrap();
                fs::write(
                    dir.join(".dart_tool/pub/workspace_ref.json"),
                    "{\"workspaceRoot\": \"../../..\"}",
                )
                .unwrap();
            }
            fs::create_dir_all(root.join(".dart_tool/pub")).unwrap();
            fs::write(
                root.join("pubspec.yaml"),
                "name: ws_root\nworkspace:\n  - a\n  - b\n",
            )
            .unwrap();
            fs::write(
                root.join(".dart_tool/pub/workspace_ref.json"),
                "{\"workspaceRoot\": \"../..\"}",
            )
            .unwrap();
            fs::write(
                root.join(".dart_tool/package_graph.json"),
                "{\"roots\": [\"ws_root\", \"ws_a\", \"ws_b\"]}",
            )
            .unwrap();
            fs::write(
                root.join(".dart_tool/package_config.json"),
                "{\"configVersion\": 2, \"packages\": [
                    {\"name\": \"ws_root\", \"rootUri\": \"../\"},
                    {\"name\": \"ws_a\", \"rootUri\": \"../a/\"},
                    {\"name\": \"ws_b\", \"rootUri\": \"../b/\"},
                    {\"name\": \"dep\", \"rootUri\": \"file:///nonexistent/dep\"}
                ]}",
            )
            .unwrap();
            Self { root }
        }

        fn canonical_root(&self) -> PathBuf {
            canonicalize(&self.root).unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn discovery_from_member_resolves_workspace() {
        let fixture = Fixture::new("member");
        let root = fixture.canonical_root();
        let info = discover(&fixture.root.join("a")).unwrap();
        assert!(info.build_workspace);
        assert_eq!(info.root, root);
        assert_eq!(info.current_package, "ws_a");
        assert_eq!(
            info.output_packages.keys().collect::<Vec<_>>(),
            vec!["ws_a", "ws_b", "ws_root"]
        );
        assert_eq!(info.output_packages["ws_b"], root.join("b"));
    }

    #[test]
    fn discovery_from_root_resolves_workspace() {
        let fixture = Fixture::new("root");
        let root = fixture.canonical_root();
        let info = discover(&fixture.root).unwrap();
        assert!(info.build_workspace);
        assert_eq!(info.root, root);
        assert_eq!(info.current_package, "ws_root");
        assert_eq!(info.output_packages.len(), 3);
    }

    #[test]
    fn discovery_without_workspace_reference_is_single_package() {
        let dir =
            std::env::temp_dir().join(format!("workspace-discovery-solo-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(".dart_tool")).unwrap();
        fs::write(dir.join("pubspec.yaml"), "name: solo\n").unwrap();
        fs::write(
            dir.join(".dart_tool/package_config.json"),
            "{\"configVersion\": 2, \"packages\": [{\"name\": \"solo\", \"rootUri\": \"../\"}]}",
        )
        .unwrap();
        let info = discover(&dir).unwrap();
        assert!(!info.build_workspace);
        assert_eq!(info.root, canonicalize(&dir).unwrap());
        assert_eq!(info.output_packages.len(), 1);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn pubspec_workspace_opt_in_matches_yaml_shapes() {
        let cases: &[(&str, bool)] = &[
            ("name: x\nresolution: workspace\n", true),
            ("name: x\nworkspace:\n  - a\n", true),
            ("name: x\nworkspace:\n- a\n- b\n", true),
            ("name: x\nworkspace: [a, b]\n", true),
            ("name: x\nworkspace:\n", false),
            ("name: x\nworkspace:\ndependencies:\n  y: 1\n", false),
            ("name: x\nworkspace: null\n", false),
            ("name: x\nworkspace: ~\n", false),
            ("name: x\nworkspace: # members\n", false),
            ("name: x\nworkspace: # members\n  - a\n", true),
            ("name: x\nresolution: null\n", false),
            ("name: x\nresolution:\n  workspace\n", true),
            ("name: x\nresolution: >-\n  workspace\n", true),
            // Block scalars keep the trailing newline unless chomped, so
            // unchomped forms are not the exact string `workspace`.
            ("name: x\nresolution: |\n  workspace\n", false),
            ("name: x\nresolution: |-\n  workspace\n", true),
            ("name: x\nresolution: >\n  workspace\n", false),
            ("name: x\nresolution: workspace # comment\n", true),
            ("name: x\nresolution: 'workspace'\n", true),
            ("name: x\nresolution: workspacefoo\n", false),
            ("name: x\nresolution:\n  other\n", false),
            ("name: x\nresolution: &mode workspace\n", true),
            ("name: x\nresolution:\n  # comment\n  workspace\n", true),
            ("  name: x\n  resolution: workspace\n", true),
            ("{\"resolution\": \"workspace\"}\n", true),
            (
                "name: x\ndescription: &mode workspace\nresolution: *mode\n",
                true,
            ),
            ("name: x\nworkspace: false\n", true),
            ("name: x\n", false),
        ];
        for (index, (text, expected)) in cases.iter().enumerate() {
            let dir = std::env::temp_dir().join(format!(
                "build_runner_accelerator_opt_in_{}_{index}",
                std::process::id()
            ));
            fs::create_dir_all(&dir).unwrap();
            let path = dir.join("pubspec.yaml");
            fs::write(&path, text).unwrap();
            let actual = pubspec_opts_into_workspace(&path).unwrap();
            let _ = fs::remove_dir_all(&dir);
            assert_eq!(actual, *expected, "case {index}: {text:?}");
        }
    }

    #[test]
    fn package_name_strips_comment_and_quotes() {
        let cases: &[(&str, &str)] = &[
            ("name: ws_a\n", "ws_a"),
            ("name: ws_a # package name\n", "ws_a"),
            ("name: \"ws_a\"\n", "ws_a"),
            ("name: 'ws_a' # comment\n", "ws_a"),
            ("dependencies:\n  name: other\nname: ws_a\n", "ws_a"),
        ];
        for (index, (text, expected)) in cases.iter().enumerate() {
            let dir = std::env::temp_dir().join(format!(
                "build_runner_accelerator_pkg_name_{}_{index}",
                std::process::id()
            ));
            fs::create_dir_all(&dir).unwrap();
            let path = dir.join("pubspec.yaml");
            fs::write(&path, text).unwrap();
            let actual = package_name(&path).unwrap();
            let _ = fs::remove_dir_all(&dir);
            assert_eq!(actual, *expected, "case {index}: {text:?}");
        }
    }

    #[test]
    fn package_name_rejects_unparsable_pubspec() {
        // The line scan would still find `name:` in these files; a pubspec
        // YAML rejects must fail instead, matching the stock Dart path.
        let cases: &[&str] = &["name: ws_a\nbad: [1, 2\n", "name: ws_a\n\tfoo: bar\n"];
        for (index, text) in cases.iter().enumerate() {
            let dir = std::env::temp_dir().join(format!(
                "build_runner_accelerator_pkg_name_bad_{}_{index}",
                std::process::id()
            ));
            fs::create_dir_all(&dir).unwrap();
            let path = dir.join("pubspec.yaml");
            fs::write(&path, text).unwrap();
            assert!(package_name(&path).is_err(), "case {index}: {text:?}");
            let _ = fs::remove_dir_all(&dir);
        }
        // A pubspec that parses but whose name is not a plain string still
        // falls back to the line scan.
        let dir = std::env::temp_dir().join(format!(
            "build_runner_accelerator_pkg_name_nonstring_{}",
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("pubspec.yaml");
        fs::write(&path, "name: 42\n").unwrap();
        assert_eq!(package_name(&path).unwrap(), "42");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn discovery_with_stale_reference_falls_back_to_single_package() {
        let fixture = Fixture::new("stale");
        // The reference file remains, but the member no longer opts in.
        fs::write(fixture.root.join("a/pubspec.yaml"), "name: ws_a\n").unwrap();
        fs::create_dir_all(fixture.root.join("a/.dart_tool")).unwrap();
        fs::write(
            fixture.root.join("a/.dart_tool/package_config.json"),
            "{\"configVersion\": 2, \"packages\": [{\"name\": \"ws_a\", \"rootUri\": \"../../a/\"}]}",
        )
        .unwrap();
        let info = discover(&fixture.root.join("a")).unwrap();
        assert!(!info.build_workspace);
        assert_eq!(info.current_package, "ws_a");
        assert_eq!(info.output_packages.len(), 1);
    }

    #[test]
    fn discovery_rejects_graph_without_root_or_current_member() {
        let fixture = Fixture::new("graph");
        fs::write(
            fixture.root.join(".dart_tool/package_graph.json"),
            "{\"roots\": [\"ws_a\", \"ws_b\"]}",
        )
        .unwrap();
        assert!(discover(&fixture.root.join("a")).is_err());
        fs::write(
            fixture.root.join(".dart_tool/package_graph.json"),
            "{\"roots\": [\"ws_root\", \"ws_b\"]}",
        )
        .unwrap();
        assert!(discover(&fixture.root.join("a")).is_err());
    }
}
