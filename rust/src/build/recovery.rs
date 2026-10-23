//! Undo journal for the publication boundary. The workspace writer lock must
//! cover preparation, publication, and recovery. No fsync/power-loss promise.
use crate::assets::write_atomic;
use crate::digest::digest_bytes;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: PathBuf,
    before: Option<String>,
    after: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    graph_path: PathBuf,
    entries: Vec<Entry>,
    graph: Option<String>,
}

fn directory(graph: &Path) -> PathBuf {
    graph.with_extension("commit-undo")
}

pub(crate) fn pending(graph: &Path) -> bool {
    directory(graph).join("journal.json").exists()
}

/// Verification must not turn a previous interrupted publishing command into
/// filesystem writes. Refuse before graph loading, with an ordinary-build retry.
pub(super) fn require_clean_verification(graph: &Path) -> io::Result<()> {
    match fs::symlink_metadata(directory(graph).join("journal.json")) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(guidance(&directory(graph), error)),
        Ok(_) => Err(io::Error::other(
            "interrupted commit requires recovery; --only-check leaves outputs, graph and undo state untouched. Run a native build without --only-check to recover first, then retry verification. Do not clear native state.",
        )),
    }
}

fn check_no_symlinks(path: &Path) -> io::Result<()> {
    // Reject links, including parent links: recovery must never follow a new
    // symlink into a handwritten file. Missing parents are safe to recreate.
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(io::Error::other(format!(
                    "symlink at {}",
                    ancestor.display()
                )));
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn read_optional(path: &Path) -> io::Result<Option<Vec<u8>>> {
    check_no_symlinks(path)?;
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.is_file() => {
            return Err(io::Error::other(format!(
                "not a regular file: {}",
                path.display()
            )));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

// Reserved by the journal before use. A fixed sibling name stays on the
// destination filesystem, including when package directories are mount points.
fn temporary(path: &Path) -> io::Result<PathBuf> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| io::Error::other("output has no UTF-8 filename"))?;
    Ok(path.with_file_name(format!(".{name}.build-runner-accelerator-commit.tmp")))
}

fn require_unreserved(path: &Path) -> io::Result<()> {
    let path = temporary(path)?;
    check_no_symlinks(&path)?;
    match fs::symlink_metadata(&path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
        Ok(_) => Err(io::Error::other(format!(
            "cannot reserve commit temporary file {}; move the existing file aside before retrying",
            path.display()
        ))),
    }
}

/// Only for destinations already reserved in the active undo journal. Partial
/// temporary files remain owned by that journal across publication and rollback.
pub(super) fn write_output(path: &Path, bytes: &[u8]) -> io::Result<()> {
    if path.is_file() && fs::read(path)? == bytes {
        return Ok(());
    }
    fs::create_dir_all(
        path.parent()
            .ok_or_else(|| io::Error::other("output has no parent"))?,
    )?;
    let temporary = temporary(path)?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    super::commit::boundary("output_temporary_created")?;
    file.write_all(bytes)?;
    drop(file);
    fs::rename(temporary, path)
}

fn validate_temporary(path: &Path) -> io::Result<()> {
    let path = temporary(path)?;
    check_no_symlinks(&path)?;
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.is_file() => Ok(()),
        Ok(_) => Err(io::Error::other(format!(
            "unexpected commit temporary file type at {}",
            path.display()
        ))),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn remove_temporary(path: &Path) -> io::Result<()> {
    match fs::remove_file(temporary(path)?) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

/// Publish the journal only after every backup is complete. An interrupted
/// preparation has changed no outputs and its unreferenced backups can be reused.
pub(super) fn prepare(graph: &Path, changes: BTreeMap<PathBuf, Option<String>>) -> io::Result<()> {
    if pending(graph) {
        return Err(io::Error::other(
            "unfinished commit must be recovered before publication",
        ));
    }
    if changes.contains_key(graph)
        || changes.contains_key(&temporary(graph)?)
        || changes
            .keys()
            .any(|path| path.starts_with(directory(graph)))
    {
        return Err(io::Error::other("output overlaps graph recovery state"));
    }
    require_unreserved(graph)?;
    for path in changes.keys() {
        if changes.contains_key(&temporary(path)?) || temporary(path)? == graph {
            return Err(io::Error::other(
                "commit temporary path overlaps another output",
            ));
        }
        require_unreserved(path)?;
    }
    let dir = directory(graph);
    check_no_symlinks(&dir)?;
    fs::create_dir_all(&dir)?;
    let mut entries = Vec::new();
    for (index, (path, after)) in changes.into_iter().enumerate() {
        let before = read_optional(&path)?;
        if let Some(bytes) = &before {
            let path = dir.join(index.to_string());
            check_no_symlinks(&path)?;
            fs::write(path, bytes)?;
        }
        entries.push(Entry {
            path,
            before: before.as_deref().map(digest_bytes),
            after,
        });
    }
    let before_graph = read_optional(graph)?;
    if let Some(bytes) = &before_graph {
        check_no_symlinks(&dir.join("graph"))?;
        fs::write(dir.join("graph"), bytes)?;
    }
    let journal = Journal {
        version: 1,
        graph_path: graph.to_owned(),
        entries,
        graph: before_graph.as_deref().map(digest_bytes),
    };
    write_atomic(&dir.join("journal.json"), &serde_json::to_vec(&journal)?)
}

/// The single unlink is the commit point. Cleanup after it is best-effort;
/// leaving unreferenced backups must not turn success into a rollback.
pub(super) fn finish(graph: &Path) -> io::Result<()> {
    let dir = directory(graph);
    fs::remove_file(dir.join("journal.json"))?;
    let _ = fs::remove_dir_all(dir);
    Ok(())
}

fn backup(dir: &Path, name: &str, digest: &Option<String>) -> io::Result<Option<Vec<u8>>> {
    let Some(digest) = digest else {
        return Ok(None);
    };
    let bytes = read_optional(&dir.join(name))?
        .ok_or_else(|| io::Error::other(format!("missing undo backup {name}")))?;
    if digest_bytes(&bytes) != *digest {
        return Err(io::Error::other(format!("damaged undo backup {name}")));
    }
    Ok(Some(bytes))
}

fn restore(path: &Path, bytes: Option<&[u8]>) -> io::Result<()> {
    match bytes {
        Some(bytes) => write_output(path, bytes),
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        },
    }
}

/// Validate *all* evidence before touching anything. Keep the journal until
/// outputs and the old graph have been restored; every restore is idempotent.
pub(crate) fn recover(graph: &Path) -> io::Result<bool> {
    let dir = directory(graph);
    let marker = dir.join("journal.json");
    match fs::symlink_metadata(&marker) {
        Ok(metadata) if !metadata.is_file() => {
            return Err(guidance(
                &dir,
                io::Error::other("undo journal is not a regular file"),
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(guidance(&dir, error)),
    }
    let _recovery = crate::wall::Span::new("commit_undo_recovery");
    let result = (|| {
        check_no_symlinks(&marker)?;
        let encoded = fs::read(&marker)?;
        let journal: Journal = serde_json::from_slice(&encoded)?;
        if journal.version != 1 || journal.graph_path != graph {
            return Err(io::Error::other("unsupported or relocated undo journal"));
        }
        for (index, entry) in journal.entries.iter().enumerate() {
            if !entry.path.is_absolute()
                || entry
                    .path
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir))
            {
                return Err(io::Error::other("invalid undo output path"));
            }
            let current = read_optional(&entry.path)?.as_deref().map(digest_bytes);
            if current.is_some() && current != entry.before && current != entry.after {
                return Err(io::Error::other(format!(
                    "output changed outside the interrupted commit: {}",
                    entry.path.display()
                )));
            }
            validate_temporary(&entry.path)?;
            // Validate every backup before any mutation, without retaining the
            // entire output tree in memory. Recheck each copy when restoring.
            backup(&dir, &index.to_string(), &entry.before)?;
        }
        let old_graph = backup(&dir, "graph", &journal.graph)?;
        if let Some(bytes) = &old_graph {
            crate::graph::GraphState::decode_checked(bytes, false)?;
        }
        // Also reject a graph/parent link before restoring any output.
        read_optional(graph)?;
        validate_temporary(graph)?;
        eprintln!(
            "build_runner_accelerator: recovering interrupted commit ({} outputs)",
            journal.entries.len()
        );
        // These paths were absent and reserved before publication. Do not scan
        // for unrelated sibling files; an unknown file is never swept.
        for entry in &journal.entries {
            remove_temporary(&entry.path)?;
        }
        remove_temporary(graph)?;
        for (index, entry) in journal.entries.iter().enumerate() {
            let bytes = backup(&dir, &index.to_string(), &entry.before)?;
            restore(&entry.path, bytes.as_deref())?;
            super::commit::boundary("after_restore")?;
        }
        restore(graph, old_graph.as_deref())?;
        finish(graph)
    })();
    result.map(|()| true).map_err(|error| guidance(&dir, error))
}

fn guidance(dir: &Path, error: io::Error) -> io::Error {
    io::Error::other(format!(
        "cannot recover interrupted commit: {error}. Undo state preserved at {}. Stop build/watch and stock processes; back up this directory and affected files. Fix I/O permissions/space, or move externally edited files aside, then retry the same native command. For damaged/incompatible evidence, restore intact backups or use the matching frontend; see docs/compatibility-cleanup.md#interrupted-publication. Do not clear the graph or undo state before recovery.",
        dir.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "commit-undo-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(crate::workspace::canonicalize(path).unwrap())
        }
        fn graph(&self) -> PathBuf {
            self.0.join("graph.bin")
        }
        fn output(&self) -> PathBuf {
            self.0.join("output")
        }
        fn prepare(&self) {
            prepare(
                &self.graph(),
                BTreeMap::from([(self.output(), Some(digest_bytes(b"new")))]),
            )
            .unwrap();
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn cold_commit_removes_only_journaled_new_outputs() {
        let fixture = Fixture::new();
        fs::write(fixture.0.join("unowned"), b"handwritten").unwrap();
        fixture.prepare();
        fs::write(fixture.output(), b"new").unwrap();
        fs::write(fixture.graph(), b"new graph").unwrap();
        recover(&fixture.graph()).unwrap();
        assert!(!fixture.output().exists());
        assert!(!fixture.graph().exists());
        assert_eq!(fs::read(fixture.0.join("unowned")).unwrap(), b"handwritten");
        recover(&fixture.graph()).unwrap();
    }

    #[test]
    fn damaged_backup_or_journal_blocks_graph_reuse_without_restoring_any_output() {
        let fixture = Fixture::new();
        fs::write(fixture.output(), b"old").unwrap();
        fs::write(fixture.graph(), b"old graph").unwrap();
        fixture.prepare();
        fs::write(fixture.output(), b"new").unwrap();
        fs::write(directory(&fixture.graph()).join("0"), b"damaged").unwrap();
        assert!(crate::graph::GraphState::load(&fixture.graph()).is_err());
        assert_eq!(fs::read(fixture.output()).unwrap(), b"new");
        fs::write(directory(&fixture.graph()).join("journal.json"), b"{").unwrap();
        assert!(crate::graph::GraphState::load(&fixture.graph()).is_err());
        assert!(pending(&fixture.graph()));
        assert_eq!(fs::read(fixture.graph()).unwrap(), b"old graph");
    }

    #[test]
    fn validates_later_backups_before_restoring_earlier_outputs() {
        let fixture = Fixture::new();
        let later = fixture.0.join("z-output");
        fs::write(fixture.output(), b"old first").unwrap();
        fs::write(&later, b"old last").unwrap();
        prepare(
            &fixture.graph(),
            BTreeMap::from([
                (fixture.output(), Some(digest_bytes(b"new first"))),
                (later.clone(), Some(digest_bytes(b"new last"))),
            ]),
        )
        .unwrap();
        fs::write(fixture.output(), b"new first").unwrap();
        fs::write(&later, b"new last").unwrap();
        let last_backup = directory(&fixture.graph()).join("1");
        fs::write(&last_backup, b"damaged").unwrap();
        assert!(recover(&fixture.graph()).is_err());
        assert_eq!(fs::read(fixture.output()).unwrap(), b"new first");
        assert_eq!(fs::read(&later).unwrap(), b"new last");
        assert!(pending(&fixture.graph()));
        fs::write(last_backup, b"old last").unwrap();
        recover(&fixture.graph()).unwrap();
        assert_eq!(fs::read(fixture.output()).unwrap(), b"old first");
        assert_eq!(fs::read(later).unwrap(), b"old last");
    }

    #[test]
    fn restore_io_failure_keeps_journal_and_can_retry() {
        let fixture = Fixture::new();
        fs::write(fixture.output(), b"old").unwrap();
        fixture.prepare();
        fs::write(fixture.output(), b"new").unwrap();
        let temporary = temporary(&fixture.output()).unwrap();
        fs::create_dir(&temporary).unwrap();
        assert!(recover(&fixture.graph()).is_err());
        assert!(pending(&fixture.graph()));
        fs::remove_dir(temporary).unwrap();
        recover(&fixture.graph()).unwrap();
        assert_eq!(fs::read(fixture.output()).unwrap(), b"old");
    }

    #[test]
    fn partial_temporary_files_are_owned_and_recovery_removes_them() {
        let fixture = Fixture::new();
        fs::write(fixture.output(), b"old").unwrap();
        fixture.prepare();
        fs::write(temporary(&fixture.output()).unwrap(), b"partially written").unwrap();
        recover(&fixture.graph()).unwrap();
        assert_eq!(fs::read(fixture.output()).unwrap(), b"old");
        assert!(!temporary(&fixture.output()).unwrap().exists());
    }

    #[test]
    fn existing_temporary_file_is_unowned_and_prevents_publication() {
        let fixture = Fixture::new();
        fs::write(fixture.output(), b"old").unwrap();
        fs::write(temporary(&fixture.output()).unwrap(), b"handwritten").unwrap();
        assert!(
            prepare(
                &fixture.graph(),
                BTreeMap::from([(fixture.output(), Some(digest_bytes(b"new")))])
            )
            .is_err()
        );
        assert!(!pending(&fixture.graph()));
        assert_eq!(fs::read(fixture.output()).unwrap(), b"old");
        assert_eq!(
            fs::read(temporary(&fixture.output()).unwrap()).unwrap(),
            b"handwritten"
        );
    }

    #[cfg(unix)]
    #[test]
    fn output_and_undo_symlinks_never_mutate_their_targets() {
        use std::os::unix::fs::symlink;
        let fixture = Fixture::new();
        let manual = fixture.0.join("manual");
        fs::write(&manual, b"new").unwrap();
        fixture.prepare();
        symlink(&manual, fixture.output()).unwrap();
        assert!(recover(&fixture.graph()).is_err());
        assert!(pending(&fixture.graph()));
        assert_eq!(fs::read(&manual).unwrap(), b"new");
        fs::remove_file(fixture.output()).unwrap();
        recover(&fixture.graph()).unwrap();
        fs::create_dir(fixture.0.join("manual-dir")).unwrap();
        symlink(fixture.0.join("manual-dir"), directory(&fixture.graph())).unwrap();
        assert!(prepare(&fixture.graph(), BTreeMap::new()).is_err());
        assert_eq!(
            fs::read_dir(fixture.0.join("manual-dir")).unwrap().count(),
            0
        );
    }
    #[cfg(unix)]
    #[test]
    fn dangling_journal_link_is_an_error_not_an_absent_commit() {
        let fixture = Fixture::new();
        fs::create_dir(directory(&fixture.graph())).unwrap();
        std::os::unix::fs::symlink(
            fixture.0.join("missing"),
            directory(&fixture.graph()).join("journal.json"),
        )
        .unwrap();
        assert!(crate::graph::GraphState::load(&fixture.graph()).is_err());
        assert!(
            fs::symlink_metadata(directory(&fixture.graph()).join("journal.json"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }
    #[test]
    fn unreadable_old_graph_never_becomes_an_empty_recovery_graph() {
        for obsolete in [false, true] {
            let fixture = Fixture::new();
            fs::write(fixture.output(), b"old").unwrap();
            if obsolete {
                crate::graph::GraphState {
                    schema_version: crate::graph::GRAPH_SCHEMA_VERSION - 1,
                    ..crate::graph::GraphState::default()
                }
                .save(&fixture.graph())
                .unwrap();
            } else {
                fs::write(fixture.graph(), b"old corrupt graph").unwrap();
            }
            fixture.prepare();
            fs::write(fixture.output(), b"new").unwrap();
            assert!(crate::graph::GraphState::load(&fixture.graph()).is_err());
            assert!(pending(&fixture.graph()));
            assert_eq!(fs::read(fixture.output()).unwrap(), b"new");
        }
    }
}
