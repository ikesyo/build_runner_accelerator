//! Linux-only shared-memory transport used by the read-path PoC.
//!
//! The file-backed mapping is deliberately small and private to one worker.
//! The pipe still carries the request and a response header; only the read
//! payload bypasses the pipe. This keeps the experiment easy to disable and
//! preserves the existing protocol as the fallback.

pub const ENV_ENABLED: &str = "BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY";
pub const ENV_PATH: &str = "BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY_PATH";
pub const ENV_CAPACITY: &str = "BUILD_RUNNER_ACCELERATOR_READ_SHARED_MEMORY_CAPACITY";
pub const CAPABILITY: &str = "asset-rpc-shared-memory-read-v1";

#[cfg(target_os = "linux")]
mod platform {
    use super::{ENV_CAPACITY, ENV_ENABLED, ENV_PATH};
    use std::env;
    use std::ffi::c_void;
    use std::fs::{self, File, OpenOptions};
    use std::io;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    use std::path::PathBuf;
    use std::process::Command;
    use std::ptr;
    use std::time::{SystemTime, UNIX_EPOCH};

    const DEFAULT_CAPACITY: usize = 16 * 1024 * 1024;
    const PROT_READ: i32 = 0x1;
    const PROT_WRITE: i32 = 0x2;
    const MAP_SHARED: i32 = 0x1;

    #[link(name = "c")]
    unsafe extern "C" {
        fn mmap(
            address: *mut c_void,
            length: usize,
            protection: i32,
            flags: i32,
            file_descriptor: i32,
            offset: i64,
        ) -> *mut c_void;
        fn munmap(address: *mut c_void, length: usize) -> i32;
    }

    pub struct ReadSharedMemory {
        address: usize,
        capacity: usize,
        _file: File,
        path: PathBuf,
    }

    impl ReadSharedMemory {
        pub fn from_environment() -> io::Result<Option<Self>> {
            if env::var(ENV_ENABLED).as_deref() != Ok("1") {
                return Ok(None);
            }

            let capacity = env::var(ENV_CAPACITY)
                .ok()
                .map(|value| {
                    value.parse::<usize>().map_err(|_| {
                        io::Error::new(
                            io::ErrorKind::InvalidInput,
                            format!("{ENV_CAPACITY} must be a positive integer"),
                        )
                    })
                })
                .transpose()?
                .unwrap_or(DEFAULT_CAPACITY);
            if capacity == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("{ENV_CAPACITY} must be positive"),
                ));
            }

            let path = unique_path();
            let file = OpenOptions::new()
                .create_new(true)
                .read(true)
                .write(true)
                .mode(0o600)
                .open(&path)?;
            if let Err(error) = file.set_len(capacity as u64) {
                let _ = fs::remove_file(&path);
                return Err(error);
            }

            // SAFETY: the file is kept open for the mapping's lifetime and is
            // exactly `capacity` bytes long.
            let address = unsafe {
                mmap(
                    ptr::null_mut(),
                    capacity,
                    PROT_READ | PROT_WRITE,
                    MAP_SHARED,
                    file.as_raw_fd(),
                    0,
                )
            };
            if address as isize == -1 {
                let error = io::Error::last_os_error();
                let _ = fs::remove_file(&path);
                return Err(error);
            }

            Ok(Some(Self {
                address: address as usize,
                capacity,
                _file: file,
                path,
            }))
        }

        pub fn configure_command(&self, command: &mut Command) {
            command
                .env(ENV_PATH, &self.path)
                .env(ENV_CAPACITY, self.capacity.to_string());
        }

        pub fn write(&self, bytes: &[u8]) -> io::Result<bool> {
            if bytes.len() > self.capacity {
                return Ok(false);
            }
            // SAFETY: the mapping is writable and has room for `bytes`.
            unsafe {
                ptr::copy_nonoverlapping(bytes.as_ptr(), self.address as *mut u8, bytes.len());
            }
            Ok(true)
        }
    }

    impl Drop for ReadSharedMemory {
        fn drop(&mut self) {
            // SAFETY: this is the address and length returned by mmap.
            unsafe {
                let _ = munmap(self.address as *mut c_void, self.capacity);
            }
            let _ = fs::remove_file(&self.path);
        }
    }

    fn unique_path() -> PathBuf {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        env::temp_dir().join(format!(
            "build-runner-accelerator-read-{}-{timestamp}.shm",
            std::process::id()
        ))
    }
}

#[cfg(not(target_os = "linux"))]
mod platform {
    use super::{ENV_ENABLED, ENV_PATH};
    use std::io;
    use std::process::Command;

    pub struct ReadSharedMemory;

    impl ReadSharedMemory {
        pub fn from_environment() -> io::Result<Option<Self>> {
            if std::env::var(ENV_ENABLED).as_deref() == Ok("1") {
                return Err(io::Error::new(
                    io::ErrorKind::Unsupported,
                    "read shared memory PoC is only available on Linux",
                ));
            }
            Ok(None)
        }

        pub fn configure_command(&self, _command: &mut Command) {
            let _ = ENV_PATH;
        }

        pub fn write(&self, _bytes: &[u8]) -> io::Result<bool> {
            Ok(false)
        }
    }
}

pub use platform::ReadSharedMemory;
