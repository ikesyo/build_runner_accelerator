use super::{
    ANALYSIS_PREWARM_ACTIVE, WorkerArtifact, acquire_background_aot_lock, analysis_prewarm_enabled,
    background_aot_lock_is_stale, catch_worker_aot_panic, link_sdk_bin, parse_depfile_dependencies,
    pinned_worker_artifact_is_current, spawn_analysis_prewarm,
};
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Barrier};
use std::thread;

#[test]
fn compiler_snapshot_keeps_prepared_roots_and_is_not_a_persistent_dependency() {
    let root = std::env::temp_dir().join(format!("aot-config-snapshot-{}", std::process::id()));
    fs::create_dir_all(root.join(".dart_tool/build_runner_accelerator")).unwrap();
    fs::create_dir_all(root.join("first")).unwrap();
    fs::create_dir_all(root.join("second")).unwrap();
    fs::create_dir_all(root.join("sdk/lib/_internal")).unwrap();
    fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
    let original_path = root.join(".dart_tool/package_config.json");
    let original = r#"{"configVersion":2,"packages":[{"name":"dep","rootUri":"../first/"}]}"#;
    fs::write(&original_path, original).unwrap();
    let workspace = crate::workspace::Workspace::load(root.clone()).unwrap();
    // Simulate abrupt termination: Drop cannot clean up the file. A later
    // workspace must not discover it, even with all JSON files included.
    let orphan = super::CompilerConfigSnapshot::create(&workspace).unwrap();
    let orphan_path = orphan.path.clone();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&orphan_path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    std::mem::forget(orphan);
    let reloaded = crate::workspace::Workspace::load(root.clone()).unwrap();
    assert!(
        reloaded
            .list_package_assets("app")
            .unwrap()
            .iter()
            .all(|(_, path)| path != &orphan_path)
    );
    let sources = Arc::new(
        serde_json::from_value(serde_json::json!({
            "app": {"targets": [{"include": ["**"], "exclude": []}],
                    "public_assets": null}
        }))
        .unwrap(),
    );
    reloaded.configure_sources(Some(&sources));
    assert_eq!(
        reloaded.find_assets("app", "**/*.json").unwrap(),
        vec!["app|.dart_tool/package_config.json"]
    );
    let scanned = crate::snapshot::scan_packages(
        &reloaded,
        &std::collections::BTreeSet::from(["app".to_owned()]),
    )
    .unwrap();
    assert!(scanned.contains_key("app|.dart_tool/package_config.json"));
    assert!(
        scanned
            .keys()
            .all(|asset| !asset.contains("._worker-aot-packages-"))
    );
    assert!(orphan_path.exists());
    // A later preparation chooses a different compiler file, leaving the
    // original unchanged. Reading only the original cannot detect this.
    let selector = root.join(".dart_tool/build_runner_accelerator/runner-package_config.json");
    fs::write(
        &selector,
        r#"{"packages":[{"name":"dep","rootUri":"../../second/"}]}"#,
    )
    .unwrap();
    assert_ne!(
        crate::runner_compatibility::package_config(&root).unwrap(),
        original_path
    );
    let snapshot = super::CompilerConfigSnapshot::create(&workspace).unwrap();
    let snapshot_path = snapshot.path.clone();
    assert_eq!(fs::read_to_string(&snapshot.path).unwrap(), original);
    let parsed: serde_json::Value = serde_json::from_str(original).unwrap();
    let resolved = crate::workspace::resolve_uri(
        snapshot.path.parent().unwrap(),
        parsed["packages"][0]["rootUri"].as_str().unwrap(),
    );
    assert_eq!(
        super::canonicalize(resolved).unwrap(),
        super::canonicalize(root.join("first")).unwrap()
    );
    // Rewrites, including change-and-restore, never touch this snapshot.
    fs::write(&selector, original).unwrap();
    assert_eq!(fs::read_to_string(&snapshot.path).unwrap(), original);
    let second = super::CompilerConfigSnapshot::create(&workspace).unwrap();
    assert_ne!(snapshot.path, second.path);
    let second_path = second.path.clone();
    drop(second);
    assert!(!second_path.exists());
    let worker = root.join("worker.dart");
    let artifact = root.join("worker");
    fs::write(&worker, "worker").unwrap();
    fs::write(&artifact, "artifact").unwrap();
    fs::write(root.join("sdk/version"), "sdk").unwrap();
    fs::write(
        root.join("sdk/lib/_internal/allowed_experiments.json"),
        "{}",
    )
    .unwrap();
    let escape = |path: &Path| {
        path.to_string_lossy()
            .replace('\\', "\\\\")
            .replace(' ', "\\ ")
    };
    let depfile = root.join("worker.d");
    fs::write(
        &depfile,
        format!("out: {} {}\n", escape(&worker), escape(&snapshot.path)),
    )
    .unwrap();
    let metadata = super::build_aot_metadata(
        &workspace,
        &root.join("sdk"),
        &worker,
        &worker,
        &snapshot.path,
        &depfile,
        &artifact,
        "snapshot-key",
    )
    .unwrap();
    assert_eq!(metadata.dependencies.len(), 1);
    drop(snapshot);
    assert!(!snapshot_path.exists());
    let metadata_path = root.join("worker.sdk");
    fs::write(&metadata_path, serde_json::to_vec(&metadata).unwrap()).unwrap();
    assert!(super::aot_metadata_is_current(
        &artifact,
        &metadata_path,
        &workspace,
        &root.join("sdk"),
        &worker,
        "snapshot-key",
    ));
    let mut failed_path = None;
    let failed = (|| -> std::io::Result<()> {
        let snapshot = super::CompilerConfigSnapshot::create(&workspace)?;
        failed_path = Some(snapshot.path.clone());
        Command::new(root.join("missing-compiler")).status()?;
        Ok(())
    })();
    assert!(failed.is_err());
    assert!(!failed_path.unwrap().exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn aot_key_tracks_lock_contents_through_manifest_and_rejects_read_errors() {
    let root = std::env::temp_dir().join(format!("aot-lock-key-{}", std::process::id()));
    fs::create_dir_all(root.join(".dart_tool")).unwrap();
    fs::create_dir_all(root.join("sdk/lib/_internal")).unwrap();
    fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
    fs::write(
        root.join(".dart_tool/package_config.json"),
        r#"{"configVersion":2,"packages":[]}"#,
    )
    .unwrap();
    fs::write(root.join("sdk/version"), "3.13.3").unwrap();
    fs::write(
        root.join("sdk/lib/_internal/allowed_experiments.json"),
        "{}",
    )
    .unwrap();
    let worker = root.join("worker.dart");
    fs::write(&worker, "worker").unwrap();
    let workspace = crate::workspace::Workspace::load(root.clone()).unwrap();
    let key = || super::aot_cache_key(&workspace, &worker, &root.join("sdk"));
    let lock = root.join("pubspec.lock");
    let missing = key().unwrap();
    fs::write(&lock, "").unwrap();
    assert_ne!(missing, key().unwrap());
    fs::write(&lock, "packages:\n  first: 1\n").unwrap();
    let first = key().unwrap();
    fs::write(&lock, "packages:\r\n  first: 1\r\n").unwrap();
    assert_eq!(first, key().unwrap());
    fs::write(&lock, "packages:\n  second: 2\n").unwrap();
    let second = key().unwrap();
    assert_ne!(first, second);
    let config_path = root.join(".dart_tool/package_config.json");
    let original_config = fs::read(&config_path).unwrap();
    fs::write(
        &config_path,
        r#"{"configVersion":2,"packages":[{"name":"app","rootUri":"../","languageVersion":"3.13"}]}"#,
    )
    .unwrap();
    let changed = crate::workspace::Workspace::load(root.clone()).unwrap();
    assert_ne!(
        workspace.package_config_identity(),
        changed.package_config_identity()
    );
    assert_ne!(
        second,
        super::aot_cache_key(&changed, &worker, &root.join("sdk")).unwrap()
    );
    fs::write(&config_path, original_config).unwrap();
    let old_key = format!(
        "{}-packages{}",
        second.replacen(
            "-worker",
            &format!(
                "-lock{}-worker",
                crate::digest::digest_bytes(b"packages:\n  second: 2\n")
            ),
            1,
        ),
        workspace.package_config_identity(),
    );
    let artifact = root.join("worker");
    fs::write(&artifact, "artifact").unwrap();
    let (sdk_version, allowed_experiments) = super::aot_sdk_identity(&root.join("sdk")).unwrap();
    let mut metadata = super::AotMetadata {
        format: super::AOT_METADATA_VERSION,
        cache_key: second.clone(),
        sdk_version,
        allowed_experiments,
        package_config: workspace.package_config_identity().into(),
        worker: super::digest_file(&worker).unwrap(),
        executable: super::digest_file(&artifact).unwrap(),
        dependencies: Default::default(),
    };
    let metadata_path = root.join("worker.sdk");
    fs::write(&metadata_path, serde_json::to_vec(&metadata).unwrap()).unwrap();
    let current = || {
        super::aot_metadata_is_current(
            &artifact,
            &metadata_path,
            &workspace,
            &root.join("sdk"),
            &worker,
            &second,
        )
    };
    assert!(current());
    metadata.cache_key = old_key;
    fs::write(&metadata_path, serde_json::to_vec(&metadata).unwrap()).unwrap();
    assert!(!current());
    let depfile = root.join("worker.d");
    let dependency = super::canonicalize(&worker)
        .unwrap()
        .to_string_lossy()
        .replace('\\', "\\\\")
        .replace(' ', "\\ ");
    fs::write(&depfile, format!("out: {dependency}\n")).unwrap();
    let build_metadata = || {
        super::build_aot_metadata(
            &workspace,
            &root.join("sdk"),
            &worker,
            &worker,
            &config_path,
            &depfile,
            &artifact,
            &second,
        )
    };
    assert!(build_metadata().is_ok());
    let original = fs::read(&config_path).unwrap();
    fs::write(
        &config_path,
        r#"{"packages":[],"configVersion":2,"changed":true}"#,
    )
    .unwrap();
    assert!(
        build_metadata()
            .unwrap_err()
            .to_string()
            .contains("changed after workspace preparation")
    );
    fs::write(config_path, original).unwrap();
    fs::remove_file(&lock).unwrap();
    fs::create_dir(&lock).unwrap();
    assert!(key().is_err());
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn cached_aot_validation_rejects_source_and_artifact_edits() {
    let root = std::env::temp_dir().join(format!("aot-digest-validation-{}", std::process::id()));
    fs::create_dir_all(root.join(".dart_tool")).unwrap();
    fs::create_dir_all(root.join("sdk/lib/_internal")).unwrap();
    fs::write(root.join("pubspec.yaml"), "name: validation_test\n").unwrap();
    fs::write(
        root.join(".dart_tool/package_config.json"),
        r#"{"configVersion":2,"packages":[]}"#,
    )
    .unwrap();
    fs::write(root.join("sdk/version"), "3.13.3").unwrap();
    fs::write(
        root.join("sdk/lib/_internal/allowed_experiments.json"),
        "{}",
    )
    .unwrap();
    let workspace = crate::workspace::Workspace::load(root.clone()).unwrap();
    let worker = root.join("worker.dart");
    let artifact = root.join("worker");
    let dep = root.join("dep.dart");
    let metadata_path = root.join("worker.sdk");
    for path in [&worker, &artifact, &dep] {
        fs::write(path, "before").unwrap();
    }
    let (sdk_version, allowed_experiments) = super::aot_sdk_identity(&root.join("sdk")).unwrap();
    let digest = crate::digest::digest_bytes(b"before");
    let metadata = super::AotMetadata {
        format: super::AOT_METADATA_VERSION,
        cache_key: "test".into(),
        sdk_version,
        allowed_experiments,
        package_config: workspace.package_config_identity().to_owned(),
        worker: digest.clone(),
        executable: digest.clone(),
        dependencies: [("workspace:dep.dart".into(), digest)]
            .into_iter()
            .collect(),
    };
    fs::write(&metadata_path, serde_json::to_vec(&metadata).unwrap()).unwrap();
    let current = || {
        super::aot_metadata_is_current(
            &artifact,
            &metadata_path,
            &workspace,
            &root.join("sdk"),
            &worker,
            "test",
        )
    };
    // Let initial stamps settle before testing the actual reuse path.
    thread::sleep(crate::file_stamp::STAMP_SETTLE + std::time::Duration::from_millis(100));
    assert!(current()); // Full validation creates local digest evidence.
    assert!(current()); // Reuses that evidence.
    let eligible = crate::file_stamp::reusable_devices(&root).is_some_and(|devices| {
        [&worker, &artifact, &dep].iter().any(|path| {
            devices.contains(&crate::file_stamp::stamp(path).unwrap()[0])
                && crate::file_stamp::is_settled(
                    &crate::file_stamp::stamp(path).unwrap(),
                    std::time::SystemTime::now(),
                )
        })
    });
    assert_eq!(
        root.join(".dart_tool/build_runner_accelerator/aot-validation-digests-b3.json")
            .is_file(),
        eligible
    );
    let mtime = fs::metadata(&dep).unwrap().modified().unwrap();
    // Separate the rewrite from the cached stamp even on coarse clocks.
    thread::sleep(std::time::Duration::from_millis(1100));
    fs::write(&dep, "after!").unwrap();
    OpenOptions::new()
        .write(true)
        .open(&dep)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(mtime))
        .unwrap();
    assert!(!current());
    fs::write(&dep, "before").unwrap();
    assert!(current());
    fs::write(&artifact, "cut").unwrap();
    assert!(!current());
    fs::write(&artifact, "before").unwrap();
    assert!(current());
    fs::remove_dir_all(root).unwrap();
}

fn write_kernel_stamp(kernel: &std::path::Path, config_key: String) {
    let stamp = super::KernelStamp {
        format: super::KERNEL_STAMP_VERSION,
        config_key,
        sdk_version: String::new(),
        allowed_experiments: String::new(),
        kernel_digest: String::new(),
        dependencies: Default::default(),
    };
    fs::write(
        kernel.with_extension("dill.config"),
        serde_json::to_string(&stamp).unwrap(),
    )
    .unwrap();
}

fn kernel_config_current(root: &std::path::Path, kernel: &std::path::Path) -> bool {
    super::read_kernel_stamp(kernel)
        .is_some_and(|stamp| super::kernel_stamp_config_is_current(root, &stamp))
}

#[test]
fn kernel_stamp_rejects_changed_effective_configuration() {
    let root = std::env::temp_dir().join(format!("kernel-config-stamp-{}", std::process::id()));
    fs::create_dir_all(root.join(".dart_tool")).unwrap();
    let config = root.join(".dart_tool/package_config.json");
    let kernel = root.join("worker.dill");
    assert!(!kernel_config_current(&root, &kernel));
    let contents = r#"{"configVersion":2,"packages":[{"name":"dep","rootUri":"../dep/"}]}"#;
    fs::write(&config, contents).unwrap();
    write_kernel_stamp(&kernel, super::kernel_package_config_key(&config).unwrap());
    assert!(kernel_config_current(&root, &kernel));
    fs::remove_file(kernel.with_extension("dill.config")).unwrap();
    assert!(!kernel_config_current(&root, &kernel));
    write_kernel_stamp(&kernel, super::kernel_package_config_key(&config).unwrap());
    fs::write(&config, "experimental configuration").unwrap();
    assert!(!kernel_config_current(&root, &kernel));
    fs::write(&config, contents).unwrap();
    assert!(kernel_config_current(&root, &kernel));
    let alternate = root.join("alternate/.dart_tool");
    fs::create_dir_all(&alternate).unwrap();
    fs::copy(&config, alternate.join("package_config.json")).unwrap();
    fs::write(
        root.join("pubspec.yaml"),
        "name: app\nresolution: workspace\n",
    )
    .unwrap();
    fs::create_dir_all(root.join(".dart_tool/pub")).unwrap();
    fs::write(
        root.join(".dart_tool/pub/workspace_ref.json"),
        r#"{"workspaceRoot":"../../alternate"}"#,
    )
    .unwrap();
    assert!(!kernel_config_current(&root, &kernel));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn kernel_stamp_tracks_isolated_configuration_in_child_process() {
    const CHILD: &str = "BRA_TEST_ISOLATED_KERNEL_STAMP_CHILD";
    if std::env::var_os(CHILD).is_none() {
        assert!(std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "worker_kernel::tests::kernel_stamp_tracks_isolated_configuration_in_child_process", "--nocapture"])
            .env(CHILD, "1").env(crate::compile_isolation::ENV, "1")
            .status().unwrap().success());
        return;
    }
    assert!(crate::compile_isolation::enabled());
    let root = std::env::temp_dir().join(format!("isolated-kernel-stamp-{}", std::process::id()));
    fs::create_dir_all(root.join(".dart_tool/build_runner_accelerator")).unwrap();
    let original = root.join(".dart_tool/package_config.json");
    let isolated = root.join(crate::compile_isolation::CONFIG);
    let kernel = root.join("worker.dill");
    fs::write(&original, "original").unwrap();
    fs::write(&isolated, "isolated").unwrap();
    let stamp = kernel.with_extension("dill.config");
    write_kernel_stamp(
        &kernel,
        super::kernel_package_config_key(&original).unwrap(),
    );
    assert!(!kernel_config_current(&root, &kernel));
    write_kernel_stamp(
        &kernel,
        super::kernel_package_config_key(&isolated).unwrap(),
    );
    assert!(kernel_config_current(&root, &kernel));
    fs::write(original, "changed original").unwrap();
    assert!(kernel_config_current(&root, &kernel));
    fs::write(isolated, "changed isolated").unwrap();
    assert!(!kernel_config_current(&root, &kernel));
    fs::remove_file(stamp).unwrap();
    assert!(!kernel_config_current(&root, &kernel));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn kernel_stamp_rejects_sdk_change_and_dependency_content_change() {
    use std::io::Write as _;
    let root = std::env::temp_dir().join(format!("kernel-stamp-validation-{}", std::process::id()));
    fs::create_dir_all(root.join(".dart_tool")).unwrap();
    fs::write(root.join("pubspec.yaml"), "name: app\n").unwrap();
    let config = root.join(".dart_tool/package_config.json");
    fs::write(&config, r#"{"configVersion":2,"packages":[]}"#).unwrap();
    for (sdk, version) in [("sdk_a", "3.13.3"), ("sdk_b", "3.14.0")] {
        fs::create_dir_all(root.join(sdk).join("lib/_internal")).unwrap();
        fs::write(root.join(sdk).join("version"), version).unwrap();
        fs::write(
            root.join(sdk)
                .join("lib/_internal/allowed_experiments.json"),
            "{}",
        )
        .unwrap();
    }
    fs::write(root.join("worker.dart"), "worker").unwrap();
    fs::write(root.join("dep.dart"), "before").unwrap();
    let worker = super::canonicalize(root.join("worker.dart")).unwrap();
    let dep = super::canonicalize(root.join("dep.dart")).unwrap();
    let kernel = root.join("worker.dill");
    let depfile = root.join("worker.dill.d");
    fs::write(&kernel, "kernel").unwrap();
    let escape = |path: &std::path::Path| {
        path.to_string_lossy()
            .replace('\\', "\\\\")
            .replace(' ', "\\ ")
    };
    fs::write(
        &depfile,
        format!("out: {} {}\n", escape(&worker), escape(&dep)),
    )
    .unwrap();
    let key = super::kernel_package_config_key(&config).unwrap();
    // Inputs written after the compile started cannot be stamped: the
    // digest would describe bytes the compiler may never have read.
    assert!(
        super::build_kernel_stamp(
            &root,
            &root.join("sdk_a"),
            &kernel,
            &depfile,
            &key,
            std::time::SystemTime::UNIX_EPOCH,
        )
        .is_err()
    );
    let stamp = super::build_kernel_stamp(
        &root,
        &root.join("sdk_a"),
        &kernel,
        &depfile,
        &key,
        std::time::SystemTime::now(),
    )
    .unwrap();
    fs::write(
        kernel.with_extension("dill.config"),
        serde_json::to_string(&stamp).unwrap(),
    )
    .unwrap();
    let current = |sdk: &str| {
        super::kernel_stamp_is_current(&root, &root.join(sdk), &kernel, &depfile, &worker)
    };
    assert!(current("sdk_a"));
    // A kernel compiled by another SDK must not be reused: its format
    // version may not load under the selected VM.
    assert!(!current("sdk_b"));
    // Let the digest evidence settle, then change a dependency's
    // contents while restoring its modification time: the mtime-only
    // check this replaces would have reused the stale kernel. The
    // settle window is Unix-only; elsewhere digests are compared
    // directly and a short delay is enough.
    #[cfg(unix)]
    let settle = crate::file_stamp::STAMP_SETTLE + std::time::Duration::from_millis(100);
    #[cfg(not(unix))]
    let settle = std::time::Duration::from_millis(100);
    thread::sleep(settle);
    assert!(current("sdk_a"));
    assert!(current("sdk_a"));
    let mtime = fs::metadata(&dep).unwrap().modified().unwrap();
    thread::sleep(std::time::Duration::from_millis(1100));
    fs::write(&dep, "after!").unwrap();
    std::fs::OpenOptions::new()
        .write(true)
        .open(&dep)
        .unwrap()
        .set_times(fs::FileTimes::new().set_modified(mtime))
        .unwrap();
    assert!(!current("sdk_a"));
    fs::write(&dep, "before").unwrap();
    assert!(current("sdk_a"));
    // The stamp also binds the kernel bytes themselves: a damaged or
    // replaced .dill is not reused.
    fs::write(&kernel, "tampered").unwrap();
    assert!(!current("sdk_a"));
    fs::write(&kernel, "kernel").unwrap();
    assert!(current("sdk_a"));
    // Stamps written before the format carried this evidence are
    // treated as stale, not parsed leniently.
    let mut plain = std::fs::File::create(kernel.with_extension("dill.config")).unwrap();
    plain.write_all(key.as_bytes()).unwrap();
    drop(plain);
    assert!(!current("sdk_a"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn prewarm_helper_uses_original_package_even_when_compiler_copies_only_lib() {
    let root =
        std::env::temp_dir().join(format!("prewarm-original-package-{}", std::process::id()));
    let original = root.join("original");
    fs::create_dir_all(root.join(".dart_tool/build_runner_accelerator")).unwrap();
    fs::create_dir_all(original.join("bin")).unwrap();
    let helper = original.join("bin/prewarm_analysis.dart");
    fs::write(&helper, "void main() {}\n").unwrap();
    fs::write(root.join(".dart_tool/package_config.json"), serde_json::to_vec(&serde_json::json!({"packages":[{"name":"build_runner_accelerator","rootUri":crate::runner_compatibility::file_uri(&original)}]})).unwrap()).unwrap();
    fs::write(
        root.join(".dart_tool/build_runner_accelerator/runner-package_config.json"),
        r#"{"packages":[{"name":"build_runner_accelerator","rootUri":"missing-copy/"}]}"#,
    )
    .unwrap();
    assert_eq!(super::prewarm_script_path(&root), Some(helper));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn early_worker_aot_panics_are_caught() {
    let result = catch_worker_aot_panic(|| -> std::io::Result<PathBuf> {
        panic!("injected AOT panic");
    });
    assert!(result.is_err());
}

#[test]
fn depfile_parser_handles_continuations_and_escaped_spaces() {
    let depfile = concat!(
        "/tmp/worker.dill: /tmp/package_config.json /tmp/path\\ with\\ spaces.dart \\\n",
        " /tmp/other.dart\n",
    );
    let dependencies = parse_depfile_dependencies(depfile).expect("dependencies");
    assert_eq!(
        dependencies,
        vec![
            PathBuf::from("/tmp/package_config.json"),
            PathBuf::from("/tmp/path with spaces.dart"),
            PathBuf::from("/tmp/other.dart"),
        ]
    );
}

#[test]
#[cfg(unix)]
fn aot_sdk_bin_supports_subprocesses_and_sdk_reselection() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("aot-sdk-bin-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let facade = root.join("facade");
    fs::create_dir_all(facade.join("bin")).unwrap();
    fs::write(facade.join("bin/worker"), "worker").unwrap();
    fs::write(facade.join("bin/preserved"), "physical").unwrap();
    std::os::unix::fs::symlink(root.join("unmanaged"), facade.join("bin/unmanaged")).unwrap();
    for version in ["first", "second"] {
        let sdk = root.join(version);
        fs::create_dir_all(sdk.join("bin/snapshots")).unwrap();
        fs::write(sdk.join("bin/snapshots/compiler"), version).unwrap();
        if version == "first" {
            fs::write(sdk.join("bin/obsolete"), "old SDK").unwrap();
            fs::write(sdk.join("bin/preserved_link"), "old SDK").unwrap();
        }
        fs::write(
            sdk.join("bin/dart"),
            "#!/bin/sh\ncat \"$(dirname \"$0\")/snapshots/compiler\"\n",
        )
        .unwrap();
        fs::set_permissions(sdk.join("bin/dart"), fs::Permissions::from_mode(0o755)).unwrap();
        link_sdk_bin(&sdk, &facade).unwrap();
        link_sdk_bin(&sdk, &facade).unwrap();
        let result = Command::new(facade.join("bin/dart")).output().unwrap();
        assert!(result.status.success());
        assert_eq!(result.stdout, version.as_bytes());
        if version == "first" {
            // Obsolete SDK links must disappear even if their target was
            // removed before reselection.
            fs::remove_file(sdk.join("bin/obsolete")).unwrap();
            fs::remove_file(facade.join("bin/preserved_link")).unwrap();
            fs::write(facade.join("bin/preserved_link"), "user replacement").unwrap();
        } else {
            assert!(fs::symlink_metadata(facade.join("bin/obsolete")).is_err());
            assert_eq!(
                fs::read(facade.join("bin/preserved_link")).unwrap(),
                b"user replacement"
            );
        }
    }
    assert_eq!(fs::read(facade.join("bin/worker")).unwrap(), b"worker");
    assert_eq!(fs::read(facade.join("bin/preserved")).unwrap(), b"physical");
    assert_eq!(
        fs::read_link(facade.join("bin/unmanaged")).unwrap(),
        root.join("unmanaged")
    );
    let registry = || -> Vec<PathBuf> {
        serde_json::from_slice(&fs::read(facade.join("sdk-bin-links.json")).unwrap()).unwrap()
    };
    let mut expected = vec![
        root.join("second/bin/dart"),
        root.join("second/bin/snapshots"),
    ];
    expected.sort();
    assert_eq!(registry(), expected, "SDK history must not remain owned");
    // A user can recreate a formerly managed link after its removal. It
    // must stay unmanaged even when it points to that old SDK's bin path.
    let user_target = root.join("first/bin/obsolete");
    std::os::unix::fs::symlink(&user_target, facade.join("bin/obsolete")).unwrap();
    link_sdk_bin(&root.join("second"), &facade).unwrap();
    assert_eq!(
        fs::read_link(facade.join("bin/obsolete")).unwrap(),
        user_target
    );
    assert_eq!(registry(), expected);
    // A conflicting physical entry must be rejected, never overwritten.
    fs::remove_file(facade.join("bin/dart")).unwrap();
    fs::write(facade.join("bin/dart"), "owned").unwrap();
    assert!(link_sdk_bin(&root.join("second"), &facade).is_err());
    assert_eq!(fs::read(facade.join("bin/dart")).unwrap(), b"owned");
    assert_eq!(registry(), vec![root.join("second/bin/snapshots")]);
    // A partially successful SDK switch retains active links, but neither
    // removed SDK paths nor a failed physical-file conflict stay owned.
    let third = root.join("third");
    fs::create_dir_all(third.join("bin")).unwrap();
    fs::write(third.join("bin/a_tool"), "new SDK").unwrap();
    fs::write(third.join("bin/z_conflict"), "new SDK").unwrap();
    fs::write(facade.join("bin/z_conflict"), "user file").unwrap();
    assert!(link_sdk_bin(&third, &facade).is_err());
    assert_eq!(registry(), vec![third.join("bin/a_tool")]);
    assert_eq!(
        fs::read(facade.join("bin/z_conflict")).unwrap(),
        b"user file"
    );
    assert_eq!(
        fs::read_link(facade.join("bin/obsolete")).unwrap(),
        user_target
    );
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn sdk_bin_registry_serializes_processes() {
    const CHILD_ROOT: &str = "BUILD_RUNNER_ACCELERATOR_TEST_SDK_LINK_ROOT";
    if let Some(root) = std::env::var_os(CHILD_ROOT) {
        let root = PathBuf::from(root);
        fs::write(root.join("started"), b"started").unwrap();
        link_sdk_bin(&root.join("sdk"), &root.join("facade")).unwrap();
        return;
    }
    let root = std::env::temp_dir().join(format!("sdk-bin-process-lock-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("sdk/bin")).unwrap();
    fs::create_dir_all(root.join("facade/bin")).unwrap();
    fs::write(root.join("sdk/bin/dart"), b"SDK").unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join("facade/sdk-bin-links.lock"))
        .unwrap();
    lock.lock().unwrap();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "worker_kernel::tests::sdk_bin_registry_serializes_processes",
            "--nocapture",
        ])
        .env(CHILD_ROOT, &root)
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !root.join("started").exists() && std::time::Instant::now() < deadline {
        assert!(child.try_wait().unwrap().is_none());
        thread::sleep(std::time::Duration::from_millis(10));
    }
    if !root.join("started").exists() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("SDK registry child did not start");
    }
    thread::sleep(std::time::Duration::from_millis(100));
    let blocked = child.try_wait().unwrap().is_none();
    let untouched = !root.join("facade/sdk-bin-links.json").exists()
        && fs::symlink_metadata(root.join("facade/bin/dart")).is_err();
    drop(lock);
    while child.try_wait().unwrap().is_none() && std::time::Instant::now() < deadline {
        thread::sleep(std::time::Duration::from_millis(10));
    }
    if child.try_wait().unwrap().is_none() {
        let _ = child.kill();
    }
    let status = child.wait().unwrap();
    assert!(
        blocked && untouched,
        "another process must not mutate a locked registry"
    );
    assert!(status.success());
    assert_eq!(
        fs::read_link(root.join("facade/bin/dart")).unwrap(),
        root.join("sdk/bin/dart")
    );
    let owned: Vec<PathBuf> =
        serde_json::from_slice(&fs::read(root.join("facade/sdk-bin-links.json")).unwrap()).unwrap();
    assert_eq!(owned, vec![root.join("sdk/bin/dart")]);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn background_lock_is_single_flight() {
    let path = std::env::temp_dir().join(format!(
        "build-runner-accelerator-lock-{}",
        std::process::id()
    ));
    let _ = fs::remove_file(&path);
    let gate = Arc::new(Barrier::new(8));
    let handles = (0..8)
        .map(|_| {
            let gate = Arc::clone(&gate);
            let path = path.clone();
            thread::spawn(move || {
                gate.wait();
                acquire_background_aot_lock(&path).unwrap()
            })
        })
        .collect::<Vec<_>>();
    let owners = handles
        .into_iter()
        .map(|handle| handle.join().unwrap())
        .filter(|owned| *owned)
        .count();
    assert_eq!(owners, 1);
    let _ = fs::remove_file(path);
}

#[test]
fn fresh_background_lock_is_not_stale() {
    let path = std::env::temp_dir().join(format!(
        "build-runner-accelerator-fresh-lock-{}",
        std::process::id()
    ));
    let _ = fs::remove_file(&path);
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&path)
        .unwrap();
    assert!(!background_aot_lock_is_stale(&path));
    let _ = fs::remove_file(path);
}

static PREWARM_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn aot_wait_retries_share_the_deadline() {
    let root = std::env::temp_dir().join(format!(
        "build-runner-accelerator-wait-deadline-{}",
        std::process::id()
    ));
    fs::create_dir_all(root.join(".dart_tool")).unwrap();
    fs::write(root.join("pubspec.yaml"), "name: wait_test\n").unwrap();
    fs::write(
        root.join(".dart_tool/package_config.json"),
        r#"{"configVersion":2,"packages":[]}"#,
    )
    .unwrap();
    let context = super::AotContext {
        workspace: crate::workspace::Workspace::load(root.clone()).unwrap(),
        sdk_root: root.join("sdk"),
        worker_path: root.join("worker.dart"),
        worker_digest: "unused".to_owned(),
        cache_key: "wait-deadline-test".to_owned(),
        aot_sdk_root: root.join("aot-sdk"),
        aot_path: root.join("aot-sdk/bin/worker"),
        depfile_path: root.join("aot-sdk/bin/worker.d"),
        sdk_metadata_path: root.join("aot-sdk/bin/worker.sdk"),
    };
    // A script stays pinned even if an AOT compile finishes mid-session.
    assert!(
        pinned_worker_artifact_is_current(
            &context.workspace,
            "unused",
            "unused.dart",
            &WorkerArtifact::Script,
        )
        .unwrap()
    );
    let lock_path = root.join(super::AOT_COMPILE_LOCK_NAME);
    assert!(acquire_background_aot_lock(&lock_path).unwrap());
    let deadline = std::time::Instant::now();
    for _ in 0..2 {
        assert!(
            super::wait_for_aot_winner(&context, &lock_path, deadline)
                .unwrap()
                .is_none()
        );
    }
    assert!(deadline.elapsed() < std::time::Duration::from_secs(1));
    assert!(lock_path.is_file());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn analysis_prewarm_spawn_is_single_flight() {
    let _guard = PREWARM_TEST_LOCK.lock().unwrap();
    ANALYSIS_PREWARM_ACTIVE.store(true, Ordering::SeqCst);
    assert!(spawn_analysis_prewarm(Path::new("/nonexistent"), "dart", "test").is_none());
    ANALYSIS_PREWARM_ACTIVE.store(false, Ordering::SeqCst);
}

#[test]
fn analysis_prewarm_missing_package_config_releases_flag() {
    let _guard = PREWARM_TEST_LOCK.lock().unwrap();
    let root = std::env::temp_dir().join(format!(
        "build-runner-accelerator-prewarm-{}",
        std::process::id()
    ));
    fs::create_dir_all(&root).unwrap();
    assert!(spawn_analysis_prewarm(&root, "dart", "test").is_none());
    assert!(!ANALYSIS_PREWARM_ACTIVE.load(Ordering::SeqCst));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn analysis_prewarm_enabled_follows_env() {
    let _guard = PREWARM_TEST_LOCK.lock().unwrap();
    let name = "BUILD_RUNNER_ACCELERATOR_ANALYSIS_PREWARM";
    let saved = std::env::var_os(name);
    // SAFETY: env mutation is unsafe in edition 2024; PREWARM_TEST_LOCK
    // serializes every test in this module that touches the environment.
    unsafe {
        std::env::remove_var(name);
        assert!(analysis_prewarm_enabled());
        std::env::set_var(name, "0");
        assert!(!analysis_prewarm_enabled());
        std::env::set_var(name, "off");
        assert!(!analysis_prewarm_enabled());
        match saved {
            Some(value) => std::env::set_var(name, value),
            None => std::env::remove_var(name),
        }
    }
}
