use std::env;
use std::io;
use std::path::PathBuf;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FrontendMode {
    Auto,
    Rust,
    Dart,
}

impl FrontendMode {
    pub(crate) fn parse(value: &str) -> io::Result<Self> {
        match value {
            "auto" => Ok(Self::Auto),
            "rust" => Ok(Self::Rust),
            "dart" => Ok(Self::Dart),
            _ => Err(io::Error::other(format!(
                "--mode must be auto, rust, or dart: {value}"
            ))),
        }
    }
}
pub(crate) struct Options {
    pub(crate) command: String,
    pub(crate) root: PathBuf,
    pub(crate) dart_binary: Option<String>,
    pub(crate) worker: Option<String>,
    pub(crate) interval_ms: u64,
    pub(crate) jobs: usize,
    pub(crate) mode: FrontendMode,
    pub(crate) background: bool,
}

impl Options {
    pub(crate) fn parse(mut args: impl Iterator<Item = String>) -> io::Result<Self> {
        let command = args.next().unwrap_or_else(|| "build".to_owned());
        let mut root = env::current_dir()?;
        let mut dart_binary = None;
        let mut worker = None;
        let mut interval_ms = 200;
        // Worker processes each carry a full analyzer instance (~1 GiB on
        // large workspaces), so the default follows the machine's parallelism
        // capped by the memory that is actually available. --jobs overrides
        // it (including down to 1 on small runners).
        let mut jobs = default_worker_count();
        let mut mode = FrontendMode::Auto;
        let mut background = false;
        while let Some(argument) = args.next() {
            match argument.as_str() {
                "--root" => {
                    root = PathBuf::from(
                        args.next()
                            .ok_or_else(|| io::Error::other("--root needs a value"))?,
                    )
                }
                "--dart" => {
                    dart_binary = Some(
                        args.next()
                            .ok_or_else(|| io::Error::other("--dart needs a value"))?,
                    )
                }
                "--worker" => {
                    worker = Some(
                        args.next()
                            .ok_or_else(|| io::Error::other("--worker needs a value"))?,
                    )
                }
                "--interval-ms" => {
                    interval_ms = args
                        .next()
                        .ok_or_else(|| io::Error::other("--interval-ms needs a value"))?
                        .parse()
                        .map_err(|_| io::Error::other("--interval-ms must be an integer"))?;
                    if interval_ms == 0 {
                        return Err(io::Error::other("--interval-ms must be greater than zero"));
                    }
                }
                "--jobs" => {
                    jobs = args
                        .next()
                        .ok_or_else(|| io::Error::other("--jobs needs a value"))?
                        .parse()
                        .map_err(|_| io::Error::other("--jobs must be an integer"))?;
                    if jobs == 0 {
                        return Err(io::Error::other("--jobs must be greater than zero"));
                    }
                }
                "--mode" => {
                    mode = FrontendMode::parse(
                        &args
                            .next()
                            .ok_or_else(|| io::Error::other("--mode needs a value"))?,
                    )?;
                }
                "--background" => background = true,
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("unknown argument: {argument}"),
                    ));
                }
            }
        }
        if background && !matches!(command.as_str(), "prewarm" | "aot-prewarm") {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("--background is only supported with prewarm: {command}"),
            ));
        }
        Ok(Self {
            command,
            root,
            dart_binary,
            worker,
            interval_ms,
            jobs,
            mode,
            background,
        })
    }
}

/// The default worker count: logical CPUs capped by available memory at
/// roughly one worker per GiB, since each Dart worker carries a full
/// analyzer instance (~1 GiB while a cold byte store is first filled).
fn default_worker_count() -> usize {
    let cpus = std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1);
    match available_memory_gib() {
        Some(gib) => {
            let capped = cpus.min((gib as usize).max(1));
            if capped < cpus {
                eprintln!(
                    "Rust defaulting --jobs to {capped} ({gib:.1} GiB available; pass --jobs to override)"
                );
            }
            capped
        }
        // No availability probe on this platform: keep the parallelism default.
        None => cpus,
    }
}

