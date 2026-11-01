//! Local digest reuse. Expected digests still come from AOT metadata.
use crate::digest::digest_bytes;
use std::{fs, path::Path};

#[cfg(unix)]
mod local {
    use super::*;
    use crate::file_stamp::{Stamp, is_settled, reusable_devices, stamp};
    use serde::{Deserialize, Serialize};
    use std::{
        collections::{BTreeMap, BTreeSet},
        path::PathBuf,
    };

    const RECEIPT: &str = ".dart_tool/build_runner_accelerator/aot-validation-digests.json";

    #[derive(Default, Deserialize, Serialize)]
    struct Receipt {
        files: BTreeMap<PathBuf, (Stamp, String)>,
    }

    pub(crate) struct Cache {
        receipt: Option<Receipt>,
        devices: BTreeSet<u64>,
        changed: bool,
        used: BTreeSet<PathBuf>,
    }

    impl Cache {
        /// Load disposable evidence; missing or malformed data requires rehashing.
        pub(crate) fn load(root: &Path) -> Self {
            Self::load_on_devices(root, reusable_devices(root))
        }

        fn load_on_devices(root: &Path, devices: Option<BTreeSet<u64>>) -> Self {
            let receipt = devices.as_ref().map(|_| {
                fs::read(root.join(RECEIPT))
                    .ok()
                    .and_then(|bytes| serde_json::from_slice::<Receipt>(&bytes).ok())
                    .unwrap_or_default()
            });
            Self {
                receipt,
                devices: devices.unwrap_or_default(),
                changed: false,
                used: BTreeSet::new(),
            }
        }

        /// Match content, reusing only settled stamps with the expected digest.
        pub(crate) fn matches(&mut self, path: &Path, expected: &str) -> bool {
            self.matches_at(path, expected, std::time::SystemTime::now())
        }

        fn matches_at(&mut self, path: &Path, expected: &str, now: std::time::SystemTime) -> bool {
            let Some(receipt) = &mut self.receipt else {
                return fs::read(path).is_ok_and(|bytes| digest_bytes(&bytes) == expected);
            };
            let before = stamp(path).ok();
            if before.is_none_or(|stamp| !self.devices.contains(&stamp[0])) {
                return fs::read(path).is_ok_and(|bytes| digest_bytes(&bytes) == expected);
            }
            self.used.insert(path.to_owned());
            if let Some(before) = before
                && receipt.files.get(path).is_some_and(|(old, digest)| {
                    *old == before && digest == expected && is_settled(&before, now)
                })
            {
                return true;
            }
            let Ok(bytes) = fs::read(path) else {
                return false;
            };
            let actual = digest_bytes(&bytes);
            if actual != expected {
                return false;
            }
            if let Some(before) = before {
                if !stamp(path).is_ok_and(|after| after == before) {
                    return false;
                }
                if is_settled(&before, now) {
                    receipt.files.insert(path.to_owned(), (before, actual));
                    self.changed = true;
                }
            }
            true
        }

        /// Publish after complete AOT validation; cache-write failures are optional.
        pub(crate) fn save(self, root: &Path) {
            if !self.changed {
                return;
            }
            let Some(mut receipt) = self.receipt else {
                return;
            };
            receipt.files.retain(|path, _| self.used.contains(path));
            let Ok(bytes) = serde_json::to_vec(&receipt) else {
                return;
            };
            let destination = root.join(RECEIPT);
            let Some(parent) = destination.parent() else {
                return;
            };
            if fs::create_dir_all(parent).is_err() {
                return;
            }
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let temporary = destination.with_extension(format!(
                "{}.{}.tmp",
                std::process::id(),
                NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            ));
            let Ok(mut file) = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)
            else {
                return;
            };
            use std::io::Write;
            let written = file.write_all(&bytes).is_ok();
            drop(file);
            if written {
                let _ = fs::rename(&temporary, &destination);
            }
            // Only remove a temporary file created by this invocation. A
            // concurrent writer can lose reuse opportunities, never validation.
            let _ = fs::remove_file(temporary);
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        fn test_cache(root: &Path) -> Cache {
            // Exercise receipt logic independently of the test host's mounts.
            Cache::load_on_devices(root, Some([stamp(root).unwrap()[0]].into_iter().collect()))
        }
        #[test]
        fn unsupported_devices_and_disabled_cache_rehash_despite_clock_lead() {
            let root =
                std::env::temp_dir().join(format!("aot-digest-remote-{}", std::process::id()));
            fs::create_dir_all(&root).unwrap();
            let path = root.join("worker");
            fs::write(&path, "after!").unwrap();
            let expected = digest_bytes(b"before");
            let mut cache = test_cache(&root);
            cache
                .receipt
                .as_mut()
                .unwrap()
                .files
                .insert(path.clone(), (stamp(&path).unwrap(), expected.clone()));
            cache.devices.clear(); // Dependency moved to an unsupported device.
            let client_now = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
            assert!(!cache.matches_at(&path, &expected, client_now));
            assert!(!cache.changed);
            assert!(cache.matches_at(&path, &digest_bytes(b"after!"), client_now));
            assert!(!cache.changed);
            let mut cache = Cache::load_on_devices(&root, None);
            assert!(cache.receipt.is_none());
            assert!(!cache.matches(&path, &expected));
            assert!(cache.matches(&path, &digest_bytes(b"after!")));
            fs::remove_dir_all(root).unwrap();
        }

