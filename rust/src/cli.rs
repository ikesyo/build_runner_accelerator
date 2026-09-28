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
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("unknown argument: {argument}"),
                    ))
                }
            }
        }
        Ok(Self {
            command,
            root,
            dart_binary,
            worker,
            interval_ms,
            jobs,
            mode,
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
    let mounts = std::fs::read_to_string("/proc/self/cgroup").ok()?;
    for line in mounts.lines() {
        let mut fields = line.splitn(3, ':');
        let _hierarchy = fields.next();
        let Some(controllers) = fields.next() else {
            continue;
        };
        let path = fields.next().unwrap_or("");
        if controllers.is_empty() {
            // v2 unified hierarchy ("0::/path").
            return Some((
                format!("/sys/fs/cgroup{path}/memory.max").into(),
                format!("/sys/fs/cgroup{path}/memory.current").into(),
            ));
        }
        if controllers.split(',').any(|c| c == "memory") {
            return Some((
                format!("/sys/fs/cgroup/memory{path}/memory.limit_in_bytes").into(),
                format!("/sys/fs/cgroup/memory{path}/memory.usage_in_bytes").into(),
            ));
        }
    }
    None
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
    use super::{FrontendMode, cgroup_available_bytes, parse_vm_stat_available_gib};

    #[test]
    fn frontend_mode_accepts_only_explicit_values() {
        assert_eq!(FrontendMode::parse("auto").unwrap(), FrontendMode::Auto);
        assert_eq!(FrontendMode::parse("rust").unwrap(), FrontendMode::Rust);
        assert_eq!(FrontendMode::parse("dart").unwrap(), FrontendMode::Dart);
        assert!(FrontendMode::parse("native").is_err());
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
