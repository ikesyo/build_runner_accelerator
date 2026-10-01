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

pub(crate) fn resolve<F: FnOnce()>(
    root: &Path,
    dart: &str,
    generator: &Path,
    before_compile: F,
) -> PathBuf {
    let mut before_compile = Some(before_compile);
    if std::env::var("BUILD_RUNNER_ACCELERATOR_MANIFEST_SNAPSHOT").as_deref() == Ok("0") {
        if let Some(callback) = before_compile.take() {
            callback();
        }
        return generator.to_path_buf();
    }
    let start = std::time::Instant::now();
    match prepare(root, dart, generator, &mut before_compile) {
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
            if let Some(callback) = before_compile.take() {
                callback();
            }
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
    // Kernel files contain absolute source URIs. Two workspaces whose
    // package resolution agrees (identical config content resolving to the
    // same dependency directories) produce the same kernel, so the key uses
    // the resolved dependency locations rather than the config's own path:
    // the snapshot then hits across checkouts on one machine, which is what
    // the partial-cold path needs. `package_resolution` still separates
    // configs that merely share text but resolve differently.
    let config = fs::canonicalize(root.join(".dart_tool/package_config.json"))?;
    let resolution = package_resolution(&config, root);
    Ok(format!(
        "manifest-kernel-v2-{}-{}-{}-{}-{}-{}-{}-{}-{}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        version,
        experiments,
        platform,
        resolution.content_digest,
        resolution.locations_digest,
        fs::canonicalize(generator)?.display(),
        digest_file(generator)?,
    ))
}

struct PackageResolution {
    /// Digest of the config content with the workspace's own package removed:
    /// only that entry embeds the checkout path, and the generator never
    /// imports the workspace's own libraries.
    content_digest: String,
    /// Digest of where the dependencies actually resolve, separating configs
    /// that merely share text but point at different directories (e.g.
    /// relative `path:` deps on different checkouts).
    locations_digest: String,
}

fn package_resolution(config: &Path, root: &Path) -> PackageResolution {
    (|| -> Option<PackageResolution> {
        let mut parsed: serde_json::Value =
            serde_json::from_slice(&fs::read(config).ok()?).ok()?;
        let config_dir = config.parent()?;
        let canonical_root = fs::canonicalize(root).ok()?;
        let packages = parsed.get_mut("packages")?.as_array_mut()?;
        let locations_of = |entries: &[serde_json::Value]| {
            entries
                .iter()
                .filter_map(|entry| {
                    let root_uri = entry.get("rootUri")?.as_str()?;
                    let path = resolve_root_uri(config_dir, root_uri);
                    Some(fs::canonicalize(&path).unwrap_or(path))
                })
                .collect::<Vec<_>>()
        };
        let is_workspace_package = |entry: &serde_json::Value| -> bool {
            entry
                .get("rootUri")
                .and_then(|uri| uri.as_str())
                .map(|root_uri| resolve_root_uri(config_dir, root_uri))
                .is_some_and(|path| {
                    fs::canonicalize(&path).unwrap_or(path) == canonical_root
                })
        };
        let mut locations = locations_of(packages.as_slice());
        locations.retain(|path| *path != canonical_root);
        packages.retain(|entry| !is_workspace_package(entry));
        let mut location_names = locations
            .iter()
            .map(|path| path.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        location_names.sort();
        Some(PackageResolution {
            content_digest: digest_bytes(
                serde_json::to_vec(&parsed).ok()?.as_slice(),
            ),
            locations_digest: digest_bytes(location_names.join("\n").as_bytes()),
        })
    })()
    .unwrap_or_else(|| PackageResolution {
        // Config could not be parsed: fall back to the previous per-workspace
        // keying so a malformed or surprising file cannot share a slot.
        content_digest: digest_file(config)
            .unwrap_or_else(|_| config.display().to_string()),
        locations_digest: config.display().to_string(),
    })
}

fn resolve_root_uri(config_dir: &Path, root_uri: &str) -> PathBuf {
    if let Some(file_path) = root_uri.strip_prefix("file://") {
        return PathBuf::from(percent_decode(file_path));
    }
    config_dir.join(root_uri)
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(digit) = u8::from_str_radix(&value[index + 1..index + 3], 16) {
                out.push(digit);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
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

fn prepare<F: FnOnce()>(
    root: &Path,
    dart: &str,
    generator: &Path,
    before_compile: &mut Option<F>,
) -> io::Result<(PathBuf, bool)> {
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

    // Start worker compilation before paying the generator's cold compile.
    // Warm snapshot hits skip this extra selection pass entirely.
    if let Some(callback) = before_compile.take() {
        callback();
    }

    // Each invocation owns a staging directory. Competing processes may
    // publish the same slot; readers reject mismatched artifact/metadata
    // pairs, and an unavailable cache always falls back to source execution.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let staging = create_staging_directory(&directory, std::process::id(), &NEXT)?;
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

fn create_staging_directory(
    directory: &Path,
    process_id: u32,
    next: &AtomicU64,
) -> io::Result<PathBuf> {
    loop {
        let nonce = next.fetch_add(1, Ordering::Relaxed);
        let staging = directory.join(format!(".{process_id}-{nonce}"));
        match fs::create_dir(&staging) {
            Ok(()) => return Ok(staging),
            // A previous process with a reused PID may have left this
            // invocation's first staging directory behind. Skip it rather
            // than turning this cache miss into a source-only run.
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
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
    fn stale_staging_directory_does_not_block_snapshot_preparation() {
        let root = std::env::temp_dir().join(format!(
            "manifest-snapshot-staging-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let process_id = std::process::id();
        fs::create_dir(root.join(format!(".{process_id}-0"))).unwrap();
        let next = AtomicU64::new(0);

        let staging = create_staging_directory(&root, process_id, &next).unwrap();

        assert_eq!(
            staging.file_name().unwrap().to_string_lossy().to_string(),
            format!(".{process_id}-1")
        );
        assert!(staging.is_dir());
        fs::remove_dir_all(root).unwrap();
    }

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
    fn snapshot_key_shares_across_workspaces_with_identical_resolution() {
        let base =
            std::env::temp_dir().join(format!("manifest-snapshot-share-{}", std::process::id()));
        let sdk = base.join("sdk");
        fs::create_dir_all(sdk.join("lib/_internal")).unwrap();
        for path in [
            sdk.join("version"),
            sdk.join("lib/_internal/allowed_experiments.json"),
            sdk.join("lib/_internal/vm_platform_strong.dill"),
        ] {
            fs::write(path, "sdk").unwrap();
        }
        let deps = base.join("deps");
        fs::create_dir_all(&deps).unwrap();
        let generator = base.join("generator.dart");
        fs::write(&generator, "main").unwrap();
        let config_for = |dep_path: &Path| {
            format!(
                "{{\"packages\":[{{\"name\":\"app\",\"rootUri\":\"../\",\"packageUri\":\"lib/\"}},{{\"name\":\"dep\",\"rootUri\":\"file://{}\",\"packageUri\":\"lib/\"}}]}}",
                dep_path.display()
            )
        };
        let mut keys = Vec::new();
        for name in ["ws1", "ws2"] {
            let root = base.join(name);
            fs::create_dir_all(root.join(".dart_tool")).unwrap();
            fs::write(
                root.join(".dart_tool/package_config.json"),
                config_for(&deps),
            )
            .unwrap();
            keys.push(cache_key_for_sdk(&root, &sdk, &generator).unwrap());
        }
        // Identical config content resolving to the same dependency
        // directories shares one slot regardless of the workspace path.
        assert_eq!(keys[0], keys[1]);
        // Same config text but a differently-resolved dependency must not
        // share: the embedded file:// URIs would point at the wrong sources.
        let root3 = base.join("ws3");
        let other_deps = base.join("other-deps");
        fs::create_dir_all(&other_deps).unwrap();
        fs::create_dir_all(root3.join(".dart_tool")).unwrap();
        fs::write(
            root3.join(".dart_tool/package_config.json"),
            config_for(&other_deps),
        )
        .unwrap();
        assert_ne!(keys[0], cache_key_for_sdk(&root3, &sdk, &generator).unwrap());
        fs::remove_dir_all(base).unwrap();
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
