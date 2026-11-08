//! Isolated backport of dart-lang/build#5197 for build_runner 2.15.3/2.16.0/2.16.1.
//! Never edits Pub's package cache or the application's package configuration.
use crate::digest::digest_bytes;
use crate::workspace::{PackageConfigFile, canonicalize, resolve_uri};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

const CONFIG: &str = ".dart_tool/build_runner_accelerator/runner-package_config.json";
#[cfg(test)]
const RESOLVER: &str = "lib/src/build/resolver/resolvers_impl.dart";
#[cfg(test)]
const BEFORE: &str = "AnalysisOptionsImpl()\n          // ignore: deprecated_member_use\n          ..contextFeatures = _featureSet(\n            enableExperiments: enabledExperiments,\n          ),";
#[cfg(test)]
const AFTER: &str = "workerAnalysisOptions(_featureSet(\n            enableExperiments: enabledExperiments,\n          )),";

pub(crate) fn package_config(root: &Path) -> PathBuf {
    let isolated = root.join(crate::compile_isolation::CONFIG);
    if crate::compile_isolation::enabled() && isolated.is_file() {
        return isolated;
    }
    let compatible = root.join(CONFIG);
    if compatible.is_file() {
        compatible
    } else {
        root.join(".dart_tool/package_config.json")
    }
}

/// Resolve the old output default without changing user arguments or compiler
/// settings. Workspace preparation still validates/backports the runner itself.
pub(crate) fn legacy_output_defaults(root: &Path) -> io::Result<bool> {
    let path = root.join(".dart_tool/package_config.json");
    let config: Value = serde_json::from_slice(&fs::read(&path)?)?;
    let runner = config["packages"].as_array().and_then(|packages| {
        packages
            .iter()
            .find(|entry| entry["name"] == "build_runner")
    });
    let Some(uri) = runner.and_then(|entry| entry["rootUri"].as_str()) else {
        return Ok(false);
    };
    let source = resolve_uri(path.parent().unwrap(), uri).join("pubspec.yaml");
    Ok(fs::read_to_string(source)
        .is_ok_and(|spec| spec.lines().any(|line| line.trim() == "version: 2.15.3")))
}

