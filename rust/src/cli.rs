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
        let mut jobs = 1;
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

#[cfg(test)]
mod tests {
    use super::FrontendMode;

    #[test]
    fn frontend_mode_accepts_only_explicit_values() {
        assert_eq!(FrontendMode::parse("auto").unwrap(), FrontendMode::Auto);
        assert_eq!(FrontendMode::parse("rust").unwrap(), FrontendMode::Rust);
        assert_eq!(FrontendMode::parse("dart").unwrap(), FrontendMode::Dart);
        assert!(FrontendMode::parse("native").is_err());
    }
}
