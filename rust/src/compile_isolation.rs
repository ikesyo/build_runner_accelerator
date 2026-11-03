//! Opt-in compiler-source isolation. Builder-visible packages remain original.
use crate::digest::digest_bytes;
use crate::runner_compatibility::{collect, file_uri, publish};
use crate::workspace::{canonicalize, resolve_uri};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub(crate) const ENV: &str = "BUILD_RUNNER_ACCELERATOR_EXPERIMENTAL_COMPILE_ISOLATION";
pub(crate) const CONFIG: &str =
    ".dart_tool/build_runner_accelerator/compile-isolation-package_config.json";
const PARSE_URI: &str = "package:analyzer/src/clients/build_resolvers/parse_utilities.dart";
const PUBLIC_URI: &str = "package:analyzer/dart/analysis/utilities.dart";
const COLLECTION: &str = "package:analyzer/dart/analysis/analysis_context_collection.dart";
type Sources = BTreeMap<PathBuf, Vec<u8>>;

pub(crate) fn enabled() -> bool {
    std::env::var(ENV).as_deref() == Ok("1")
}

fn error(message: impl std::fmt::Display) -> io::Error {
    io::Error::other(format!(
        "experimental compile isolation: {message}; unset {ENV} to disable"
    ))
}

/// Called after the legacy resolver backport, before publishing the effective
/// config. Select the experimental view separately so default and experimental
/// prewarm processes cannot overwrite each other's compiler configuration.
pub(crate) fn prepare(root: &Path, mut config: Value) -> io::Result<PathBuf> {
    let incoming = serde_json::to_vec(&config)?;
    let packages = config["packages"]
        .as_array_mut()
        .ok_or_else(|| error("missing packages"))?;
    let config_dir = root.join(".dart_tool");
    let mut roots = BTreeMap::new();
    for package in packages.iter() {
        let name = package["name"]
            .as_str()
            .ok_or_else(|| error("missing package name"))?;
        let uri = package["rootUri"]
            .as_str()
            .ok_or_else(|| error("missing package rootUri"))?;
        if roots
            .insert(
                name.to_owned(),
                canonicalize(resolve_uri(&config_dir, uri))?,
            )
            .is_some()
        {
            return Err(error(format!("duplicate package {name}")));
        }
    }
    let selections: &[(&str, &[&str])] = &[
        ("analyzer", &["14.5.0", "14.6.0"]),
        ("build_runner", &["2.16.1", "2.16.2"]),
        ("dart_style", &["3.1.13", "3.1.14"]),
        ("build_runner_accelerator", &[]),
    ];
    // Bind reuse to the complete incoming resolution and canonical package roots.
    // Bump this version if the transformation or receipt contract changes.
    let input = digest_bytes(&serde_json::to_vec(&(
        "compile-isolation-validation-v1",
        &incoming,
        &roots,
    ))?);
    if validation::reuse(root, &input) {
        return Ok(root.join(CONFIG));
    }
    let watched = selections
        .iter()
        .filter_map(|(name, _)| roots.get(*name))
        .cloned()
        .collect::<Vec<_>>();
    let before = validation::sources(&watched);
    let mut files = Sources::new();
    for (name, versions) in selections {
        let source = roots
            .get(*name)
            .ok_or_else(|| error(format!("missing {name}")))?;
        if source == root {
            return Err(error(
                "use a consumer workspace, not a compiler package's own root",
            ));
        }
        let spec = fs::read(source.join("pubspec.yaml"))?;
        let spec_text = std::str::from_utf8(&spec).map_err(error)?;
        let version = spec_text
            .lines()
            .find_map(|line| line.strip_prefix("version: "))
            .map(str::trim)
            .unwrap_or("");
        if !versions.is_empty() && !versions.contains(&version) {
            return Err(error(format!(
                "unsupported {name} {version}; expected {}",
                versions.join("/")
            )));
        }
        let mut package_files = Sources::new();
        collect(source, Path::new("lib"), &mut package_files)?;
        package_files.insert(PathBuf::from("pubspec.yaml"), spec);
        package_files.insert(PathBuf::from("LICENSE"), fs::read(source.join("LICENSE"))?);
        for (relative, contents) in package_files {
            files.insert(Path::new(name).join(relative), contents);
        }
    }
    patch(&mut files)?;
    let digests = files
        .iter()
        .map(|(path, bytes)| (path, digest_bytes(bytes)))
        .collect::<BTreeMap<_, _>>();
    let mut identity = b"experimental-compile-isolation-v1\0".to_vec();
    identity.extend_from_slice(&serde_json::to_vec(&digests)?);
    let identity = digest_bytes(&identity);
    let slot = root
        .join(".dart_tool/build_runner_accelerator/compile-isolation")
        .join(&identity);
    publish(&slot, &files).map_err(|e| error(format!("{}: {e}", slot.display())))?;
    for package in packages {
        let name = package["name"].as_str().unwrap();
        let path = if selections.iter().any(|(selected, _)| *selected == name) {
            slot.join(name)
        } else {
            roots[name].clone()
        };
        package["rootUri"] = Value::String(file_uri(&path));
    }
    config["buildRunnerAcceleratorCompileIsolation"] = Value::String(identity);
    let path = crate::runner_compatibility::publish_config_at(root, CONFIG, &config)?;
    validation::save(root, input, before, &slot, &files, &config);
    Ok(path)
}

