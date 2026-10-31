//! Local digest reuse. Expected digests still come from AOT metadata.
use crate::digest::digest_bytes;
use std::{fs, path::Path};

#[cfg(unix)]
mod local {
    use super::*;
    use crate::file_stamp::{Stamp, stamp};
    use serde::{Deserialize, Serialize};
    use std::{
        collections::{BTreeMap, BTreeSet},
        path::PathBuf,
    };

    const RECEIPT: &str = ".dart_tool/build_runner_accelerator/aot-validation-digests.json";

    #[derive(Default, Deserialize, Serialize)]
    struct Receipt {
        // The schema is independently versioned from portable AOT metadata.
        revision: u32,
        files: BTreeMap<PathBuf, (Stamp, String)>,
    }

    pub(crate) struct Cache {
        receipt: Receipt,
        changed: bool,
        used: BTreeSet<PathBuf>,
    }

    impl Cache {
        pub(crate) fn load(root: &Path) -> Self {
            let receipt = fs::read(root.join(RECEIPT))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Receipt>(&bytes).ok())
                .filter(|receipt| receipt.revision == 1)
                .unwrap_or(Receipt {
                    revision: 1,
                    ..Receipt::default()
                });
            Self {
                receipt,
                changed: false,
                used: BTreeSet::new(),
            }
        }

        pub(crate) fn matches(&mut self, path: &Path, expected: &str) -> bool {
            let receipt = &mut self.receipt;
            self.used.insert(path.to_owned());
            let before = stamp(path).ok();
            if let Some(before) = before
                && receipt
                    .files
                    .get(path)
                    .is_some_and(|(old, digest)| *old == before && digest == expected)
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
                receipt.files.insert(path.to_owned(), (before, actual));
                self.changed = true;
            }
            true
        }

        pub(crate) fn save(mut self, root: &Path) {
            if !self.changed {
                return;
            }
            self.receipt
                .files
                .retain(|path, _| self.used.contains(path));
            let Ok(bytes) = serde_json::to_vec(&self.receipt) else {
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
            let mut cache = Cache::load(&root);
            assert!(cache.matches(&path, &digest));
            cache.save(&root);
            let mut cache = Cache::load(&root);
            assert!(cache.matches(&path, &digest));
            assert!(!cache.changed);
            let mtime = fs::metadata(&path).unwrap().modified().unwrap();
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
            fs::write(root.join(RECEIPT), "incomplete").unwrap();
            assert!(!Cache::load(&root).matches(&path, &digest));
            fs::write(&path, "before").unwrap();
            assert!(Cache::load(&root).matches(&path, &digest));
            fs::remove_file(root.join(RECEIPT)).unwrap();
            assert!(Cache::load(&root).matches(&path, &digest));
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
