use crate::digest::{bare_digest, digest_bytes};
use crate::protocol::GlobRead;
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::Path;
use std::thread;

const PARALLEL_SCAN_THRESHOLD: usize = 64;
const MIN_FILES_PER_WORKER: usize = 32;
const MAX_SCAN_WORKERS: usize = 8;

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
        .map(|(asset, entry)| (asset.clone(), bare_digest(&entry.digest).to_owned()))
        .collect()
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

#[allow(dead_code)]
fn scan_packages_sequential(
    workspace: &Workspace,
    packages: &BTreeSet<String>,
) -> io::Result<Snapshot> {
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

fn scan_asset(asset: &str, path: &Path, buffer: &mut [u8]) -> io::Result<AssetSnapshot> {
    if crate::placeholders::is_placeholder_asset(asset) {
        return Err(io::Error::other(format!(
            "Unsupported native source at a virtual primary path: {asset}"
        )));
    }
    // Stream through the hasher with a caller-owned buffer: parallel workers
    // must not each hold a whole asset in memory, and the buffer is reused
    // across files. The streamed BLAKE3 digest and the counted size are
    // identical to hashing `std::fs::read` bytes with `digest_bytes` (same
    // `b3-` prefixed hex form).
    use std::io::Read as _;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut size: u64 = 0;
    loop {
        // `std::fs::read` retries interrupted reads internally; match that
        // behavior so a transient signal cannot fail the scan.
        let read = match file.read(buffer) {
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        size += read as u64;
    }
    Ok(AssetSnapshot {
        exists: true,
        digest: format!("b3-{}", hasher.finalize().to_hex()),
        size,
    })
}

/// Whether an error reports descriptor/handle exhaustion, using each
/// platform's own codes: ENFILE (23) / EMFILE (24) on unix,
/// ERROR_TOO_MANY_OPEN_FILES (4) on Windows.
fn is_descriptor_exhaustion(error: &io::Error) -> bool {
    #[cfg(unix)]
    {
        matches!(error.raw_os_error(), Some(23) | Some(24))
    }
    #[cfg(windows)]
    {
        error.raw_os_error() == Some(4)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = error;
        false
    }
}

/// Consume one package's file list and insert each entry directly, as the
/// original sequential scan did: no cloned IDs or package-sized temporary.
fn scan_package_into(
    snapshot: &mut Snapshot,
    files: Vec<(String, std::path::PathBuf)>,
) -> io::Result<()> {
    let mut buffer = [0u8; 64 * 1024];
    for (asset, path) in files {
        let entry = scan_asset(&asset, &path, &mut buffer)?;
        snapshot.insert(asset, entry);
    }
    Ok(())
}

/// Scan one chunk, returning entries in file order. Asset IDs are not
/// cloned: the caller zips the ordered entries back with the file list
/// after every chunk succeeds.
fn scan_chunk(files: &[(String, std::path::PathBuf)]) -> io::Result<Vec<AssetSnapshot>> {
    let mut buffer = [0u8; 64 * 1024];
    let mut scanned = Vec::with_capacity(files.len());
    for (asset, path) in files {
        scanned.push(scan_asset(asset, path, &mut buffer)?);
    }
    Ok(scanned)
}

fn scan_worker_count(file_count: usize, parallelism: usize) -> usize {
    if file_count < PARALLEL_SCAN_THRESHOLD {
        1
    } else {
        parallelism
            .min(MAX_SCAN_WORKERS)
            .min(file_count / MIN_FILES_PER_WORKER)
            .max(1)
    }
}

pub fn scan_packages(workspace: &Workspace, packages: &BTreeSet<String>) -> io::Result<Snapshot> {
    let parallelism = thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);
    scan_packages_with_parallelism(workspace, packages, parallelism)
}

/// `parallelism` is the host parallelism the worker count derives from;
/// tests pass explicit values so the parallel path is exercised even on
/// single-CPU runners.
fn scan_packages_with_parallelism(
    workspace: &Workspace,
    packages: &BTreeSet<String>,
    parallelism: usize,
) -> io::Result<Snapshot> {
    let mut snapshot = Snapshot::new();
    let virtual_primary = std::cell::LazyCell::new(|| AssetSnapshot {
        exists: true,
        digest: digest_bytes(b"<virtual-primary>"),
        size: 0,
    });
    for package in packages {
        let files = workspace.list_package_assets(package)?;
        let worker_count = scan_worker_count(files.len(), parallelism);
        if worker_count <= 1 {
            scan_package_into(&mut snapshot, files)?;
        } else {
            let chunk_size = files.len().div_ceil(worker_count);
            let scanned = thread::scope(|scope| -> io::Result<Vec<_>> {
                // `Scope::spawn` panics when the OS refuses a new thread, which
                // must not fail a scan the sequential path could complete:
                // chunks that cannot be spawned are scanned inline instead.
                let mut handles = Vec::new();
                let mut by_index: BTreeMap<usize, io::Result<Vec<AssetSnapshot>>> = BTreeMap::new();
                for (index, chunk) in files.chunks(chunk_size).enumerate() {
                    match thread::Builder::new().spawn_scoped(scope, move || scan_chunk(chunk)) {
                        Ok(handle) => handles.push((index, handle)),
                        Err(_) => {
                            by_index.insert(index, scan_chunk(chunk));
                        }
                    }
                }
                for (index, handle) in handles {
                    // A panicked worker becomes this chunk's error so the
                    // first error in chunk order still wins, exactly as in
                    // the sequential scan.
                    let result = handle
                        .join()
                        .unwrap_or_else(|_| Err(io::Error::other("snapshot scan thread panicked")));
                    by_index.insert(index, result);
                }
                by_index.into_values().collect()
            });
            match scanned {
                Ok(chunks) => {
                    // Chunks partition the file list contiguously and in
                    // order, so zipping restores each asset's entry without
                    // cloned IDs.
                    let entries = chunks.into_iter().flatten();
                    for ((asset, _), entry) in files.into_iter().zip(entries) {
                        snapshot.insert(asset, entry);
                    }
                }
                // Concurrent opens can exhaust file descriptors where a
                // serial scan fits; retry this package serially before
                // giving up.
                Err(error) if is_descriptor_exhaustion(&error) => {
                    scan_package_into(&mut snapshot, files)?;
                }
                Err(error) => return Err(error),
            }
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
    use crate::workspace::Workspace;
    use std::fs;
    use std::hint::black_box;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Instant;

    static TEMP_WORKSPACE_COUNTER: AtomicU64 = AtomicU64::new(0);

    struct TempDirGuard(PathBuf);

    impl Drop for TempDirGuard {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn build_temp_workspace(label: &str, lib_files: &[(&str, &[u8])]) -> (TempDirGuard, Workspace) {
        let id = TEMP_WORKSPACE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("bra-snapshot-{label}-{}-{id}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join(".dart_tool")).unwrap();
        fs::create_dir_all(dir.join("lib")).unwrap();
        fs::write(dir.join("pubspec.yaml"), "name: app\n").unwrap();
        fs::write(
            dir.join(".dart_tool/package_config.json"),
            r#"{"configVersion":2,"packages":[{"name":"app","rootUri":"../","packageUri":"lib/"}]}"#,
        )
        .unwrap();
        for (rel_path, contents) in lib_files {
            let path = dir.join("lib").join(rel_path);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(path, contents).unwrap();
        }
        let guard = TempDirGuard(dir.clone());
        let workspace = Workspace::load(dir).unwrap();
        (guard, workspace)
    }

    #[test]
    fn workspace_is_sync() {
        fn assert_sync<T: Sync>() {}
        assert_sync::<Workspace>();
    }

    #[test]
    fn scan_packages_matches_sequential_for_200_varied_files() {
        let mut owned_files: Vec<(String, Vec<u8>)> = Vec::with_capacity(200);
        owned_files.push(("empty.dart".to_owned(), Vec::new()));
        owned_files.push((
            "binary.bin".to_owned(),
            vec![0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28, 0xaa],
        ));
        // Larger than the 64KiB streaming buffer, to cross read boundaries.
        owned_files.push((
            "large.bin".to_owned(),
            (0..200_000u32).map(|i| (i % 251) as u8).collect(),
        ));
        for index in 3..200 {
            owned_files.push((
                format!("sub_{}/file_{index:03}.dart", index % 5),
                format!("// file {index}\nfinal value{index} = {};\n", index * 31).into_bytes(),
            ));
        }
        let file_refs: Vec<(&str, &[u8])> = owned_files
            .iter()
            .map(|(path, bytes)| (path.as_str(), bytes.as_slice()))
            .collect();
        let (_guard, workspace) = build_temp_workspace("equiv-200", &file_refs);
        let packages = BTreeSet::from(["app".to_owned()]);

        let expected = scan_packages_sequential(&workspace, &packages).unwrap();
        let actual = scan_packages(&workspace, &packages).unwrap();
        assert_eq!(actual, expected);
        // Force the parallel path regardless of host CPU count.
        let forced = scan_packages_with_parallelism(&workspace, &packages, 8).unwrap();
        assert_eq!(forced, expected);

        // The sequential oracle uses `fs::read` + `digest_bytes`, so the
        // equality checks above already cross-validate the streaming path;
        // pin digests directly as well for representative contents: empty,
        // non-UTF8, and multi-buffer files.
        for (asset, contents) in [
            ("app|lib/empty.dart", &[][..]),
            (
                "app|lib/binary.bin",
                &[0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28, 0xaa][..],
            ),
            (
                "app|lib/large.bin",
                &owned_files
                    .iter()
                    .find(|(path, _)| path == "large.bin")
                    .unwrap()
                    .1[..],
            ),
        ] {
            let entry = &expected[asset];
            assert_eq!(entry.digest, digest_bytes(contents), "digest for {asset}");
            assert_eq!(entry.size, contents.len() as u64, "size for {asset}");
        }
    }

    #[test]
    fn scan_packages_matches_sequential_at_threshold_boundaries() {
        // Vary lib/ file counts around PARALLEL_SCAN_THRESHOLD; the enumerated
        // total also includes pubspec.yaml and .dart_tool/package_config.json,
        // so both sides of the threshold are covered.
        for lib_file_count in [61_usize, 62, 63, 64, 65] {
            let owned_files: Vec<(String, Vec<u8>)> = (0..lib_file_count)
                .map(|index| {
                    (
                        format!("file_{index:03}.dart"),
                        format!("const v{index} = {index};\n").into_bytes(),
                    )
                })
                .collect();
            let file_refs: Vec<(&str, &[u8])> = owned_files
                .iter()
                .map(|(path, bytes)| (path.as_str(), bytes.as_slice()))
                .collect();
            let (_guard, workspace) =
                build_temp_workspace(&format!("boundary-{lib_file_count}"), &file_refs);
            // Pin the enumerated total (lib/ files + pubspec.yaml +
            // .dart_tool/package_config.json) so a fixture change cannot
            // silently drop a threshold side from coverage.
            assert_eq!(
                workspace.list_package_assets("app").unwrap().len(),
                lib_file_count + 2,
                "enumerated total drifted for lib_file_count={lib_file_count}"
            );
            let packages = BTreeSet::from(["app".to_owned()]);

            let expected = scan_packages_sequential(&workspace, &packages).unwrap();
            let actual = scan_packages(&workspace, &packages).unwrap();
            assert_eq!(
                actual, expected,
                "mismatch for lib_file_count={lib_file_count}"
            );
            // Force each worker-count shape regardless of host CPU count.
            for parallelism in [1_usize, 2, 4, 8] {
                let forced =
                    scan_packages_with_parallelism(&workspace, &packages, parallelism).unwrap();
                assert_eq!(
                    forced, expected,
                    "mismatch for lib_file_count={lib_file_count} parallelism={parallelism}"
                );
            }
        }
    }

    #[test]
    fn scan_packages_preserves_first_placeholder_error_in_sorted_order() {
        let mut owned_files: Vec<(String, Vec<u8>)> = (0..100)
            .map(|index| {
                (
                    format!("file_{index:03}.dart"),
                    format!("const x{index} = {index};\n").into_bytes(),
                )
            })
            .collect();
        owned_files.push(("$lib$".to_owned(), b"placeholder".to_vec()));
        let file_refs: Vec<(&str, &[u8])> = owned_files
            .iter()
            .map(|(path, bytes)| (path.as_str(), bytes.as_slice()))
            .collect();
        let (guard, workspace) = build_temp_workspace("error-order", &file_refs);
        fs::create_dir_all(guard.0.join("web")).unwrap();
        fs::write(guard.0.join("web/$web$"), b"placeholder").unwrap();

        // Force 4 workers and confirm the two placeholder assets land in
        // distinct chunks, so chunk-order error precedence is what the
        // assertion below actually exercises, on any host CPU count.
        let files = workspace.list_package_assets("app").unwrap();
        let worker_count = scan_worker_count(files.len(), 4);
        assert!(worker_count >= 2, "test must exercise the parallel path");
        let chunk_size = files.len().div_ceil(worker_count);
        let chunk_of =
            |asset: &str| files.iter().position(|(name, _)| name == asset).unwrap() / chunk_size;
        assert_ne!(
            chunk_of("app|lib/$lib$"),
            chunk_of("app|web/$web$"),
            "placeholder assets must be in distinct chunks"
        );

        let packages = BTreeSet::from(["app".to_owned()]);
        let seq_err = scan_packages_sequential(&workspace, &packages).unwrap_err();
        let par_err = scan_packages_with_parallelism(&workspace, &packages, 4).unwrap_err();

        assert!(
            par_err.to_string().contains("app|lib/$lib$"),
            "unexpected error message: {par_err}"
        );
        assert_eq!(par_err.to_string(), seq_err.to_string());
    }

    #[test]
    #[ignore = "performance measurement; run release with --ignored --nocapture"]
    fn scan_packages_benchmark() {
        let owned_files: Vec<(String, Vec<u8>)> = (0..2048)
            .map(|index| {
                (
                    format!("dir_{:02}/model_{index:04}.dart", index % 32),
                    format!(
                        "// Generated fixture {index}\nclass Model{index} {{ final int value = {index}; }}\n{}",
                        "a".repeat(1024)
                    )
                    .into_bytes(),
                )
            })
            .collect();
        let file_refs: Vec<(&str, &[u8])> = owned_files
            .iter()
            .map(|(path, bytes)| (path.as_str(), bytes.as_slice()))
            .collect();
        let (_guard, workspace) = build_temp_workspace("bench-2048", &file_refs);
        let packages = BTreeSet::from(["app".to_owned()]);

        // Report the mode actually measured: on a single-CPU host the
        // production entry point selects the sequential path.
        let file_count = workspace.list_package_assets("app").unwrap().len();
        let parallelism = thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4);
        let worker_count = scan_worker_count(file_count, parallelism);
        let mode = if worker_count <= 1 {
            "sequential (host parallelism selects 1 worker)"
        } else {
            "parallel"
        };

        // Warm up both paths so neither benefits from cold filesystem caches,
        // then alternate the measurement order across repetitions.
        let seq_snapshot = scan_packages_sequential(&workspace, &packages).unwrap();
        let par_snapshot = scan_packages(&workspace, &packages).unwrap();
        assert_eq!(par_snapshot, seq_snapshot);
        let mut seq_times = Vec::new();
        let mut par_times = Vec::new();
        for rep in 0..3 {
            let measure_seq = || {
                let start = Instant::now();
                black_box(scan_packages_sequential(&workspace, &packages)).unwrap();
                start.elapsed()
            };
            let measure_par = || {
                let start = Instant::now();
                black_box(scan_packages(&workspace, &packages)).unwrap();
                start.elapsed()
            };
            if rep % 2 == 0 {
                seq_times.push(measure_seq());
                par_times.push(measure_par());
            } else {
                par_times.push(measure_par());
                seq_times.push(measure_seq());
            }
        }
        seq_times.sort();
        par_times.sort();
        println!(
            "scan_packages_benchmark ({file_count} files, workers={worker_count}, mode={mode}): \
             sequential_median={:?}, {mode}_median={:?}",
            seq_times[1], par_times[1]
        );
    }

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