// Metadata reuse is limited to Unix change-time semantics. Other platforms keep
// the byte-validation path. A receipt is disposable evidence, never authority
// to repair or ignore damaged compiler copies.
#[cfg(unix)]
mod validation {
    use super::*;
    use crate::file_stamp::stamp;
    use serde::{Deserialize, Serialize};

    const RECEIPT: &str = ".dart_tool/build_runner_accelerator/compile-isolation-validation.json";
    type Stamp = [u64; 8];

    #[derive(Deserialize, Serialize)]
    pub(super) struct Snapshot(Vec<(PathBuf, Stamp)>);

    #[derive(Deserialize, Serialize)]
    struct Receipt {
        input: String,
        sources: Snapshot,
        outputs: Snapshot,
    }

    impl Snapshot {
        fn current(&self) -> bool {
            self.0
                .iter()
                .all(|(p, expected)| stamp(p).is_ok_and(|s| s == *expected))
        }

        fn tree(&mut self, path: &Path) -> io::Result<()> {
            self.0.push((path.to_owned(), stamp(path)?));
            for entry in fs::read_dir(path)? {
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    self.tree(&entry.path())?;
                } else {
                    self.0.push((entry.path(), stamp(&entry.path())?));
                }
            }
            Ok(())
        }
    }

    pub(super) fn sources(roots: &[PathBuf]) -> Option<Snapshot> {
        let mut snapshot = Snapshot(Vec::new());
        for root in roots {
            snapshot.tree(&root.join("lib")).ok()?;
            for name in ["pubspec.yaml", "LICENSE"] {
                let path = root.join(name);
                snapshot.0.push((path.clone(), stamp(&path).ok()?));
            }
        }
        Some(snapshot)
    }

    pub(super) fn reuse(root: &Path, input: &str) -> bool {
        let Ok(bytes) = fs::read(root.join(RECEIPT)) else {
            return false;
        };
        let Ok(receipt) = serde_json::from_slice::<Receipt>(&bytes) else {
            return false;
        };
        receipt.input == input && receipt.sources.current() && receipt.outputs.current()
    }

    pub(super) fn save(
        root: &Path,
        input: String,
        sources: Option<Snapshot>,
        slot: &Path,
        files: &Sources,
        config: &Value,
    ) {
        let Some(sources) = sources else {
            return;
        };
        let save = || -> io::Result<()> {
            let mut outputs = Snapshot(Vec::new());
            outputs.tree(slot)?;
            let selector = root.join(CONFIG);
            outputs.0.push((selector.clone(), stamp(&selector)?));
            // Capture metadata before validating bytes, then check it again.
            // A racing source/copy edit must never mint a reusable receipt.
            for (path, bytes) in files {
                if fs::read(slot.join(path))? != *bytes {
                    return Ok(());
                }
            }
            if fs::read(selector)? != serde_json::to_vec(config)?
                || !sources.current()
                || !outputs.current()
            {
                return Ok(());
            }
            let receipt = Receipt {
                input: input.clone(),
                sources,
                outputs,
            };
            crate::runner_compatibility::publish_config_at(
                root,
                RECEIPT,
                &serde_json::to_value(receipt)?,
            )?;
            Ok(())
        };
        // Missing/unwritable receipt only disables this optimization. Compiler
        // sources and the selector have already passed normal validation.
        let _ = save();
    }
}