#[cfg(test)]
thread_local! {
    static PREPARE_CALLS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

/// Original and effective compiler views from one validated preparation.
pub(crate) struct PreparedConfig {
    pub(crate) path: PathBuf,
    pub(crate) original: PackageConfigFile,
    /// Absent when the compiler uses the original configuration unchanged.
    pub(crate) compiler: Option<PackageConfigFile>,
}

/// Called before loading a workspace, including native-only and prewarm paths.
/// The effective resolution participates in all existing graph/compiler keys.
pub(crate) fn prepare(root: &Path) -> io::Result<PreparedConfig> {
    #[cfg(test)]
    PREPARE_CALLS.with(|calls| calls.set(calls.get() + 1));
    prepare_with_read(root, |path| fs::read_to_string(path))
}

/// Reject a view computed from inputs replaced during preparation. Retry from
/// the new text, including when the obsolete inputs made preparation fail.
fn prepare_with_read(
    root: &Path,
    mut read: impl FnMut(&Path) -> io::Result<String>,
) -> io::Result<PreparedConfig> {
    let original_path = root.join(".dart_tool/package_config.json");
    for _ in 0..3 {
        let contents = read(&original_path)?;
        let prepared = (|| {
            let original: PackageConfigFile = serde_json::from_str(&contents)?;
            let path = prepare_compiler(root, &original_path, &original, &contents)?;
            // Isolation cache hits return the validated on-disk selection, not
            // the incoming DOM. Read that configuration after validation.
            let compiler = if path == original_path {
                None
            } else {
                Some(serde_json::from_str(&fs::read_to_string(&path)?)?)
            };
            Ok(PreparedConfig {
                path,
                original,
                compiler,
            })
        })();
        if read(&original_path)? == contents {
            return prepared;
        }
    }
    Err(io::Error::other(
        "package_config.json changed repeatedly during preparation; retry the command",
    ))
}

fn prepare_compiler(
    root: &Path,
    original: &Path,
    parsed: &PackageConfigFile,
    contents: &str,
) -> io::Result<PathBuf> {
    let runner_root = parsed.runner_root(original.parent().unwrap());
    let is_legacy = runner_root.as_ref().is_some_and(|path| {
        fs::read_to_string(path.join("pubspec.yaml")).is_ok_and(|spec| {
            spec.lines().any(|line| {
                matches!(
                    line.trim(),
                    "version: 2.15.3" | "version: 2.16.0" | "version: 2.16.1"
                )
            })
        })
    });
    if !is_legacy {
        match fs::remove_file(root.join(CONFIG)) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        if !crate::compile_isolation::enabled() {
            return Ok(original.to_path_buf());
        }
    }
    // Only rewriting paths needs a full DOM. Preserve the original metadata
    // and object order by parsing the original text rather than reserializing
    // the typed view with defaulted/omitted fields.
    let mut config: Value = serde_json::from_str(contents)?;
    if !is_legacy {
        return crate::compile_isolation::prepare(root, config);
    }
    let packages = config["packages"].as_array_mut().unwrap();
    let runner_root = runner_root.unwrap();
    let mut files = BTreeMap::new();
    collect(&runner_root, Path::new("lib"), &mut files)?;
    files.insert(
        PathBuf::from("pubspec.yaml"),
        fs::read(runner_root.join("pubspec.yaml"))?,
    );
    collect_license(&runner_root, &mut files)?;
    crate::dependency_patches::apply(&mut files, crate::dependency_patches::RESOLVER)?;
    let identity = digest_bytes(&serde_json::to_vec(
        &files
            .iter()
            .map(|(name, bytes)| (name, digest_bytes(bytes)))
            .collect::<BTreeMap<_, _>>(),
    )?);
    let slot = root
        .join(".dart_tool/build_runner_accelerator/runner-compat")
        .join(identity);
    publish(&slot, &files)?;
    for entry in packages {
        let uri = entry["rootUri"]
            .as_str()
            .ok_or_else(|| io::Error::other("package rootUri is missing"))?;
        let path = if entry["name"] == "build_runner" {
            slot.clone()
        } else {
            canonicalize(resolve_uri(original.parent().unwrap(), uri))?
        };
        entry["rootUri"] = Value::String(file_uri(&path));
    }
    let destination = publish_config(root, &config)?;
    if crate::compile_isolation::enabled() {
        return crate::compile_isolation::prepare(root, config);
    }
    Ok(destination)
}

pub(crate) fn publish_config(root: &Path, config: &Value) -> io::Result<PathBuf> {
    publish_config_at(root, CONFIG, config)
}

pub(crate) fn publish_config_at(
    root: &Path,
    relative: &str,
    config: &Value,
) -> io::Result<PathBuf> {
    let destination = root.join(relative);
    fs::create_dir_all(destination.parent().unwrap())?;
    let bytes = serde_json::to_vec(config)?;
    if fs::read(&destination).ok().as_deref() != Some(&bytes) {
        let temporary = temporary_path(&destination);
        fs::write(&temporary, &bytes)?;
        #[cfg(windows)]
        if destination.exists() && fs::read(&destination).ok().as_deref() != Some(&bytes) {
            fs::remove_file(&destination)?;
        }
        match fs::rename(&temporary, &destination) {
            Ok(()) => {}
            Err(_) if fs::read(&destination).ok().as_deref() == Some(&bytes) => {
                // Concurrent prewarm published the identical resolution. In
                // particular, never remove that config on Windows.
                let _ = fs::remove_file(&temporary);
            }
            Err(error) => {
                let _ = fs::remove_file(&temporary);
                return Err(error);
            }
        }
    }
    Ok(destination)
}

/// Preserve an existing package license without requiring one for path packages.
pub(crate) fn collect_license(
    root: &Path,
    files: &mut BTreeMap<PathBuf, Vec<u8>>,
) -> io::Result<()> {
    match fs::read(root.join("LICENSE")) {
        Ok(license) => {
            files.insert(PathBuf::from("LICENSE"), license);
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    Ok(())
}

pub(crate) fn collect(
    root: &Path,
    relative: &Path,
    files: &mut BTreeMap<PathBuf, Vec<u8>>,
) -> io::Result<()> {
    for entry in fs::read_dir(root.join(relative))? {
        let entry = entry?;
        let name = relative.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            collect(root, &name, files)?;
        } else if entry.file_type()?.is_file() {
            files.insert(name, fs::read(entry.path())?);
        } else {
            return Err(io::Error::other(
                "unsupported link in build_runner compatibility source",
            ));
        }
    }
    Ok(())
}

pub(crate) fn publish(slot: &Path, files: &BTreeMap<PathBuf, Vec<u8>>) -> io::Result<()> {
    if !slot.exists() {
        fs::create_dir_all(slot.parent().unwrap())?;
        let temporary = temporary_path(slot);
        fs::create_dir(&temporary)?;
        let result = (|| {
            for (path, bytes) in files {
                let target = temporary.join(path);
                fs::create_dir_all(target.parent().unwrap())?;
                fs::write(target, bytes)?;
            }
            match fs::rename(&temporary, slot) {
                Ok(()) => Ok(()),
                Err(_) if slot.is_dir() => Ok(()), // Another prewarm won publication.
                Err(error) => Err(error),
            }
        })();
        let _ = fs::remove_dir_all(&temporary);
        result?;
    }
    // Validate the file set and bytes in one pass, without retaining a second
    // copy of every source. Compile-isolation receipt reuse skips this cold path.
    fn validate(
        slot: &Path,
        relative: &Path,
        files: &BTreeMap<PathBuf, Vec<u8>>,
    ) -> io::Result<usize> {
        let mut count = 0;
        for entry in fs::read_dir(slot.join(relative))? {
            let entry = entry?;
            let path = relative.join(entry.file_name());
            let kind = entry.file_type()?;
            if kind.is_dir() {
                count += validate(slot, &path, files)?;
            } else if kind.is_file()
                && files.get(&path).is_some_and(|expected| {
                    fs::read(entry.path()).is_ok_and(|actual| actual == *expected)
                })
            {
                count += 1;
            } else {
                return Err(invalid_copy());
            }
        }
        Ok(count)
    }
    if validate(slot, Path::new(""), files)? != files.len() {
        return Err(invalid_copy());
    }
    Ok(())
}

fn invalid_copy() -> io::Error {
    io::Error::other("invalid runner-compat cache; remove it and retry")
}

fn temporary_path(path: &Path) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    path.with_extension(format!(
        "{}.{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

pub(crate) fn file_uri(path: &Path) -> String {
    let normalized = path.to_string_lossy().replace('\\', "/");
    let mut uri = if normalized.starts_with('/') {
        "file://"
    } else {
        "file:///"
    }
    .to_owned();
    for byte in normalized.bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~:".contains(&byte) {
            uri.push(byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    if !uri.ends_with('/') {
        uri.push('/');
    }
    uri
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prepare(root: &Path) -> io::Result<PathBuf> {
        super::prepare(root).map(|prepared| prepared.path)
    }

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = temporary_path(&std::env::temp_dir().join("runner compatibility ü #"));
            fs::create_dir_all(root.join(".dart_tool")).unwrap();
            fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
            let runner = root.join("upstream runner");
            fs::create_dir_all(runner.join("lib/src/build/resolver")).unwrap();
            fs::write(
                runner.join("pubspec.yaml"),
                "name: build_runner\nversion: 2.16.0\n",
            )
            .unwrap();
            fs::write(runner.join("LICENSE"), "upstream BSD license").unwrap();
            fs::write(
                runner.join(RESOLVER),
                &crate::dependency_patches::preimages(&[crate::dependency_patches::RESOLVER])
                    [Path::new(RESOLVER)],
            )
            .unwrap();
            fs::write(root.join(".dart_tool/package_config.json"), serde_json::to_vec(&serde_json::json!({
                "configVersion": 2,
                "packages": [
                    {"name": "app", "rootUri": "../", "packageUri": "lib/", "languageVersion": "3.11"},
                    {"name": "build_runner", "rootUri": "../upstream%20runner/", "packageUri": "lib/", "languageVersion": "3.11"}
                ]
            })).unwrap()).unwrap();
            Self(canonicalize(root).unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn replaced_config_retries_with_latest_roots_even_if_obsolete_preparation_failed() {
        for obsolete_fails in [false, true] {
            let fixture = Fixture::new();
            let latest = Fixture::new();
            fs::write(
                latest.0.join("upstream runner/pubspec.yaml"),
                "version: 2.16.2\n",
            )
            .unwrap();
            if obsolete_fails {
                fs::write(
                    fixture.0.join("upstream runner").join(RESOLVER),
                    "unsupported API",
                )
                .unwrap();
            }
            let original = fixture.0.join(".dart_tool/package_config.json");
            let mut config: Value = serde_json::from_slice(&fs::read(&original).unwrap()).unwrap();
            let latest_root = latest.0.join("upstream runner");
            config["packages"][1]["rootUri"] = Value::String(file_uri(&latest_root));
            let replacement = serde_json::to_vec(&config).unwrap();
            let mut reads = 0;
            let prepared = super::prepare_with_read(&fixture.0, |path| {
                reads += 1;
                if reads == 2 {
                    // Replace after the first compiler view was prepared, before
                    // accepting it. No thread timing or sleeps are involved.
                    let staging = path.with_extension("replacement");
                    fs::write(&staging, &replacement)?;
                    #[cfg(windows)]
                    fs::remove_file(path)?;
                    fs::rename(staging, path)?;
                }
                fs::read_to_string(path)
            })
            .unwrap();
            assert_eq!(prepared.path, original);
            assert!(prepared.compiler.is_none());
            assert_eq!(
                prepared.original.runner_root(original.parent().unwrap()),
                Some(latest_root),
            );
            assert!(!fixture.0.join(CONFIG).exists());
        }
    }

    #[test]
    fn continually_changing_config_fails_instead_of_returning_a_stale_view() {
        let fixture = Fixture::new();
        fs::write(
            fixture.0.join("upstream runner/pubspec.yaml"),
            "version: 2.16.2\n",
        )
        .unwrap();
        let mut reads = 0;
        let result = super::prepare_with_read(&fixture.0, |path| {
            reads += 1;
            if reads % 2 == 0 {
                let mut config: Value = serde_json::from_slice(&fs::read(path)?)?;
                config["generation"] = serde_json::json!(reads);
                fs::write(path, serde_json::to_vec(&config)?)?;
            }
            fs::read_to_string(path)
        });
        assert!(
            result
                .err()
                .expect("unstable configuration must not be accepted")
                .to_string()
                .contains("changed repeatedly during preparation")
        );
    }

    #[test]
    fn isolated_backport_rebases_config_and_preserves_sources() {
        let fixture = Fixture::new();
        let root = &fixture.0;
        let original = fs::read(root.join(".dart_tool/package_config.json")).unwrap();
        let resolver = fs::read(root.join("upstream runner").join(RESOLVER)).unwrap();
        let path = prepare(root).unwrap();
        assert_eq!(path, package_config(root));
        let config: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let clone = resolve_uri(
            path.parent().unwrap(),
            config["packages"][1]["rootUri"].as_str().unwrap(),
        );
        let workspace = crate::workspace::Workspace::load(root.clone()).unwrap();
        assert_eq!(
            canonicalize(workspace.package_root("build_runner").unwrap()).unwrap(),
            root.join("upstream runner")
        );
        let logical = workspace
            .logical_dependency_key(&clone.join(RESOLVER))
            .unwrap();
        assert!(logical.starts_with("package:build_runner:"));
        assert_eq!(
            workspace.resolve_logical_dependency(&logical).unwrap(),
            clone.join(RESOLVER)
        );
        let patched = fs::read_to_string(clone.join(RESOLVER)).unwrap();
        assert!(patched.contains(AFTER));
        assert!(patched.contains("show workerAnalysisOptions"));
        assert!(!patched.contains(BEFORE));
        assert_eq!(
            fs::read(clone.join("LICENSE")).unwrap(),
            b"upstream BSD license"
        );
        assert_eq!(
            resolve_uri(
                path.parent().unwrap(),
                config["packages"][0]["rootUri"].as_str().unwrap()
            ),
            *root
        );
        assert_eq!(
            fs::read(root.join(".dart_tool/package_config.json")).unwrap(),
            original
        );
        assert_eq!(
            fs::read(root.join("upstream runner").join(RESOLVER)).unwrap(),
            resolver
        );
        let modified = fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(prepare(root).unwrap(), path);
        assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), modified);
        // Source edits produce a new compile resolution and invalidate existing keys.
        fs::write(
            root.join("upstream runner/lib/new.dart"),
            "// new dependency",
        )
        .unwrap();
        prepare(root).unwrap();
        assert_ne!(
            fs::read(&path).unwrap(),
            serde_json::to_vec(&config).unwrap()
        );
        // A version transition must remove the old selection before compilation.
        assert!(!legacy_output_defaults(root).unwrap());
        fs::write(
            root.join("upstream runner/pubspec.yaml"),
            "version: 2.15.3\n",
        )
        .unwrap();
        assert!(legacy_output_defaults(root).unwrap());
        prepare(root).unwrap();
        fs::write(
            root.join("upstream runner/pubspec.yaml"),
            "version: 2.16.2\n",
        )
        .unwrap();
        assert_eq!(
            prepare(root).unwrap(),
            root.join(".dart_tool/package_config.json")
        );
        assert!(!root.join(CONFIG).exists());
    }

    #[test]
    fn aot_keys_reuse_only_the_supplied_prepared_workspace() {
        use crate::worker_kernel::aot_cache_key;
        use crate::workspace::Workspace;

        let first = Fixture::new();
        let second = Fixture::new();
        let sdk = first.0.join("sdk");
        fs::create_dir_all(sdk.join("lib/_internal")).unwrap();
        fs::write(sdk.join("version"), "test sdk").unwrap();
        fs::write(sdk.join("lib/_internal/allowed_experiments.json"), "{}").unwrap();
        for fixture in [&first, &second] {
            fs::write(fixture.0.join("worker.dart"), "void main() {}\n").unwrap();
        }
        // Different workspaces keep their own compiler roots and worker keys.
        fs::write(second.0.join("upstream runner/lib/other.dart"), "// other").unwrap();
        fs::write(
            second.0.join("worker.dart"),
            "void main() { /* other */ }\n",
        )
        .unwrap();
        let before = PREPARE_CALLS.get();
        let a = Workspace::load(first.0.clone()).unwrap();
        let b = Workspace::load(second.0.clone()).unwrap();
        let key = aot_cache_key(&a, &first.0.join("worker.dart"), &sdk).unwrap();
        assert_eq!(
            aot_cache_key(&a, &first.0.join("worker.dart"), &sdk).unwrap(),
            key
        );
        assert_ne!(
            aot_cache_key(&b, &second.0.join("worker.dart"), &sdk).unwrap(),
            key
        );
        fs::write(sdk.join("version"), "changed sdk").unwrap();
        assert_ne!(
            aot_cache_key(&a, &first.0.join("worker.dart"), &sdk).unwrap(),
            key
        );
        fs::write(sdk.join("version"), "test sdk").unwrap();
        fs::write(sdk.join("lib/_internal/allowed_experiments.json"), "[]").unwrap();
        assert_ne!(
            aot_cache_key(&a, &first.0.join("worker.dart"), &sdk).unwrap(),
            key
        );
        assert_eq!(PREPARE_CALLS.get(), before + 2);
        let dependency = format!("package:build_runner:{RESOLVER}");
        let original_copy = a.resolve_logical_dependency(&dependency).unwrap();
        assert!(original_copy.starts_with(&first.0));
        assert!(
            b.resolve_logical_dependency(&dependency)
                .unwrap()
                .starts_with(&second.0)
        );

        // A new preparation unit observes dependency edits and validates copies.
        fs::write(first.0.join("upstream runner/lib/new.dart"), "// changed").unwrap();
        let refreshed = Workspace::load(first.0.clone()).unwrap();
        assert_ne!(
            refreshed.resolve_logical_dependency(&dependency).unwrap(),
            original_copy
        );
        let config = package_config(&first.0);
        let parsed: Value = serde_json::from_slice(&fs::read(&config).unwrap()).unwrap();
        let copy = resolve_uri(
            config.parent().unwrap(),
            parsed["packages"][1]["rootUri"].as_str().unwrap(),
        );
        let resolver = fs::read(copy.join(RESOLVER)).unwrap();
        fs::write(copy.join(RESOLVER), "broken").unwrap();
        assert!(Workspace::load(first.0.clone()).is_err());
        fs::write(copy.join(RESOLVER), resolver).unwrap();
        assert!(Workspace::load(first.0.clone()).is_ok());

        // Changing package resolution removes the old compile selection.
        fs::write(
            first.0.join("upstream runner/pubspec.yaml"),
            "version: 2.16.2\n",
        )
        .unwrap();
        let current = Workspace::load(first.0.clone()).unwrap();
        assert!(!first.0.join(CONFIG).exists());
        assert_eq!(
            canonicalize(current.resolve_logical_dependency(&dependency).unwrap()).unwrap(),
            first.0.join("upstream runner").join(RESOLVER)
        );
        let original = first.0.join(".dart_tool/package_config.json");
        let mut resolution: Value = serde_json::from_slice(&fs::read(&original).unwrap()).unwrap();
        resolution["packages"][1]["rootUri"] =
            Value::String(file_uri(&second.0.join("upstream runner")));
        fs::write(&original, serde_json::to_vec(&resolution).unwrap()).unwrap();
        let changed = Workspace::load(first.0.clone()).unwrap();
        assert_eq!(
            canonicalize(changed.package_root("build_runner").unwrap()).unwrap(),
            second.0.join("upstream runner")
        );
        assert!(first.0.join(CONFIG).is_file());
    }

    #[test]
    fn concurrent_prewarm_publishes_complete_sources_and_config() {
        let fixture = Fixture::new();
        std::thread::scope(|scope| {
            let handles: Vec<_> = (0..4)
                .map(|_| {
                    let root = &fixture.0;
                    scope.spawn(move || prepare(root).unwrap())
                })
                .collect();
            for handle in handles {
                assert_eq!(handle.join().unwrap(), package_config(&fixture.0));
            }
        });
        prepare(&fixture.0).unwrap();
    }

    #[test]
    fn rejects_unknown_patch_shape_and_damaged_cache() {
        let fixture = Fixture::new();
        let root = &fixture.0;
        let path = prepare(root).unwrap();
        let config: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let clone = resolve_uri(
            path.parent().unwrap(),
            config["packages"][1]["rootUri"].as_str().unwrap(),
        );
        fs::write(clone.join(RESOLVER), "corrupt").unwrap();
        assert!(
            prepare(root)
                .unwrap_err()
                .to_string()
                .contains("invalid runner-compat")
        );
        fs::write(root.join("upstream runner").join(RESOLVER), "different API").unwrap();
        assert!(
            prepare(root)
                .unwrap_err()
                .to_string()
                .contains("source context differs")
        );
    }
    #[test]
    fn published_copy_rejects_extra_missing_and_changed_files() {
        let fixture = Fixture::new();
        let slot = fixture.0.join("copy");
        let path = PathBuf::from("lib/source.dart");
        let files = BTreeMap::from([(path.clone(), b"expected".to_vec())]);
        publish(&slot, &files).unwrap();
        let extra = slot.join("lib/injected.dart");
        fs::write(&extra, "unexpected").unwrap();
        assert!(publish(&slot, &files).is_err());
        fs::remove_file(extra).unwrap();
        publish(&slot, &files).unwrap();
        fs::write(slot.join(&path), "changed").unwrap();
        assert!(publish(&slot, &files).is_err());
        fs::remove_file(slot.join(path)).unwrap();
        assert!(publish(&slot, &files).is_err());
    }
    #[test]
    fn legacy_runner_license_is_optional_but_other_read_errors_propagate() {
        for version in ["2.15.3", "2.16.0", "2.16.1"] {
            let fixture = Fixture::new();
            let runner = fixture.0.join("upstream runner");
            fs::write(
                runner.join("pubspec.yaml"),
                format!("name: build_runner\nversion: {version}\n"),
            )
            .unwrap();
            fs::remove_file(runner.join("LICENSE")).unwrap();
            crate::workspace::Workspace::load(fixture.0.clone()).unwrap();
            let config: Value =
                serde_json::from_slice(&fs::read(fixture.0.join(CONFIG)).unwrap()).unwrap();
            let copied = resolve_uri(
                Path::new("/"),
                config["packages"][1]["rootUri"].as_str().unwrap(),
            );
            assert!(!copied.join("LICENSE").exists());
            fs::write(runner.join("LICENSE"), "restored license").unwrap();
            prepare(&fixture.0).unwrap();
            let config: Value =
                serde_json::from_slice(&fs::read(fixture.0.join(CONFIG)).unwrap()).unwrap();
            let copied = resolve_uri(
                Path::new("/"),
                config["packages"][1]["rootUri"].as_str().unwrap(),
            );
            assert_eq!(
                fs::read(copied.join("LICENSE")).unwrap(),
                b"restored license"
            );
            fs::remove_file(runner.join("LICENSE")).unwrap();
            fs::create_dir(runner.join("LICENSE")).unwrap();
            assert!(prepare(&fixture.0).is_err());
        }
    }
}
