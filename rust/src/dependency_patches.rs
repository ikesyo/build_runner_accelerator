//! Embedded, exact-context unified diffs for private compiler source copies.
use std::collections::BTreeMap;
use std::io;
use std::path::{Component, Path, PathBuf};

type Sources = BTreeMap<PathBuf, Vec<u8>>;
pub(crate) const ISOLATION: [&str; 4] = [
    include_str!("../patches/analyzer-compile-isolation.patch"),
    include_str!("../patches/build_runner-compile-isolation.patch"),
    include_str!("../patches/dart_style-compile-isolation.patch"),
    include_str!("../patches/build_runner_accelerator-compile-isolation.patch"),
];
pub(crate) const RESOLVER: &str = include_str!("../patches/build_runner-resolver-options.patch");

/// Computed once per frontend process; warm preparations hash only this digest.
pub(crate) fn isolation_identity() -> &'static str {
    static IDENTITY: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    IDENTITY.get_or_init(|| crate::digest::digest_bytes(&serde_json::to_vec(&ISOLATION).unwrap()))
}

fn invalid(message: impl std::fmt::Display) -> io::Error {
    io::Error::other(format!("dependency patch: {message}"))
}

fn path(header: &str, prefix: &str) -> io::Result<PathBuf> {
    let value = header
        .strip_prefix(prefix)
        .ok_or_else(|| invalid("invalid file header"))?;
    let path = Path::new(value);
    if value.is_empty()
        || value.contains('\\')
        || !path.components().all(|c| matches!(c, Component::Normal(_)))
    {
        return Err(invalid("invalid relative path"));
    }
    Ok(path.to_owned())
}

struct Hunk {
    start: usize,
    before: String,
    after: String,
}
struct Edit {
    path: PathBuf,
    create: bool,
    hunks: Vec<Hunk>,
}

fn range(value: &str, prefix: char) -> io::Result<(usize, usize)> {
    let value = value
        .strip_prefix(prefix)
        .ok_or_else(|| invalid("invalid hunk range"))?;
    let (start, count) = value.split_once(',').unwrap_or((value, "1"));
    let number = |s: &str| s.parse::<usize>().map_err(invalid);
    Ok((number(start)?, number(count)?))
}

fn parse(patch: &str) -> io::Result<Vec<Edit>> {
    let lines = patch.split_inclusive('\n').collect::<Vec<_>>();
    let mut index = 0;
    let mut edits = Vec::new();
    while index < lines.len() {
        let old = lines[index].trim_end_matches('\n');
        let create = old == "--- /dev/null";
        let old_path = if create {
            None
        } else {
            Some(path(old, "--- a/")?)
        };
        index += 1;
        let new_path = path(
            lines
                .get(index)
                .ok_or_else(|| invalid("missing new file header"))?
                .trim_end_matches('\n'),
            "+++ b/",
        )?;
        if old_path.as_ref().is_some_and(|p| p != &new_path)
            || edits.iter().any(|e: &Edit| e.path == new_path)
        {
            return Err(invalid("renames and duplicate file edits are unsupported"));
        }
        index += 1;
        let mut hunks = Vec::new();
        while index < lines.len() && !lines[index].starts_with("--- ") {
            let header = lines[index].trim_end_matches('\n');
            let mut fields = header.split_whitespace();
            if fields.next() != Some("@@") {
                return Err(invalid("missing hunk header"));
            }
            let (start, old_count) = range(
                fields.next().ok_or_else(|| invalid("missing old range"))?,
                '-',
            )?;
            let (_, new_count) = range(
                fields.next().ok_or_else(|| invalid("missing new range"))?,
                '+',
            )?;
            if fields.next() != Some("@@") || (old_count > 0 && start == 0) {
                return Err(invalid("invalid hunk header"));
            }
            index += 1;
            let mut before = String::new();
            let mut after = String::new();
            let (mut removed, mut added) = (0, 0);
            while removed < old_count || added < new_count {
                let line = lines.get(index).ok_or_else(|| invalid("truncated hunk"))?;
                let body = line.get(1..).ok_or_else(|| invalid("empty hunk line"))?;
                match line.as_bytes()[0] {
                    b' ' => {
                        before.push_str(body);
                        after.push_str(body);
                        removed += 1;
                        added += 1;
                    }
                    b'-' => {
                        before.push_str(body);
                        removed += 1;
                    }
                    b'+' => {
                        after.push_str(body);
                        added += 1;
                    }
                    _ => return Err(invalid("unsupported hunk line")),
                }
                index += 1;
                if removed > old_count || added > new_count {
                    return Err(invalid("hunk count mismatch"));
                }
            }
            // Only a file creation or a beginning-of-file prepend may lack context.
            if before.is_empty() && start != 0 {
                return Err(invalid("contextless insertion"));
            }
            hunks.push(Hunk {
                start,
                before,
                after,
            });
        }
        if hunks.is_empty() {
            return Err(invalid("file has no hunks"));
        }
        edits.push(Edit {
            path: new_path,
            create,
            hunks,
        });
    }
    if edits.is_empty() {
        return Err(invalid("empty patch"));
    }
    Ok(edits)
}