/// Available memory in GiB: Linux `MemAvailable` bounded by the process's
/// cgroup memory limit (a container can see the host's MemAvailable while
/// being limited to much less). Unlimited/unreadable cgroups fall back to
/// `MemAvailable` alone.
#[cfg(target_os = "linux")]
fn available_memory_gib() -> Option<f64> {
    let contents = std::fs::read_to_string("/proc/meminfo").ok()?;
    let line = contents
        .lines()
        .find(|line| line.starts_with("MemAvailable:"))?;
    let kb: f64 = line
        .strip_prefix("MemAvailable:")?
        .trim()
        .strip_suffix("kB")?
        .trim()
        .parse()
        .ok()?;
    let mut gib = kb / 1_048_576.0;
    if let Some(cgroup_gib) = cgroup_available_memory_gib() {
        gib = gib.min(cgroup_gib);
    }
    Some(gib)
}

/// Remaining memory under the process's cgroup limit (v2 or v1), or None
/// when the cgroup is unlimited/unreadable.
#[cfg(target_os = "linux")]
fn cgroup_available_memory_gib() -> Option<f64> {
    let (limit_file, current_file) = cgroup_memory_files()?;
    let limit = std::fs::read_to_string(limit_file).ok()?;
    let current = std::fs::read_to_string(current_file).ok()?;
    cgroup_available_bytes(&limit, &current).map(|bytes| bytes as f64 / 1_073_741_824.0)
}

/// Locates this process's cgroup memory limit/usage files, for both the
/// v2 unified hierarchy (`memory.max`/`memory.current`) and v1
/// (`memory.limit_in_bytes`/`memory.usage_in_bytes`).
#[cfg(target_os = "linux")]
fn cgroup_memory_files() -> Option<(std::path::PathBuf, std::path::PathBuf)> {
    let cgroup = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    let mountinfo = std::fs::read_to_string("/proc/self/mountinfo").ok();
    for line in cgroup.lines() {
        let mut fields = line.splitn(3, ':');
        let Some(controllers) = fields.nth(1) else {
            continue;
        };
        let path = fields.next().unwrap_or("");
        if controllers.is_empty() {
            // v2 unified hierarchy ("0::/path").
            let Some(dir) = cgroup_dir(
                path,
                "cgroup2",
                None,
                mountinfo.as_deref(),
                "/sys/fs/cgroup",
            ) else {
                continue;
            };
            return Some((dir.join("memory.max"), dir.join("memory.current")));
        }
        if controllers.split(',').any(|c| c == "memory") {
            let Some(dir) = cgroup_dir(
                path,
                "cgroup",
                Some("memory"),
                mountinfo.as_deref(),
                "/sys/fs/cgroup/memory",
            ) else {
                continue;
            };
            return Some((
                dir.join("memory.limit_in_bytes"),
                dir.join("memory.usage_in_bytes"),
            ));
        }
    }
    None
}

/// Maps a cgroup path from /proc/self/cgroup onto the mount point
/// /proc/self/mountinfo reports for the hierarchy of `fstype` (v1 mounts are
/// further matched by `controller` in their super options). Falls back to
/// the conventional sysfs location when mountinfo is unavailable or lacks
/// the mount; a mount under which the path cannot be expressed yields None
/// — appending blindly would read the hierarchy root instead of the
/// process's cgroup.
#[cfg(target_os = "linux")]
fn cgroup_dir(
    path: &str,
    fstype: &str,
    controller: Option<&str>,
    mountinfo: Option<&str>,
    fallback: &str,
) -> Option<std::path::PathBuf> {
    if let Some(info) = mountinfo {
        if let Some((root, point)) = cgroup_mount(info, fstype, controller) {
            return cgroup_dir_for(root, point, path);
        }
    }
    Some(std::path::PathBuf::from(fallback).join(path.trim_start_matches('/')))
}

/// Finds the (root, mount point) of the cgroup hierarchy of `fstype` in
/// /proc/self/mountinfo text; v1 mounts match only when `controller` appears
/// in their super options.
#[cfg(any(target_os = "linux", test))]
fn cgroup_mount<'a>(
    mountinfo: &'a str,
    fstype: &str,
    controller: Option<&str>,
) -> Option<(&'a str, &'a str)> {
    for line in mountinfo.lines() {
        let Some((before, after)) = line.split_once(" - ") else {
            continue;
        };
        let pre: Vec<&str> = before.split_whitespace().collect();
        let (Some(&root), Some(&point)) = (pre.get(3), pre.get(4)) else {
            continue;
        };
        let mut post = after.split_whitespace();
        let (Some(fs), Some(_source), Some(super_options)) =
            (post.next(), post.next(), post.next())
        else {
            continue;
        };
        if fs != fstype {
            continue;
        }
        if let Some(want) = controller {
            if !super_options.split(',').any(|opt| opt == want) {
                continue;
            }
        }
        return Some((root, point));
    }
    None
}

