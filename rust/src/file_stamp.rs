//! Strong local filesystem change stamps for disposable validation caches.
#![cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::{fs, io, path::Path};

pub(crate) type Stamp = [u64; 8];

/// Read a change stamp without following symlinks.
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

/// Snapshot kernel mount types once per validation. Supported local and overlay
/// mounts may reuse coherent timestamps; direct remote, FUSE and unknown mounts
/// rehash. Overlay backing layers must follow the documented local contract.
/// Mount-table reads are local and do not issue remote statfs RPCs.
pub(crate) fn reusable_devices(root: &Path) -> Option<std::collections::BTreeSet<u64>> {
    let _wall = crate::wall::Span::new("aot_filesystem_policy");
    #[cfg(target_os = "linux")]
    {
        let devices = local_devices(&fs::read_to_string("/proc/self/mountinfo").ok()?)?;
        devices.contains(&stamp(root).ok()?[0]).then_some(devices)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = root;
        None
    }
}

#[cfg(target_os = "linux")]
fn local_devices(mounts: &str) -> Option<std::collections::BTreeSet<u64>> {
    let mut devices = std::collections::BTreeMap::new();
    for line in mounts.lines() {
        let (fields, filesystem) = line.split_once(" - ")?;
        let (major, minor) = fields.split_whitespace().nth(2)?.split_once(':')?;
        let device = libc::makedev(major.parse().ok()?, minor.parse().ok()?);
        // Supported metadata contracts; ordinary OverlayFS uses local backing.
        let local = matches!(
            filesystem.split_whitespace().next()?,
            "ext2" | "ext3" | "ext4" | "xfs" | "btrfs" | "tmpfs" | "overlay"
        );
        // Ambiguous device identities never enable reuse.
        devices
            .entry(device)
            .and_modify(|allowed| *allowed &= local)
            .or_insert(local);
    }
    Some(
        devices
            .into_iter()
            .filter_map(|(dev, local)| local.then_some(dev))
            .collect(),
    )
}

/// Keep recently written files out of the reuse window, including coarse ticks.
pub(crate) const STAMP_SETTLE: std::time::Duration = std::time::Duration::from_secs(2);

/// Require old timestamps and sub-second change-time evidence. Whole-second
/// ctime cannot establish adequate precision and always falls back to hashing.
/// Future, invalid or unrepresentable timestamps also fail closed.
pub(crate) fn is_settled(stamp: &Stamp, now: std::time::SystemTime) -> bool {
    use std::time::{Duration, UNIX_EPOCH};
    let old = |seconds, nanos| {
        if nanos >= 1_000_000_000 {
            return false;
        }
        UNIX_EPOCH
            .checked_add(Duration::new(seconds, nanos as u32))
            .and_then(|time| now.duration_since(time).ok())
            .is_some_and(|age| age > STAMP_SETTLE)
    };
    stamp[7] != 0 && old(stamp[4], stamp[5]) && old(stamp[6], stamp[7])
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    #[cfg(target_os = "linux")]
    #[test]
    fn mount_policy_rejects_remote_unknown_ambiguous_and_malformed_entries() {
        let mounts = "1 0 0:1 / /tmp rw - tmpfs tmpfs rw\n2 0 0:2 / /net rw - nfs4 server:/export rw\n3 0 0:3 / /overlay rw - overlay overlay rw\n4 0 0:4 / /fuse rw - fuse.sshfs remote rw\n5 0 0:5 / /disk rw - ext4 /dev/disk rw\n6 0 0:5 / /ambiguous rw - nfs server rw\n7 0 0:6 / /xfs rw - xfs /dev/x rw\n8 0 0:7 / /btrfs rw - btrfs /dev/b rw\n9 0 0:8 / /unknown rw - unknown disk rw\n10 0 0:9 / /cifs rw - cifs server rw\n";
        let devices = local_devices(mounts).unwrap();
        assert_eq!(
            devices,
            [1, 3, 6, 7]
                .into_iter()
                .map(|minor| libc::makedev(0, minor))
                .collect()
        );
        assert!(local_devices("malformed").is_none());
        assert!(local_devices("1 0 invalid / / rw - ext4 disk rw").is_none());
    }

    #[test]
    fn settled_stamps_reject_recent_future_invalid_and_whole_second_times() {
        let now = UNIX_EPOCH + Duration::new(100, 100_000_000);
        let mut stamp = [0, 0, 0, 0, 97, 100_000_000, 97, 100_000_000];
        assert!(is_settled(&stamp, now));
        stamp[6] = 98; // Exactly the margin is still unsettled.
        assert!(!is_settled(&stamp, now));
        stamp[6] = 101;
        assert!(!is_settled(&stamp, now));
        stamp[6] = 97;
        stamp[4] = 99;
        assert!(!is_settled(&stamp, now));
        stamp[4] = 97;
        stamp[7] = 0; // Coarse whole-second ctime: never reuse.
        assert!(!is_settled(&stamp, now));
        stamp[7] = 1_000_000_000;
        assert!(!is_settled(&stamp, now));
        stamp[7] = 100_000_000;
        stamp[6] = u64::MAX;
        assert!(!is_settled(&stamp, now));
    }
}
