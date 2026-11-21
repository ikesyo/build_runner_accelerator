//! Open-file-description locks for worker isolates sharing this Linux process.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{LazyLock, Mutex};

use super::take_buffer;

const OPEN_ERROR: i64 = 4096;

struct WorkerLock {
    worker: u64,
    _file: OwnedFd,
}

static LOCKS: LazyLock<Mutex<HashMap<i64, WorkerLock>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_LOCK: AtomicI64 = AtomicI64::new(1);

fn open_lock(path: &CStr) -> io::Result<OwnedFd> {
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDWR | libc::O_CREAT | libc::O_CLOEXEC,
            0o666,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn lock_file(file: &OwnedFd, operation: libc::c_int) -> io::Result<()> {
    let mut lock: libc::flock = unsafe { std::mem::zeroed() };
    lock.l_type = libc::F_WRLCK as _;
    lock.l_whence = libc::SEEK_SET as _;
    // A zero range length locks the whole file, including future appends.
    if unsafe { libc::fcntl(file.as_raw_fd(), operation, &lock) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn errno(error: io::Error) -> i64 {
    i64::from(error.raw_os_error().unwrap_or(libc::EIO))
}

#[unsafe(no_mangle)]
unsafe extern "C" fn bra_spike_cache_lock(worker: u64, path: *mut u8, length: usize) -> i64 {
    let bytes = unsafe { take_buffer(path, length) };
    let Ok(path) = CString::new(bytes.into_vec()) else {
        return -OPEN_ERROR - i64::from(libc::EINVAL);
    };
    let file = match open_lock(&path) {
        Ok(file) => file,
        Err(error) => return -OPEN_ERROR - errno(error),
    };
    // OFD locks contend with traditional POSIX locks on the same inode.
    if let Err(error) = lock_file(&file, libc::F_OFD_SETLK) {
        return -errno(error);
    }
    let token = NEXT_LOCK.fetch_add(1, Ordering::Relaxed);
    LOCKS.lock().unwrap().insert(
        token,
        WorkerLock {
            worker,
            _file: file,
        },
    );
    token
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_cache_unlock(worker: u64, token: i64) {
    let mut locks = LOCKS.lock().unwrap();
    if locks.get(&token).is_some_and(|lock| lock.worker == worker) {
        locks.remove(&token);
    }
}

#[unsafe(no_mangle)]
extern "C" fn bra_spike_release_worker_locks(worker: u64) {
    LOCKS
        .lock()
        .unwrap()
        .retain(|_, lock| lock.worker != worker);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;

    #[test]
    fn releasing_a_worker_drops_only_its_locks() {
        let path = std::env::temp_dir().join(format!("bra-ofd-owner-{}", std::process::id()));
        let acquire = |worker| {
            let bytes = path.as_os_str().as_bytes().to_vec().into_boxed_slice();
            let length = bytes.len();
            unsafe { bra_spike_cache_lock(worker, Box::into_raw(bytes).cast(), length) }
        };
        let owner = acquire(1);
        assert!(owner > 0);
        assert_eq!(acquire(2), -i64::from(libc::EAGAIN));
        bra_spike_cache_unlock(2, owner);
        assert_eq!(acquire(2), -i64::from(libc::EAGAIN));

        bra_spike_release_worker_locks(1);
        let contender = acquire(2);
        assert!(contender > 0);
        bra_spike_release_worker_locks(1);
        assert_eq!(acquire(1), -i64::from(libc::EAGAIN));
        bra_spike_cache_unlock(2, contender);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn descriptor_locks_contend_and_survive_unrelated_descriptor_close() {
        let path = std::env::temp_dir().join(format!("bra-ofd-test-{}", std::process::id()));
        let name = CString::new(path.as_os_str().as_bytes()).unwrap();
        let owner = open_lock(&name).unwrap();
        lock_file(&owner, libc::F_OFD_SETLK).unwrap();
        drop(open_lock(&name).unwrap());

        let other = open_lock(&name).unwrap();
        for operation in [libc::F_OFD_SETLK, libc::F_SETLK] {
            let code = lock_file(&other, operation).unwrap_err().raw_os_error();
            assert!(
                matches!(code, Some(libc::EAGAIN | libc::EACCES)),
                "{code:?}"
            );
        }
        drop(owner);

        lock_file(&other, libc::F_SETLK).unwrap();
        let contender = open_lock(&name).unwrap();
        let code = lock_file(&contender, libc::F_OFD_SETLK)
            .unwrap_err()
            .raw_os_error();
        assert!(
            matches!(code, Some(libc::EAGAIN | libc::EACCES)),
            "{code:?}"
        );
        drop(other);
        lock_file(&contender, libc::F_OFD_SETLK).unwrap();
        drop(contender);
        std::fs::remove_file(path).unwrap();
    }
}