/// Maps a cgroup path from /proc/self/cgroup to a directory under the
/// hierarchy's mount point, given the mount's root. Returns None when the
/// path cannot be expressed under that root — the process's cgroup is then
/// not visible inside the mount, and no files exist to read.
#[cfg(any(target_os = "linux", test))]
fn cgroup_dir_for(
    mount_root: &str,
    mount_point: &str,
    cgroup_path: &str,
) -> Option<std::path::PathBuf> {
    let relative = if mount_root == "/" {
        cgroup_path
    } else if cgroup_path == mount_root {
        "/"
    } else {
        cgroup_path.strip_prefix(&format!("{mount_root}/"))?
    };
    Some(std::path::PathBuf::from(mount_point).join(relative.trim_start_matches('/')))
}

/// Effective headroom from a cgroup limit/usage pair. `max` and the v1
/// PAGE_COUNTER_MAX sentinel mean "unlimited" → None (caller falls back to
/// the host's MemAvailable).
#[cfg(any(target_os = "linux", test))]
fn cgroup_available_bytes(limit: &str, current: &str) -> Option<u64> {
    let limit = limit.trim();
    if limit == "max" {
        return None;
    }
    let limit: u64 = limit.parse().ok()?;
    if limit >= 1 << 60 {
        return None;
    }
    let current: u64 = current.trim().parse().ok()?;
    Some(limit.saturating_sub(current))
}

/// macOS has no MemAvailable-style counter; estimate it from `vm_stat`
/// (present on every macOS install) as free + inactive + speculative pages —
/// the pages that can back new allocations without swapping.
#[cfg(target_os = "macos")]
fn available_memory_gib() -> Option<f64> {
    // Invoked by absolute path so a compromised PATH cannot substitute the binary.
    let output = std::process::Command::new("/usr/bin/vm_stat").output().ok()?;
    if !output.status.success() {
        return None;
    }
    parse_vm_stat_available_gib(&String::from_utf8_lossy(&output.stdout))
}

/// Parses `vm_stat` output into an available-memory estimate in GiB.
#[cfg(any(target_os = "macos", test))]
fn parse_vm_stat_available_gib(text: &str) -> Option<f64> {
    let page_size = text
        .lines()
        .next()
        .and_then(|line| line.rsplit("page size of ").next())
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|value| value.parse::<f64>().ok())
        .unwrap_or(16384.0);
    let mut pages = 0.0;
    for stat in ["Pages free:", "Pages inactive:", "Pages speculative:"] {
        let value: f64 = text
            .lines()
            .find(|line| line.starts_with(stat))
            .and_then(|line| line[stat.len()..].trim().trim_end_matches('.').parse().ok())?;
        pages += value;
    }
    Some(pages * page_size / 1_073_741_824.0)
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn available_memory_gib() -> Option<f64> {
    None
}

#[cfg(test)]
mod tests {
    use super::{
        FrontendMode, cgroup_available_bytes, cgroup_dir_for, cgroup_mount,
        parse_vm_stat_available_gib,
    };

    #[test]
    fn frontend_mode_accepts_only_explicit_values() {
        assert_eq!(FrontendMode::parse("auto").unwrap(), FrontendMode::Auto);
        assert_eq!(FrontendMode::parse("rust").unwrap(), FrontendMode::Rust);
        assert_eq!(FrontendMode::parse("dart").unwrap(), FrontendMode::Dart);
        assert!(FrontendMode::parse("native").is_err());
    }

