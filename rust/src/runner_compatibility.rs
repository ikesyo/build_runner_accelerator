//! Isolated backport of dart-lang/build#5197 for build_runner 2.15.3/2.16.0/2.16.1.
//! Never edits Pub's package cache or the application's package configuration.
use crate::digest::digest_bytes;
use crate::workspace::{canonicalize, resolve_uri};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

const CONFIG: &str = ".dart_tool/build_runner_accelerator/runner-package_config.json";
const RESOLVER: &str = "lib/src/build/resolver/resolvers_impl.dart";
const BEFORE: &str = "AnalysisOptionsImpl()\n          // ignore: deprecated_member_use\n          ..contextFeatures = _featureSet(\n            enableExperiments: enabledExperiments,\n          ),";
const AFTER: &str = "workerAnalysisOptions(_featureSet(\n            enableExperiments: enabledExperiments,\n          )),";

pub(crate) fn package_config(root: &Path) -> PathBuf {
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

/// Called before loading a workspace, including native-only and prewarm paths.
/// The effective resolution participates in all existing graph/compiler keys.
pub(crate) fn prepare(root: &Path) -> io::Result<PathBuf> {
    #[cfg(test)]
    PREPARE_CALLS.with(|calls| calls.set(calls.get() + 1));
    let original = root.join(".dart_tool/package_config.json");
    let mut config: Value = serde_json::from_slice(&fs::read(&original)?)?;
    let packages = config["packages"]
        .as_array_mut()
        .ok_or_else(|| io::Error::other("package configuration has no packages"))?;
    let runner = packages
        .iter()
        .find(|entry| entry["name"] == "build_runner");
    let runner_root = runner
        .and_then(|entry| entry["rootUri"].as_str())
        .map(|uri| resolve_uri(original.parent().unwrap(), uri));
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
        return Ok(original);
    }
    let runner_root = runner_root.unwrap();
    let mut files = BTreeMap::new();
    collect(&runner_root, Path::new("lib"), &mut files)?;
    for name in ["pubspec.yaml", "LICENSE"] {
        files.insert(PathBuf::from(name), fs::read(runner_root.join(name))?);
    }
    let resolver = files
        .get_mut(Path::new(RESOLVER))
        .ok_or_else(|| io::Error::other("legacy build_runner resolver is missing"))?;
    *resolver =
        patch_resolver(std::str::from_utf8(resolver).map_err(io::Error::other)?)?.into_bytes();
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
    let destination = root.join(CONFIG);
    let bytes = serde_json::to_vec(&config)?;
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

fn patch_resolver(source: &str) -> io::Result<String> {
    if source.matches(BEFORE).count() != 1 {
        return Err(io::Error::other(
            "build_runner 2.16 resolver differs from the supported #5197 backport",
        ));
    }
    // Share the worker factory: it handles Analyzer 13.3's ExperimentStatus
    // cast as well as the newer immutable analysis options.
    Ok(format!(
        "// Accelerator compatibility backport: dart-lang/build#5197.\n\
         // ignore: implementation_imports\n\
         import 'package:build_runner_accelerator/src/worker_analysis_options.dart' show workerAnalysisOptions;\n{}",
        source.replacen(BEFORE, AFTER, 1)
    ))
}

fn collect(root: &Path, relative: &Path, files: &mut BTreeMap<PathBuf, Vec<u8>>) -> io::Result<()> {
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

fn publish(slot: &Path, files: &BTreeMap<PathBuf, Vec<u8>>) -> io::Result<()> {
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
    // Fail before compilation on incomplete or altered disposable state.
    for (path, bytes) in files {
        if fs::read(slot.join(path))? != *bytes {
            return Err(io::Error::other(
                "invalid runner-compat cache; remove it and retry",
            ));
        }
    }
    Ok(())
}

fn temporary_path(path: &Path) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    path.with_extension(format!(
        "{}.{}.tmp",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

fn file_uri(path: &Path) -> String {
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
            fs::write(runner.join(RESOLVER), format!("// upstream\n{BEFORE}\n")).unwrap();
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
        use crate::worker_kernel::worker_aot_cache_key;
        use crate::workspace::Workspace;

        let first = Fixture::new();
        let second = Fixture::new();
        let sdk = first.0.join("sdk");
        fs::create_dir_all(sdk.join("bin")).unwrap();
        fs::create_dir_all(sdk.join("lib/_internal")).unwrap();
        fs::write(sdk.join("bin/dart"), "").unwrap();
        fs::write(sdk.join("version"), "test sdk").unwrap();
        fs::write(sdk.join("lib/_internal/allowed_experiments.json"), "{}").unwrap();
        let dart = sdk.join("bin/dart");
        let dart = dart.to_str().unwrap();
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
        let key = worker_aot_cache_key(&a, dart, "worker.dart").unwrap();
        assert_eq!(worker_aot_cache_key(&a, dart, "worker.dart").unwrap(), key);
        assert_ne!(worker_aot_cache_key(&b, dart, "worker.dart").unwrap(), key);
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
                .contains("differs from the supported")
        );
    }
}
