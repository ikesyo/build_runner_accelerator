use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

/// Owned until every reset RPC has joined, including errors. Never reused.
pub(super) struct OverlayBlob {
    path: PathBuf,
    pub metadata: Value,
}
impl OverlayBlob {
    /// Writes available updated values into a new reset-owned blob.
    /// Publication follows successful writes/flush/close; dropping removes it.
    pub fn create(
        root: &Path,
        overlay: &BTreeMap<String, Vec<u8>>,
        updated: &BTreeSet<String>,
    ) -> io::Result<Self> {
        Self::create_with(root, overlay, updated, |file, bytes| file.write_all(bytes))
    }
    /// Allows injected write failures while preserving partial-file cleanup.
    fn create_with(
        root: &Path,
        overlay: &BTreeMap<String, Vec<u8>>,
        updated: &BTreeSet<String>,
        mut write: impl FnMut(&mut fs::File, &[u8]) -> io::Result<()>,
    ) -> io::Result<Self> {
        let dir = root.join(".dart_tool/build_runner_accelerator/overlay-blobs");
        fs::create_dir_all(&dir)?;
        let (path, mut file) = loop {
            let path = dir.join(format!(
                "{}-{}.blob",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => break (path, file),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        };
        let mut blob = Self {
            path,
            metadata: Value::Null,
        };
        let result: io::Result<Value> = (|| {
            let mut index = BTreeMap::new();
            let mut length = 0u64;
            for asset in updated {
                if let Some(bytes) = overlay.get(asset) {
                    write(&mut file, bytes)?;
                    index.insert(asset, json!({"offset": length, "length": bytes.len()}));
                    length = length
                        .checked_add(bytes.len() as u64)
                        .ok_or_else(|| io::Error::other("overlay blob length overflow"))?;
                }
            }
            file.flush()?;
            Ok(json!({"path": blob.path, "length": length, "index": index}))
        })();
        // Close before propagating errors and unlinking the partial blob,
        // including on platforms that cannot unlink an open file.
        drop(file);
        blob.metadata = result?;
        Ok(blob)
    }
}
impl Drop for OverlayBlob {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn root() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "bra-blob-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }
    #[test]
    fn snapshot_update_delete_recreate_and_empty() {
        let root = root();
        let a = "app|lib/a.dart".to_string();
        let b = "app|lib/b.part".to_string();
        let updated = BTreeSet::from([a.clone(), b.clone()]);
        let mut overlay = BTreeMap::from([(a.clone(), vec![1, 2]), (b.clone(), vec![3])]);
        let first = OverlayBlob::create(&root, &overlay, &updated).unwrap();
        assert_eq!(fs::read(&first.path).unwrap(), [1, 2, 3]);
        assert_eq!(first.metadata["index"][&b]["offset"], 2);
        overlay.remove(&a);
        let second = OverlayBlob::create(&root, &overlay, &updated).unwrap();
        assert!(second.metadata["index"].get(&a).is_none());
        assert_eq!(fs::read(&first.path).unwrap(), [1, 2, 3]); // immutable
        overlay.insert(a.clone(), vec![9]);
        let third = OverlayBlob::create(&root, &overlay, &updated).unwrap();
        assert_eq!(fs::read(&third.path).unwrap(), [9, 3]);
        let empty = OverlayBlob::create(&root, &overlay, &BTreeSet::new()).unwrap();
        assert_eq!(empty.metadata["length"], 0);
        let paths = [
            first.path.clone(),
            second.path.clone(),
            third.path.clone(),
            empty.path.clone(),
        ];
        drop((first, second, third, empty));
        assert!(paths.iter().all(|p| !p.exists()));
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn incomplete_write_cleans_up_and_recovers() {
        let root = root();
        let overlay = BTreeMap::from([("app|a".into(), vec![1, 2, 3])]);
        let updated = overlay.keys().cloned().collect();
        let failed = OverlayBlob::create_with(&root, &overlay, &updated, |file, bytes| {
            file.write_all(&bytes[..1])?;
            Err(io::Error::other("injected write failure"))
        });
        assert!(failed.is_err());
        assert_eq!(
            fs::read_dir(root.join(".dart_tool/build_runner_accelerator/overlay-blobs"))
                .unwrap()
                .count(),
            0
        );
        let recovered = OverlayBlob::create(&root, &overlay, &updated).unwrap();
        assert_eq!(fs::read(&recovered.path).unwrap(), [1, 2, 3]);
        drop(recovered);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn directory_failure_never_publishes() {
        let root = root();
        fs::write(root.join(".dart_tool"), b"blocked").unwrap();
        assert!(OverlayBlob::create(&root, &BTreeMap::new(), &BTreeSet::new()).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
