//! Exclude concurrent native graph/output writers in one workspace.
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

/// An OS-held lock lives for the entire build or watch session. The lock file
/// stays in place: unlinking it could let another process lock a different inode.
pub(crate) struct WorkspaceLock {
    _files: Vec<LockedFile>,
}

/// Coordinates workspace builds with prewarm/cache-key commands without
/// preventing those commands from overlapping ordinary single-package builds.
pub(crate) struct WorkspaceCoordination {
    _file: LockedFile,
}

/// Release ownership explicitly: close alone can leave an OS lock held by a
/// duplicated descriptor, including a concurrent fork's pre-exec inheritance.
/// Wrapping each acquisition also releases partially acquired groups on error.
struct LockedFile(File);

impl Drop for LockedFile {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

impl WorkspaceCoordination {
    pub(crate) fn acquire(root: &Path, exclusive: bool) -> io::Result<Self> {
        let directory = root
            .canonicalize()?
            .join(".dart_tool/build_runner_accelerator");
        fs::create_dir_all(&directory)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join(".workspace-coordination.lock"))?;
        let result = if exclusive {
            file.try_lock()
        } else {
            file.try_lock_shared()
        };
        result.map_err(|error| match error {
            std::fs::TryLockError::WouldBlock => io::Error::new(
                io::ErrorKind::WouldBlock,
                if exclusive {
                    "workspace build conflicts with a running prewarm or cache-key command"
                } else {
                    "prewarm or cache-key command conflicts with a running workspace build"
                },
            ),
            std::fs::TryLockError::Error(error) => error,
        })?;
        Ok(Self {
            _file: LockedFile(file),
        })
    }
}

impl WorkspaceLock {
    pub(crate) fn acquire(root: &Path) -> io::Result<Self> {
        Self::acquire_all(std::iter::once(root))
    }

    /// Lock every output package using the same files as individual builds.
    /// Non-blocking acquisition and RAII release prevent partial ownership
    /// from surviving a failure. Canonicalization also deduplicates aliases.
    pub(crate) fn acquire_all<'a>(roots: impl IntoIterator<Item = &'a Path>) -> io::Result<Self> {
        let mut roots = roots
            .into_iter()
            .map(Path::canonicalize)
            .collect::<io::Result<Vec<PathBuf>>>()?;
        roots.sort();
        roots.dedup();
        if roots.is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "at least one package root is required for a workspace lock",
            ));
        }
        let mut files = Vec::with_capacity(roots.len());
        for root in roots {
            let directory = root.join(".dart_tool/build_runner_accelerator");
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
            files.push(LockedFile(file));
        }
        Ok(Self { _files: files })
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

    #[test]
    fn workspace_locks_exclude_members_and_release_partial_acquisitions() {
        let empty = WorkspaceLock::acquire_all(std::iter::empty())
            .err()
            .unwrap();
        assert_eq!(empty.kind(), io::ErrorKind::InvalidInput);
        let root = std::env::temp_dir().join(format!(
            "accelerator-workspace-lock-group-{}",
            std::process::id()
        ));
        let member = root.join("member");
        fs::create_dir_all(&member).unwrap();
        let member_lock = WorkspaceLock::acquire(&member).unwrap();
        let error = WorkspaceLock::acquire_all([root.as_path(), member.as_path()])
            .err()
            .unwrap();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        // The failed group must release any lock it acquired before the
        // conflict, and must leave the existing member lock untouched.
        let root_lock = WorkspaceLock::acquire(&root).unwrap();
        assert!(WorkspaceLock::acquire(&member).is_err());
        drop(root_lock);
        drop(member_lock);

        let workspace =
            WorkspaceLock::acquire_all([member.as_path(), root.as_path(), root.as_path()]).unwrap();
        assert!(WorkspaceLock::acquire(&root).is_err());
        assert!(WorkspaceLock::acquire(&member).is_err());
        drop(workspace);
        assert!(WorkspaceLock::acquire(&member).is_ok());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn workspace_coordination_allows_parallel_prewarm_but_excludes_workspace_build() {
        let root =
            std::env::temp_dir().join(format!("accelerator-coordination-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let first = WorkspaceCoordination::acquire(&root, false).unwrap();
        let second = WorkspaceCoordination::acquire(&root, false).unwrap();
        assert!(WorkspaceCoordination::acquire(&root, true).is_err());
        drop(first);
        drop(second);
        let exclusive = WorkspaceCoordination::acquire(&root, true).unwrap();
        assert!(WorkspaceCoordination::acquire(&root, false).is_err());
        drop(exclusive);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn dropping_the_owner_releases_locks_even_while_a_descriptor_is_duplicated() {
        let root =
            std::env::temp_dir().join(format!("accelerator-lock-duplicate-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let owner = WorkspaceLock::acquire(&root).unwrap();
        // A process forked by another test can briefly inherit this open file
        // description before exec closes its CLOEXEC descriptor.
        let inherited = owner._files[0].0.try_clone().unwrap();
        drop(owner);
        let next = WorkspaceLock::acquire(&root).expect("the owner released its lock");
        drop(next);
        drop(inherited);

        let owner = WorkspaceCoordination::acquire(&root, false).unwrap();
        let inherited = owner._file.0.try_clone().unwrap();
        drop(owner);
        let next = WorkspaceCoordination::acquire(&root, true)
            .expect("the shared owner released its lock");
        drop(next);
        drop(inherited);
        fs::remove_dir_all(root).unwrap();
    }
}
