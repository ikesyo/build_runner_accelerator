//! Exclude concurrent native graph/output writers in one workspace.
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::Path;

/// An OS-held lock lives for the entire build or watch session. The lock file
/// stays in place: unlinking it could let another process lock a different inode.
pub(crate) struct WorkspaceLock {
    _file: File,
}

impl WorkspaceLock {
    pub(crate) fn acquire(root: &Path) -> io::Result<Self> {
        let directory = root
            .canonicalize()?
            .join(".dart_tool/build_runner_accelerator");
        fs::create_dir_all(&directory)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join(".workspace.lock"))?;
        file.try_lock().map_err(|error| match error {
            std::fs::TryLockError::WouldBlock => io::Error::new(
                io::ErrorKind::WouldBlock,
                format!(
                    "native workspace writer lock is already held for {}; stop the existing build/watch before starting another",
                    root.display()
                ),
            ),
            std::fs::TryLockError::Error(error) => error,
        })?;
        Ok(Self { _file: file })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn competing_writer_is_rejected_and_drop_releases_lock() {
        let root =
            std::env::temp_dir().join(format!("accelerator-writer-lock-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let first = WorkspaceLock::acquire(&root).unwrap();
        let error = WorkspaceLock::acquire(&root).err().unwrap();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        drop(first);
        let second = WorkspaceLock::acquire(&root).unwrap();
        drop(second);
        fs::remove_dir_all(root).unwrap();
    }
}
