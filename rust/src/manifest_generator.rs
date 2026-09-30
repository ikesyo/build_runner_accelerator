//! Cache only the generator's compiled code. Workspace configuration and
//! builder selection are still evaluated by the official Dart APIs each run.
use crate::digest::digest_bytes;
use crate::worker_kernel::{
    aot_sdk_identity, dart_sdk_root_for_binary, parse_depfile_dependencies, shared_cache_root,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Deserialize, Serialize)]
struct Metadata {
    key: String,
    kernel: String,
    dependencies: BTreeMap<PathBuf, String>,
}

pub(crate) fn resolve(root: &Path, dart: &str, generator: &Path) -> PathBuf {
    if std::env::var("BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT").as_deref() == Ok("0") {
        return generator.to_path_buf();
    }
    let start = std::time::Instant::now();
    match prepare(root, dart, generator) {
        Ok((path, hit)) => {
            if std::env::var("BUILD_RUNNER_ACCELERATOR_METRICS").as_deref() == Ok("1") {
                eprintln!(
                    "Rust manifest snapshot: cache={} elapsed_us={}",
                    if hit { "hit" } else { "miss" },
                    start.elapsed().as_micros()
                );
            }
            path
        }
        Err(error) => {
            eprintln!("Rust manifest snapshot unavailable; using Dart source ({error})");
            generator.to_path_buf()
        }
    }
}

fn digest_file(path: &Path) -> io::Result<String> {
    Ok(digest_bytes(&fs::read(path)?))
}

fn cache_key(root: &Path, dart: &str, generator: &Path) -> io::Result<String> {
    let sdk = dart_sdk_root_for_binary(dart)?;
    cache_key_for_sdk(root, &sdk, generator)
}

fn cache_key_for_sdk(root: &Path, sdk: &Path, generator: &Path) -> io::Result<String> {
    let (version, experiments) = aot_sdk_identity(sdk)?;
    let platform = digest_file(&sdk.join("lib/_internal/vm_platform_strong.dill"))?;
    // Kernel files contain absolute source URIs. Deliberately do not restore
    // them across relocated package roots, unlike the worker AOT cache.
    let config = fs::canonicalize(root.join(".dart_tool/package_config.json"))?;
    Ok(format!(
        "manifest-kernel-v1-{}-{}-{}-{}-{}-{}-{}-{}-{}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        version,
        experiments,
        platform,
        config.display(),
        digest_file(&config)?,
        fs::canonicalize(generator)?.display(),
        digest_file(generator)?,
    ))
}

fn is_current(kernel: &Path, metadata: &Path, key: &str, generator: &Path) -> bool {
    let Ok(contents) = fs::read(metadata) else {
        return false;
    };
    let Ok(metadata) = serde_json::from_slice::<Metadata>(&contents) else {
        return false;
    };
    metadata.key == key
        && metadata.dependencies.contains_key(generator)
        && digest_file(kernel).is_ok_and(|digest| digest == metadata.kernel)
        && metadata
            .dependencies
            .iter()
            .all(|(path, expected)| digest_file(path).is_ok_and(|actual| actual == *expected))
}

fn prepare(root: &Path, dart: &str, generator: &Path) -> io::Result<(PathBuf, bool)> {
    let generator = fs::canonicalize(generator)?;
    let key = cache_key(root, dart, &generator)?;
    let directory = shared_cache_root(root)
        .ok_or_else(|| io::Error::other("no shared cache directory"))?
        .join("manifest-kernel")
        .join(digest_bytes(key.as_bytes()));
    fs::create_dir_all(&directory)?;
    let kernel = directory.join("generator.dill");
    let metadata = directory.join("metadata.json");
    if is_current(&kernel, &metadata, &key, &generator) {
        return Ok((kernel, true));
    }

    // Each invocation owns a staging directory. Competing processes may
    // publish the same slot; readers reject mismatched artifact/metadata
    // pairs, and an unavailable cache always falls back to source execution.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let staging = directory.join(format!(
        ".{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&staging)?;
    let result = (|| {
        let temporary_kernel = staging.join("generator.dill");
        let depfile = staging.join("generator.d");
        // The VM's kernel snapshot mode compiles without running main. It
        // avoids a second source compilation and leaves all runtime arguments
        // to the normal generator launch (including the early AOT overlap).
        let status = Command::new(dart)
            .arg(format!(
                "--packages={}",
                root.join(".dart_tool/package_config.json").display()
            ))
            .arg("--snapshot-kind=kernel")
            .arg(format!("--snapshot={}", temporary_kernel.display()))
            .arg(format!("--depfile={}", depfile.display()))
            .arg(&generator)
            .current_dir(root)
            .stdout(Stdio::null())
            .status()?;
        if !status.success() {
            return Err(io::Error::other(format!(
                "generator kernel compilation exited with {status}"
            )));
        }
        let dependencies = parse_depfile_dependencies(&fs::read_to_string(&depfile)?)
            .ok_or_else(|| io::Error::other("generator depfile has no dependencies"))?;
        let mut digests = BTreeMap::new();
        for dependency in dependencies {
            let path = if dependency.is_absolute() {
                dependency
            } else {
                root.join(dependency)
            };
            let path = fs::canonicalize(path)?;
            digests.insert(path.clone(), digest_file(&path)?);
        }
        if !digests.contains_key(&generator) {
            return Err(io::Error::other("generator missing from kernel depfile"));
        }
        // Package config is part of the key, even if omitted from the VM depfile.
        // If it changed during compilation, do not publish under the old key.
        if cache_key(root, dart, &generator)? != key {
            return Err(io::Error::other(
                "generator inputs changed during compilation",
            ));
        }
        let value = Metadata {
            key,
            kernel: digest_file(&temporary_kernel)?,
            dependencies: digests,
        };
        let temporary_metadata = staging.join("metadata.json");
        fs::write(
            &temporary_metadata,
            serde_json::to_vec(&value).map_err(io::Error::other)?,
        )?;
        replace(&temporary_kernel, &kernel)?;
        replace(&temporary_metadata, &metadata)?;
        Ok((kernel, false))
    })();
    let _ = fs::remove_dir_all(staging);
    result
}

