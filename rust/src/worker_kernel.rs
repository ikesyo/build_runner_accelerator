use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Select an explicitly configured kernel, or prepare a cache for a generated
/// Dart worker when the caller opted into the default worker path.
pub(crate) fn resolve_worker_kernel(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
    auto: bool,
) -> io::Result<Option<PathBuf>> {
    if let Some(kernel) = configured_worker_kernel()? {
        return Ok(Some(kernel));
    }
    if !auto || !is_dart_source(worker_executable) {
        return Ok(None);
    }

    match prepare_worker_kernel(root, dart_binary, worker_executable) {
        Ok(kernel) => Ok(Some(kernel)),
        Err(error) => {
            eprintln!(
                "Rust worker kernel cache unavailable; using Dart script ({error})"
            );
            Ok(None)
        }
    }
}

fn is_dart_source(worker_executable: &str) -> bool {
    Path::new(worker_executable)
        .extension()
        .and_then(|extension| extension.to_str())
        == Some("dart")
}

fn configured_worker_kernel() -> io::Result<Option<PathBuf>> {
    let Some(value) = env::var_os("FAST_BUILD_RUNNER_WORKER_KERNEL") else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if !path.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "FAST_BUILD_RUNNER_WORKER_KERNEL is not a file: {}",
                path.display()
            ),
        ));
    }
    Ok(Some(fs::canonicalize(path)?))
}

fn prepare_worker_kernel(
    root: &Path,
    dart_binary: &str,
    worker_executable: &str,
) -> io::Result<PathBuf> {
    let worker_path = absolute_worker_path(root, Path::new(worker_executable))?;
    let kernel_path = worker_path.with_extension("dill");
    let depfile_path = PathBuf::from(format!("{}.d", kernel_path.display()));
    if worker_kernel_is_current(&kernel_path, &depfile_path, &worker_path) {
        return fs::canonicalize(kernel_path);
    }

    let process_id = std::process::id();
    let temp_kernel = temporary_sibling(&kernel_path, process_id, "dill");
    let temp_depfile = temporary_sibling(&depfile_path, process_id, "d");
    let package_config = root.join(".dart_tool/package_config.json");
    let status = Command::new(dart_binary)
        .args(["--suppress-analytics", "compile", "kernel"])
        .arg("--no-embed-sources")
        .arg(format!("--packages={}", package_config.display()))
        .arg(format!("--depfile={}", temp_depfile.display()))
        .arg(&worker_path)
        .arg("-o")
        .arg(&temp_kernel)
        .current_dir(root)
        .status()
        .map_err(|error| kernel_compile_error(&worker_path, error))?;
    if !status.success() {
        remove_if_present(&temp_kernel);
        remove_if_present(&temp_depfile);
        return Err(kernel_compile_status_error(&worker_path, status));
    }

    // Publish the dependency list before the kernel. If the second rename is
    // interrupted, the old kernel is conservatively treated as stale.
    replace_file(&temp_depfile, &depfile_path)?;
    replace_file(&temp_kernel, &kernel_path)?;
    fs::canonicalize(kernel_path)
}

fn absolute_worker_path(root: &Path, worker_path: &Path) -> io::Result<PathBuf> {
    let path = if worker_path.is_absolute() {
        worker_path.to_path_buf()
    } else {
        root.join(worker_path)
    };
    fs::canonicalize(path)
}

fn worker_kernel_is_current(kernel: &Path, depfile: &Path, worker: &Path) -> bool {
    let Ok(kernel_modified) = fs::metadata(kernel).and_then(|metadata| metadata.modified()) else {
        return false;
    };
    let Ok(contents) = fs::read_to_string(depfile) else {
        return false;
    };
    let Some(dependencies) = parse_depfile_dependencies(&contents) else {
        return false;
    };
    dependencies.iter().any(|path| path == worker)
        && dependencies.iter().all(|path| {
            fs::metadata(path)
                .and_then(|metadata| metadata.modified())
                .is_ok_and(|modified| modified <= kernel_modified)
        })
}

fn parse_depfile_dependencies(contents: &str) -> Option<Vec<PathBuf>> {
    let mut logical = String::with_capacity(contents.len());
    let mut characters = contents.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\\' {
            match characters.peek() {
                Some('\n') => {
                    characters.next();
                    logical.push(' ');
                    continue;
                }
                Some('\r') => {
                    characters.next();
                    if characters.peek() == Some(&'\n') {
                        characters.next();
                    }
                    logical.push(' ');
                    continue;
                }
                _ => {}
            }
        }
        logical.push(character);
    }

    let separator = logical
        .find(": ")
        .or_else(|| logical.find(':'))?;
    let dependencies = make_words(&logical[separator + 1..]);
    (!dependencies.is_empty()).then_some(dependencies.into_iter().map(PathBuf::from).collect())
}

fn make_words(value: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut escaped = false;
    for character in value.chars() {
        if escaped {
            word.push(character);
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character.is_whitespace() {
            if !word.is_empty() {
                words.push(std::mem::take(&mut word));
            }
        } else {
            word.push(character);
        }
    }
    if escaped {
        word.push('\\');
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

fn temporary_sibling(path: &Path, process_id: u32, extension: &str) -> PathBuf {
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("worker-cache");
    path.with_file_name(format!(".{filename}.{process_id}.tmp.{extension}"))
}

fn replace_file(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    if destination.exists() {
        fs::remove_file(destination)?;
    }
    fs::rename(source, destination)
}

fn remove_if_present(path: &Path) {
    let _ = fs::remove_file(path);
}

fn kernel_compile_error(worker: &Path, error: io::Error) -> io::Error {
    io::Error::new(
        error.kind(),
        format!("failed to compile worker kernel for {}: {error}", worker.display()),
    )
}

fn kernel_compile_status_error(worker: &Path, status: std::process::ExitStatus) -> io::Error {
    io::Error::other(format!(
        "worker kernel compilation exited with {status}: {}",
        worker.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::parse_depfile_dependencies;
    use std::path::PathBuf;

    #[test]
    fn depfile_parser_handles_continuations_and_escaped_spaces() {
        let depfile = concat!(
            "/tmp/worker.dill: /tmp/package_config.json /tmp/path\\ with\\ spaces.dart \\\n",
            " /tmp/other.dart\n",
        );
        let dependencies = parse_depfile_dependencies(depfile).expect("dependencies");
        assert_eq!(
            dependencies,
            vec![
                PathBuf::from("/tmp/package_config.json"),
                PathBuf::from("/tmp/path with spaces.dart"),
                PathBuf::from("/tmp/other.dart"),
            ]
        );
    }
}