#[cfg(not(unix))]
mod validation {
    use super::*;
    pub(super) fn sources(_: &[PathBuf]) -> Option<()> {
        None
    }
    pub(super) fn reuse(_: &Path, _: &str) -> bool {
        false
    }
    pub(super) fn save(_: &Path, _: String, _: Option<()>, _: &Path, _: &Sources, _: &Value) {}
}

fn source(files: &Sources, path: &str) -> io::Result<String> {
    let bytes = files
        .get(Path::new(path))
        .ok_or_else(|| error(format!("missing {path}")))?;
    String::from_utf8(bytes.clone()).map_err(error)
}

fn replace_once(text: &str, before: &str, after: &str) -> io::Result<String> {
    if text.matches(before).count() != 1 {
        return Err(error(format!("unsupported source shape near {before:?}")));
    }
    Ok(text.replacen(before, after, 1))
}

fn patch(files: &mut Sources) -> io::Result<()> {
    let utilities = "analyzer/lib/dart/analysis/utilities.dart";
    let text = source(files, utilities)?;
    let parse_begin = "/// Return the result of parsing the file";
    let resolve_begin = "/// Return the result of resolving the file at the given [path].";
    if text.matches(parse_begin).count() != 1 || text.matches(resolve_begin).count() != 1 {
        return Err(error("unsupported Analyzer utility declarations"));
    }
    let first = text.find(parse_begin).unwrap();
    let split = text.find(resolve_begin).unwrap();
    if first >= split {
        return Err(error("unsupported Analyzer utility ordering"));
    }
    let mut light = text[..split].to_owned();
    for name in ["analysis_context.dart", "analysis_context_collection.dart"] {
        light = replace_once(
            &light,
            &format!("import 'package:analyzer/dart/analysis/{name}';\n"),
            "",
        )?;
    }
    files.insert(
        PathBuf::from("analyzer/lib/src/clients/build_resolvers/parse_utilities.dart"),
        light.into_bytes(),
    );
    files.insert(
        PathBuf::from(utilities),
        format!(
            "{}export '{PARSE_URI}' show parseFile, parseString;\n\n{}",
            &text[..first],
            &text[split..]
        )
        .into_bytes(),
    );
    let barrel = "analyzer/lib/src/clients/build_resolvers/build_resolvers.dart";
    let text = replace_once(
        &source(files, barrel)?,
        &format!("import '{COLLECTION}';\n"),
        "",
    )?;
    let text = replace_once(
        &text,
        "import 'dart:typed_data';",
        &format!("/// @docImport '{COLLECTION}';\nlibrary;\n\nimport 'dart:typed_data';"),
    )?;
    files.insert(PathBuf::from(barrel), text.into_bytes());
    for path in [
        "build_runner_accelerator/lib/src/trigger_evaluator.dart",
        "build_runner_accelerator/lib/src/worker_analysis_driver_model.dart",
        "build_runner_accelerator/lib/src/resolver_directives.dart",
        "dart_style/lib/src/dart_formatter.dart",
        "analyzer/lib/src/dart/sdk/sdk.dart",
        "build_runner/lib/src/build/library_cycle_graph/asset_deps_loader.dart",
        "build_runner/lib/src/build/build.dart",
    ] {
        let text = replace_once(
            &source(files, path)?,
            &format!("'{PUBLIC_URI}'"),
            &format!("'{PARSE_URI}'"),
        )?;
        files.insert(PathBuf::from(path), text.into_bytes());
    }
    let processes = "build_runner/lib/src/bootstrap/processes.dart";
    let text = replace_once(
        &source(files, processes)?,
        "import '../build_runner.dart';\n",
        "",
    )?;
    let first = "    _isRunning = true;";
    let last = "  /// Receives the message sent from the parent process.";
    if text.matches(first).count() != 1 || text.matches(last).count() != 1 {
        return Err(error("unsupported ChildProcess.run source"));
    }
    let first = text.find(first).unwrap();
    let last = text.find(last).unwrap();
    if first >= last || !text[..first].contains("static Future<Never> run(") {
        return Err(error("unsupported ChildProcess.run declaration"));
    }
    // Do not let a builder catch this unsupported request and then publish
    // success. EOF fails the native transaction; diagnostics stay off stdout.
    let text = format!(
        "{}    stderr.writeln('Experimental compile isolation does not support ChildProcess.run; unset {ENV}');\n    exit(64);\n  }}\n\n{}",
        &text[..first],
        &text[last..]
    );
    files.insert(PathBuf::from(processes), text.into_bytes());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::Workspace;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "compile isolation ü # {}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(root.join(".dart_tool")).unwrap();
            fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
            let mut entries =
                vec![serde_json::json!({"name":"app","rootUri":"../","packageUri":"lib/"})];
            for (name, version) in [
                ("analyzer", "14.6.0"),
                ("build_runner", "2.16.2"),
                ("dart_style", "3.1.14"),
                ("build_runner_accelerator", "0.17.1"),
            ] {
                let dir = root.join(name);
                fs::create_dir_all(dir.join("lib")).unwrap();
                fs::write(
                    dir.join("pubspec.yaml"),
                    format!("name: {name}\nversion: {version}\n"),
                )
                .unwrap();
                fs::write(dir.join("LICENSE"), "preserve upstream license").unwrap();
                entries.push(
                    serde_json::json!({"name":name,"rootUri":file_uri(&dir),"packageUri":"lib/"}),
                );
            }
            let mut files = Sources::new();
            files.insert(PathBuf::from("analyzer/lib/dart/analysis/utilities.dart"), format!("import 'package:analyzer/dart/analysis/analysis_context.dart';\nimport '{COLLECTION}';\n/// Return the result of parsing the file\nString parseFile() => 'original parse';\nString parseString() => 'original string';\n/// Return the result of resolving the file at the given [path].\nString resolveFile() => 'original resolve';\n").into_bytes());
            files.insert(
                PathBuf::from("analyzer/lib/src/clients/build_resolvers/build_resolvers.dart"),
                format!("import 'dart:typed_data';\nimport '{COLLECTION}';\n").into_bytes(),
            );
            for path in [
                "build_runner_accelerator/lib/src/trigger_evaluator.dart",
                "build_runner_accelerator/lib/src/worker_analysis_driver_model.dart",
                "build_runner_accelerator/lib/src/resolver_directives.dart",
                "dart_style/lib/src/dart_formatter.dart",
                "analyzer/lib/src/dart/sdk/sdk.dart",
                "build_runner/lib/src/build/library_cycle_graph/asset_deps_loader.dart",
                "build_runner/lib/src/build/build.dart",
            ] {
                files.insert(
                    PathBuf::from(path),
                    format!("import '{PUBLIC_URI}';\n").into_bytes(),
                );
            }
            files.insert(PathBuf::from("build_runner/lib/src/bootstrap/processes.dart"), b"import '../build_runner.dart';\nclass ChildProcess {\n  static Future<Never> run() async {\n    _isRunning = true;\n    await originalCli();\n  }\n\n  /// Receives the message sent from the parent process.\n  static receive() {}\n}\n".to_vec());
            for (path, bytes) in files {
                let path = root.join(path);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, bytes).unwrap();
            }
            fs::write(
                root.join(".dart_tool/package_config.json"),
                serde_json::to_vec(&serde_json::json!({"configVersion":2,"packages":entries}))
                    .unwrap(),
            )
            .unwrap();
            Self(canonicalize(root).unwrap())
        }

        fn config(&self) -> Value {
            serde_json::from_slice(
                &fs::read(self.0.join(".dart_tool/package_config.json")).unwrap(),
            )
            .unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn copied_root(config: &Value, name: &str) -> PathBuf {
        let entry = config["packages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["name"] == name)
            .unwrap();
        resolve_uri(Path::new("/"), entry["rootUri"].as_str().unwrap())
    }

    #[test]
    fn source_copies_are_immutable_content_keyed_and_fail_closed_on_damage() {
        let fixture = Fixture::new();
        let original = fixture.config();
        let original_process = fs::read(
            fixture
                .0
                .join("build_runner/lib/src/bootstrap/processes.dart"),
        )
        .unwrap();
        let path = prepare(&fixture.0, original.clone()).unwrap();
        let first: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let runner = copied_root(&first, "build_runner");
        assert!(
            fs::read_to_string(runner.join("lib/src/bootstrap/processes.dart"))
                .unwrap()
                .contains("exit(64)")
        );
        assert_eq!(
            fs::read(runner.join("LICENSE")).unwrap(),
            b"preserve upstream license"
        );
        let analyzer = copied_root(&first, "analyzer");
        assert!(
            fs::read_to_string(analyzer.join("lib/dart/analysis/utilities.dart"))
                .unwrap()
                .contains("original resolve")
        );
        assert!(
            fs::read_to_string(
                analyzer.join("lib/src/clients/build_resolvers/parse_utilities.dart")
            )
            .unwrap()
            .contains("original parse")
        );
        prepare(&fixture.0, original.clone()).unwrap();
        assert_eq!(
            first,
            serde_json::from_slice::<Value>(&fs::read(&path).unwrap()).unwrap()
        );
        assert_eq!(original, fixture.config());
        assert_eq!(
            original_process,
            fs::read(
                fixture
                    .0
                    .join("build_runner/lib/src/bootstrap/processes.dart")
            )
            .unwrap()
        );
        fs::write(
            analyzer.join("lib/src/clients/build_resolvers/parse_utilities.dart"),
            "damaged",
        )
        .unwrap();
        assert!(
            prepare(&fixture.0, original)
                .unwrap_err()
                .to_string()
                .contains("invalid runner-compat cache")
        );
    }

    #[test]
    fn unsupported_versions_and_shapes_do_not_publish_a_selector() {
        for change_version in [true, false] {
            let fixture = Fixture::new();
            if change_version {
                fs::write(fixture.0.join("analyzer/pubspec.yaml"), "version: 99.0.0\n").unwrap();
            } else {
                fs::write(
                    fixture.0.join("dart_style/lib/src/dart_formatter.dart"),
                    "changed import\n",
                )
                .unwrap();
            }
            assert!(prepare(&fixture.0, fixture.config()).is_err());
            assert!(!fixture.0.join(CONFIG).exists());
            assert!(
                !fixture
                    .0
                    .join(".dart_tool/build_runner_accelerator/runner-package_config.json")
                    .exists()
            );
        }
    }

    #[test]
    fn source_edits_select_another_generation() {
        let fixture = Fixture::new();
        let path = prepare(&fixture.0, fixture.config()).unwrap();
        let before = fs::read(&path).unwrap();
        let source = fixture.0.join("analyzer/lib/src/dart/sdk/sdk.dart");
        fs::write(
            &source,
            format!("// edited\n{}", fs::read_to_string(&source).unwrap()),
        )
        .unwrap();
        prepare(&fixture.0, fixture.config()).unwrap();
        assert_ne!(before, fs::read(path).unwrap());
    }

    #[cfg(unix)]
    fn receipt_input(root: &Path) -> String {
        let receipt: Value = serde_json::from_slice(
            &fs::read(
                root.join(".dart_tool/build_runner_accelerator/compile-isolation-validation.json"),
            )
            .unwrap(),
        )
        .unwrap();
        receipt["input"].as_str().unwrap().to_owned()
    }

    #[cfg(unix)]
    #[test]
    fn warm_receipt_detects_same_size_edits_even_with_restored_mtime() {
        for copied in [false, true] {
            let fixture = Fixture::new();
            fs::write(fixture.0.join("analyzer/lib/stamp.txt"), "before").unwrap();
            let selector = prepare(&fixture.0, fixture.config()).unwrap();
            let key = receipt_input(&fixture.0);
            assert!(validation::reuse(&fixture.0, &key));
            prepare(&fixture.0, fixture.config()).unwrap();
            assert!(validation::reuse(&fixture.0, &key));
            let config: Value = serde_json::from_slice(&fs::read(selector).unwrap()).unwrap();
            let path = if copied {
                copied_root(&config, "analyzer")
            } else {
                fixture.0.join("analyzer")
            }
            .join("lib/stamp.txt");
            let modified = fs::metadata(&path).unwrap().modified().unwrap();
            let bytes = fs::read_to_string(&path)
                .unwrap()
                .replace("before", "after!");
            let file = fs::OpenOptions::new()
                .write(true)
                .truncate(true)
                .open(&path)
                .unwrap();
            fs::write(&path, bytes).unwrap();
            file.set_times(fs::FileTimes::new().set_modified(modified))
                .unwrap();
            assert!(!validation::reuse(&fixture.0, &key));
            // Copy damage still fails closed; a source edit gets a new identity.
            assert_eq!(prepare(&fixture.0, fixture.config()).is_err(), copied);
        }
    }

    #[cfg(unix)]
    #[test]
    fn warm_receipt_detects_membership_and_selector_changes() {
        for change in ["add", "delete", "replace", "selector", "config"] {
            let fixture = Fixture::new();
            let selector = prepare(&fixture.0, fixture.config()).unwrap();
            let key = receipt_input(&fixture.0);
            let source = fixture.0.join("analyzer/lib/src/dart/sdk/sdk.dart");
            match change {
                "add" => fs::write(source.with_file_name("new.dart"), "new").unwrap(),
                "delete" => fs::remove_file(&source).unwrap(),
                "replace" => {
                    let bytes = fs::read(&source).unwrap();
                    fs::remove_file(&source).unwrap();
                    fs::write(&source, bytes).unwrap();
                }
                "selector" => fs::write(&selector, "{}").unwrap(),
                "config" => {} // Incoming resolution is part of the reuse key.
                _ => unreachable!(),
            }
            assert!(!validation::reuse(
                &fixture.0,
                if change == "config" { "changed" } else { &key }
            ));
            if change != "delete" {
                prepare(&fixture.0, fixture.config()).unwrap();
                assert!(validation::reuse(&fixture.0, &receipt_input(&fixture.0)));
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn missing_or_malformed_receipt_revalidates_without_changing_identity() {
        let fixture = Fixture::new();
        let selector = prepare(&fixture.0, fixture.config()).unwrap();
        let expected = fs::read(&selector).unwrap();
        let receipt = fixture
            .0
            .join(".dart_tool/build_runner_accelerator/compile-isolation-validation.json");
        for missing in [true, false] {
            if missing {
                fs::remove_file(&receipt).unwrap();
            } else {
                fs::write(&receipt, "incomplete").unwrap();
            }
            prepare(&fixture.0, fixture.config()).unwrap();
            assert_eq!(fs::read(&selector).unwrap(), expected);
            assert!(validation::reuse(&fixture.0, &receipt_input(&fixture.0)));
        }
    }

    #[test]
    fn environment_switch_keeps_original_assets_and_separates_identity() {
        const CHILD: &str = "COMPILE_ISOLATION_TEST_CHILD";
        if let Some(root) = std::env::var_os(CHILD) {
            let root = PathBuf::from(root);
            let on = Workspace::load(root.clone()).unwrap();
            let selected = crate::runner_compatibility::package_config(&root);
            let config: Value = serde_json::from_slice(&fs::read(&selected).unwrap()).unwrap();
            let copy = copied_root(&config, "analyzer").join("lib/dart/analysis/utilities.dart");
            let key = on.logical_dependency_key(&copy).unwrap();
            assert_eq!(key, "package:analyzer:lib/dart/analysis/utilities.dart");
            assert_eq!(on.resolve_logical_dependency(&key).unwrap(), copy);
            assert_eq!(
                on.path_for_asset("analyzer|lib/dart/analysis/utilities.dart")
                    .unwrap(),
                root.join("analyzer/lib/dart/analysis/utilities.dart")
            );
            // This test runs alone in its own process, so changing its environment
            // cannot race other tests or application threads.
            unsafe {
                std::env::remove_var(ENV);
            }
            let off = Workspace::load(root.clone()).unwrap();
            assert_ne!(on.package_config_identity(), off.package_config_identity());
            assert_ne!(
                on.builder_manifest_fingerprint().unwrap(),
                off.builder_manifest_fingerprint().unwrap()
            );
            assert_eq!(
                crate::runner_compatibility::package_config(&root),
                root.join(".dart_tool/package_config.json")
            );
            return;
        }
        let fixture = Fixture::new();
        assert!(Command::new(std::env::current_exe().unwrap()).args(["--exact", "compile_isolation::tests::environment_switch_keeps_original_assets_and_separates_identity", "--nocapture"]).env(CHILD, &fixture.0).env(ENV, "1").status().unwrap().success());
    }
}