fn replace(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    if destination.exists() {
        fs::remove_file(destination)?;
    }
    fs::rename(source, destination)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshot_key_tracks_sdk_config_and_generator_but_not_runtime_yaml() {
        let root =
            std::env::temp_dir().join(format!("manifest-snapshot-key-test-{}", std::process::id()));
        fs::create_dir_all(root.join(".dart_tool")).unwrap();
        let sdk = root.join("sdk");
        fs::create_dir_all(sdk.join("lib/_internal")).unwrap();
        let version = sdk.join("version");
        let experiments = sdk.join("lib/_internal/allowed_experiments.json");
        let platform = sdk.join("lib/_internal/vm_platform_strong.dill");
        let config = root.join(".dart_tool/package_config.json");
        let generator = root.join("generator.dart");
        for path in [&version, &experiments, &platform, &config, &generator] {
            fs::write(path, "before").unwrap();
        }
        let key = cache_key_for_sdk(&root, &sdk, &generator).unwrap();
        fs::write(root.join("build.yaml"), "runtime configuration").unwrap();
        assert_eq!(key, cache_key_for_sdk(&root, &sdk, &generator).unwrap());
        for path in [&version, &experiments, &platform, &config, &generator] {
            fs::write(path, "after!").unwrap();
            assert_ne!(key, cache_key_for_sdk(&root, &sdk, &generator).unwrap());
            fs::write(path, "before").unwrap();
        }
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn snapshot_checks_code_contents_and_artifact_integrity() {
        let root =
            std::env::temp_dir().join(format!("manifest-snapshot-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let generator = root.join("generator.dart");
        let dependency = root.join("dependency.dart");
        let kernel = root.join("generator.dill");
        let metadata = root.join("metadata.json");
        fs::write(&generator, "main").unwrap();
        fs::write(&dependency, "before").unwrap();
        fs::write(&kernel, "kernel").unwrap();
        let mut value = Metadata {
            key: "sdk-and-config".into(),
            kernel: digest_file(&kernel).unwrap(),
            dependencies: [generator.clone(), dependency.clone()]
                .into_iter()
                .map(|path| {
                    let digest = digest_file(&path).unwrap();
                    (path, digest)
                })
                .collect(),
        };
        fs::write(&metadata, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(is_current(&kernel, &metadata, &value.key, &generator));
        assert!(!is_current(
            &kernel,
            &metadata,
            "different-sdk-or-config",
            &generator
        ));
        fs::write(&dependency, "after!").unwrap();
        assert!(!is_current(&kernel, &metadata, &value.key, &generator));
        fs::write(&dependency, "before").unwrap();
        fs::write(&kernel, "corrupt").unwrap();
        assert!(!is_current(&kernel, &metadata, &value.key, &generator));
        fs::write(&kernel, "kernel").unwrap();
        value.dependencies.remove(&generator);
        fs::write(&metadata, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(!is_current(&kernel, &metadata, &value.key, &generator));
        fs::write(&metadata, "partial metadata").unwrap();
        assert!(!is_current(
            &kernel,
            &metadata,
            "sdk-and-config",
            &generator
        ));
        fs::remove_dir_all(root).unwrap();
    }
}
