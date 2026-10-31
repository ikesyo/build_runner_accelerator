//! Strong local filesystem change stamps for disposable validation caches.
#![cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::{fs, io, path::Path};

pub(crate) type Stamp = [u64; 8];

pub(crate) fn stamp(path: &Path) -> io::Result<Stamp> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_file() && !m.is_dir() {
        return Err(io::Error::other("unsupported link in validation snapshot"));
    }
    Ok([
        m.dev(),
        m.ino(),
        u64::from(m.mode()),
        m.size(),
        m.mtime() as u64,
        m.mtime_nsec() as u64,
        m.ctime() as u64,
        m.ctime_nsec() as u64,
    ])
}
