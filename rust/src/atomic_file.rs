use std::fs;
use std::io;
use std::path::Path;

pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("output has no parent"))?;
    fs::create_dir_all(parent)?;
    if path.is_file() && fs::read(path)? == bytes {
        return Ok(());
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("output");
    let temporary = parent.join(format!(
        ".{file_name}.build-runner-accelerator-{}.tmp",
        std::process::id()
    ));
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, path)
}