/// Stage every edit before updating the map. Matching permits line offsets, but
/// never fuzzy context, ambiguous matches, partial application, or subprocesses.
pub(crate) fn apply(files: &mut Sources, patch: &str) -> io::Result<()> {
    let mut staged = Sources::new();
    for edit in parse(patch)? {
        let original = match (edit.create, files.get(&edit.path)) {
            (true, None) => "",
            (false, Some(bytes)) => std::str::from_utf8(bytes).map_err(invalid)?,
            _ => {
                return Err(invalid(format!(
                    "unexpected file existence: {}",
                    edit.path.display()
                )));
            }
        };
        let mut cursor = 0;
        let mut output = String::new();
        for hunk in edit.hunks {
            let offset = if hunk.before.is_empty() {
                if hunk.start != 0 || cursor != 0 {
                    return Err(invalid("invalid prepend"));
                }
                0
            } else {
                let mut matches = std::iter::once(0)
                    .chain(original.match_indices('\n').map(|(i, _)| i + 1))
                    .filter(|&i| original[i..].starts_with(&hunk.before));
                let offset = matches.next().ok_or_else(|| {
                    invalid(format!("source context differs: {}", edit.path.display()))
                })?;
                if matches.next().is_some() {
                    return Err(invalid(format!(
                        "ambiguous source context: {}",
                        edit.path.display()
                    )));
                }
                offset
            };
            if offset < cursor {
                return Err(invalid("overlapping or unordered hunks"));
            }
            output.push_str(&original[cursor..offset]);
            output.push_str(&hunk.after);
            cursor = offset + hunk.before.len();
        }
        output.push_str(&original[cursor..]);
        staged.insert(edit.path, output.into_bytes());
    }
    files.extend(staged);
    Ok(())
}

#[cfg(test)]
pub(crate) fn preimages(patches: &[&str]) -> Sources {
    let mut files = Sources::new();
    for patch in patches {
        for edit in parse(patch).unwrap() {
            if edit.create {
                continue;
            }
            let mut text = String::new();
            let mut line = 1;
            for hunk in edit.hunks {
                if hunk.before.is_empty() {
                    continue;
                }
                while line < hunk.start {
                    text.push_str("// fixture filler\n");
                    line += 1;
                }
                line += hunk.before.lines().count();
                text.push_str(&hunk.before);
            }
            files.insert(edit.path, text.into_bytes());
        }
    }
    files
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offsets_creation_and_atomic_failure() {
        let mut files =
            Sources::from([(PathBuf::from("lib/a.dart"), b"prefix\nold\nend\n".to_vec())]);
        let patch = "--- a/lib/a.dart\n+++ b/lib/a.dart\n@@ -1 +1 @@\n-old\n+new\n--- /dev/null\n+++ b/lib/b.dart\n@@ -0,0 +1 @@\n+created\n";
        apply(&mut files, patch).unwrap();
        assert_eq!(files[Path::new("lib/a.dart")], b"prefix\nnew\nend\n");
        assert_eq!(files[Path::new("lib/b.dart")], b"created\n");
        let before = files.clone();
        assert!(apply(&mut files, patch).is_err());
        assert_eq!(files, before);
        let fail = "--- a/lib/a.dart\n+++ b/lib/a.dart\n@@ -1 +1 @@\n-new\n+other\n--- a/missing\n+++ b/missing\n@@ -1 +1 @@\n-x\n+y\n";
        assert!(apply(&mut files, fail).is_err());
        assert_eq!(files, before);
    }
    #[test]
    fn ambiguous_context_and_unsafe_paths_fail() {
        let mut files = Sources::from([(PathBuf::from("a"), b"x\nx\n".to_vec())]);
        for patch in [
            "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n",
            "--- /dev/null\n+++ b/../escape\n@@ -0,0 +1 @@\n+x\n",
            "--- a/a\n+++ b/a\n@@ -1,2 +1 @@\n-x\n+y\n",
        ] {
            assert!(apply(&mut files, patch).is_err());
        }
    }
    #[test]
    fn overlapping_context_is_ambiguous() {
        let mut files = Sources::from([(PathBuf::from("a"), b"x\nx\nx\n".to_vec())]);
        let before = files.clone();
        let patch = "--- a/a\n+++ b/a\n@@ -1,2 +1 @@\n-x\n-x\n+y\n";
        assert!(
            apply(&mut files, patch)
                .unwrap_err()
                .to_string()
                .contains("ambiguous")
        );
        assert_eq!(files, before);
    }
}