    #[test]
    fn background_is_scoped_to_prewarm() {
        assert!(
            super::Options::parse(["prewarm", "--background"].into_iter().map(str::to_owned))
                .unwrap()
                .background
        );
        assert!(
            super::Options::parse(
                ["aot-prewarm", "--background"]
                    .into_iter()
                    .map(str::to_owned)
            )
            .unwrap()
            .background
        );
        assert!(
            !super::Options::parse(["prewarm"].into_iter().map(str::to_owned))
                .unwrap()
                .background
        );
        assert!(
            super::Options::parse(["build", "--background"].into_iter().map(str::to_owned))
                .is_err()
        );
    }

    #[test]
    fn cgroup_dir_maps_paths_relative_to_the_mount_root() {
        // Standard case: the full hierarchy is mounted at /sys/fs/cgroup.
        assert_eq!(
            cgroup_dir_for("/", "/sys/fs/cgroup", "/docker/abc"),
            Some(std::path::PathBuf::from("/sys/fs/cgroup/docker/abc"))
        );
        // Subtree-mounted container view: the reported path is the mount root.
        assert_eq!(
            cgroup_dir_for("/docker/abc", "/sys/fs/cgroup", "/docker/abc"),
            Some(std::path::PathBuf::from("/sys/fs/cgroup"))
        );
        // Nested under the mount root maps relative to it.
        assert_eq!(
            cgroup_dir_for("/docker", "/sys/fs/cgroup", "/docker/abc/x"),
            Some(std::path::PathBuf::from("/sys/fs/cgroup/abc/x"))
        );
        // A path outside the mount root cannot be resolved.
        assert_eq!(
            cgroup_dir_for("/kubepods", "/sys/fs/cgroup", "/docker/abc"),
            None
        );
        // A shared prefix without a path boundary is not a match.
        assert_eq!(
            cgroup_dir_for("/docker/ab", "/sys/fs/cgroup", "/docker/abc"),
            None
        );
    }

    #[test]
    fn cgroup_mount_selects_v1_memory_and_v2_entries() {
        let mountinfo = "\
35 27 0:31 / /sys/fs/cgroup ro,nosuid,nodev,noexec shared:9 - cgroup2 cgroup2 rw,nsdelegate
29 27 0:25 /docker/x /sys/fs/cgroup/memory rw,nosuid,nodev,noexec shared:7 - cgroup cgroup rw,memory
";
        assert_eq!(
            cgroup_mount(mountinfo, "cgroup2", None),
            Some(("/", "/sys/fs/cgroup"))
        );
        assert_eq!(
            cgroup_mount(mountinfo, "cgroup", Some("memory")),
            Some(("/docker/x", "/sys/fs/cgroup/memory"))
        );
        assert_eq!(cgroup_mount(mountinfo, "cgroup", Some("cpu")), None);
    }

    #[test]
    fn cgroup_available_bytes_bounds_remaining_headroom() {
        // cgroup v2 "max" and the v1 PAGE_COUNTER_MAX sentinel are unlimited.
        assert_eq!(cgroup_available_bytes("max", "0"), None);
        assert_eq!(
            cgroup_available_bytes("9223372036854771712", "0"),
            None
        );
        // 4 GiB limit with 1.5 GiB used -> 2.5 GiB headroom.
        let gib = 1u64 << 30;
        assert_eq!(
            cgroup_available_bytes("4294967296", &(gib + gib / 2).to_string()),
            Some(2 * gib + gib / 2)
        );
        // Usage above the limit clamps to zero, never wraps.
        assert_eq!(cgroup_available_bytes("1024", "4096"), Some(0));
        assert_eq!(cgroup_available_bytes("not-a-number", "0"), None);
    }

    #[test]
    fn vm_stat_parse_counts_reusable_pages() {
        // `vm_stat` output shape (Apple Silicon page size = 16384).
        let text = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n\
                    Pages free:                              100000.\n\
                    Pages active:                           400000.\n\
                    Pages inactive:                         200000.\n\
                    Pages speculative:                       50000.\n\
                    Pages occupied by compressor:                 0.\n";
        let gib = parse_vm_stat_available_gib(text).unwrap();
        // (100000 + 200000 + 50000) * 16384 bytes = 5.35 GiB
        assert!((gib - 5.35).abs() < 0.01, "unexpected estimate: {gib}");
    }

    #[test]
    fn vm_stat_parse_rejects_missing_stats() {
        assert!(parse_vm_stat_available_gib("no stats").is_none());
    }
}
