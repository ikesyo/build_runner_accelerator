//! Exclude concurrent native graph/output writers in one workspace.
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::Path;

#[cfg(unix)]
const F_GETFD: std::os::raw::c_int = 1;
#[cfg(unix)]
const F_SETFD: std::os::raw::c_int = 2;
#[cfg(unix)]
const FD_CLOEXEC: std::os::raw::c_int = 1;

#[cfg(unix)]
unsafe extern "C" {
    fn fcntl(fd: std::os::raw::c_int, command: std::os::raw::c_int, ...) -> std::os::raw::c_int;
}

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

    /// Allow the lock descriptor to survive only the immediate late-fallback
    /// exec. It remains close-on-exec during native startup and worker launch.
    #[cfg(unix)]
    pub(crate) fn exec(&self, command: &mut std::process::Command) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        use std::os::unix::process::CommandExt;

        let fd = self._file.as_raw_fd();
        // SAFETY: this borrow keeps the descriptor open throughout exec and
        // restoration; fcntl only reads or updates this descriptor's flags.
        let flags = unsafe { fcntl(fd, F_GETFD, 0) };
        if flags == -1 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { fcntl(fd, F_SETFD, flags & !FD_CLOEXEC) } == -1 {
            return Err(io::Error::last_os_error());
        }
        let exec_error = command.exec();
        if unsafe { fcntl(fd, F_SETFD, flags) } == -1 {
            let restore_error = io::Error::last_os_error();
            return Err(io::Error::new(
                restore_error.kind(),
                format!(
                    "failed to restore workspace lock descriptor after stock exec failed ({exec_error}): {restore_error}"
                ),
            ));
        }
        Err(exec_error)
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

    #[cfg(unix)]
    #[test]
    fn failed_exec_restores_descriptor_flags_and_keeps_lock() {
        use std::os::fd::AsRawFd;

        let root = std::env::temp_dir().join(format!(
            "accelerator-writer-lock-exec-{}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        let lock = WorkspaceLock::acquire(&root).unwrap();
        let flags = || {
            // SAFETY: the descriptor belongs to the live `lock` value.
            let result = unsafe { fcntl(lock._file.as_raw_fd(), F_GETFD, 0) };
            assert_ne!(result, -1, "fcntl(F_GETFD): {}", io::Error::last_os_error());
            result
        };
        assert_ne!(flags() & FD_CLOEXEC, 0);
        let error = lock
            .exec(&mut std::process::Command::new(
                root.join("missing-executable"),
            ))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert_ne!(flags() & FD_CLOEXEC, 0);
        assert_eq!(
            WorkspaceLock::acquire(&root).err().unwrap().kind(),
            io::ErrorKind::WouldBlock
        );
        drop(lock);
        fs::remove_dir_all(root).unwrap();
    }
}