        #[test]
        fn fresh_evidence_cannot_authorize_a_stale_digest() {
            let root =
                std::env::temp_dir().join(format!("aot-digest-unsettled-{}", std::process::id()));
            fs::create_dir_all(root.join(RECEIPT).parent().unwrap()).unwrap();
            let path = root.join("worker");
            fs::write(&path, "after!").unwrap();
            let expected = digest_bytes(b"before");
            let mut cache = test_cache(&root);
            // Simulate an old digest whose coarse stamp collides with the new
            // file. The fast path must rehash a stamp inside the settle window.
            cache
                .receipt
                .as_mut()
                .unwrap()
                .files
                .insert(path.clone(), (stamp(&path).unwrap(), expected.clone()));
            assert!(!cache.matches(&path, &expected));
            assert!(!cache.changed);
            let mut cache = test_cache(&root);
            assert!(cache.receipt.as_ref().unwrap().files.is_empty());
            assert!(!cache.matches(&path, &expected));
            // Successful full validation of a fresh file must not mint evidence.
            assert!(cache.matches(&path, &digest_bytes(b"after!")));
            assert!(cache.receipt.as_ref().unwrap().files.is_empty());
            assert!(!cache.changed);
            fs::remove_dir_all(root).unwrap();
        }

        #[test]
        fn reuse_detects_restored_mtime_replacement_truncation_and_bad_receipts() {
            let root = std::env::temp_dir().join(format!(
                "aot-digest-cache-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(&root).unwrap();
            let path = root.join("worker");
            fs::write(&path, "before").unwrap();
            let digest = digest_bytes(b"before");
            std::thread::sleep(
                crate::file_stamp::STAMP_SETTLE + std::time::Duration::from_millis(100),
            );
            let mut cache = test_cache(&root);
            assert!(cache.matches(&path, &digest));
            cache.save(&root);
            let mut cache = test_cache(&root);
            assert!(cache.matches(&path, &digest));
            assert!(!cache.changed);
            let mtime = fs::metadata(&path).unwrap().modified().unwrap();
            std::thread::sleep(std::time::Duration::from_millis(1100));
            fs::write(&path, "after!").unwrap();
            fs::OpenOptions::new()
                .write(true)
                .open(&path)
                .unwrap()
                .set_times(fs::FileTimes::new().set_modified(mtime))
                .unwrap();
            assert!(!cache.matches(&path, &digest));
            fs::remove_file(&path).unwrap();
            fs::write(&path, "before").unwrap();
            assert!(cache.matches(&path, &digest));
            fs::write(&path, "cut").unwrap();
            assert!(!cache.matches(&path, &digest));
            fs::create_dir_all(root.join(RECEIPT).parent().unwrap()).unwrap();
            fs::write(root.join(RECEIPT), "incomplete").unwrap();
            assert!(!test_cache(&root).matches(&path, &digest));
            fs::write(&path, "before").unwrap();
            assert!(test_cache(&root).matches(&path, &digest));
            fs::remove_file(root.join(RECEIPT)).unwrap();
            assert!(test_cache(&root).matches(&path, &digest));
            fs::remove_dir_all(root).unwrap();
        }
    }
}
#[cfg(unix)]
pub(crate) use local::Cache;

#[cfg(not(unix))]
pub(crate) struct Cache;
#[cfg(not(unix))]
impl Cache {
    pub(crate) fn load(_: &Path) -> Self {
        Self
    }
    pub(crate) fn matches(&mut self, path: &Path, expected: &str) -> bool {
        fs::read(path).is_ok_and(|bytes| digest_bytes(&bytes) == expected)
    }
    pub(crate) fn save(self, _: &Path) {}
}
