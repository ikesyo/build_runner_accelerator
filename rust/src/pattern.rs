use std::collections::BTreeSet;
use std::io;

#[derive(Clone, Debug, PartialEq, Eq)]
enum CapturePart {
    Literal(String),
    Capture(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CaptureMatch {
    pub(crate) start: usize,
    pub(crate) end: usize,
    pub(crate) values: Vec<String>,
}

pub(crate) fn capture_names(pattern: &str) -> io::Result<Vec<String>> {
    let parts = parse_parts(pattern)?;
    let mut names = Vec::new();
    let mut seen = BTreeSet::new();
    for part in parts {
        let CapturePart::Capture(name) = part else {
            continue;
        };
        if !seen.insert(name.clone()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("capture group is declared more than once: {{{{{name}}}}}"),
            ));
        }
        names.push(name);
    }
    if names.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "capture pattern has no capture group",
        ));
    }
    Ok(names)
}

pub(crate) fn validate_capture_output(names: &[String], output: &str) -> io::Result<()> {
    let parts = parse_parts(output)?;
    let expected = names.iter().collect::<BTreeSet<_>>();
    let mut used = BTreeSet::new();
    for part in parts {
        let CapturePart::Capture(name) = part else {
            continue;
        };
        if !expected.contains(&name) || !used.insert(name.clone()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("capture output refers to an unknown or repeated group: {{{{{name}}}}}"),
            ));
        }
    }
    if used.len() != expected.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "capture output does not refer to every input group",
        ));
    }
    Ok(())
}

pub(crate) fn match_capture_pattern(
    path: &str,
    pattern: &str,
    anchored: bool,
) -> Option<CaptureMatch> {
    let parts = parse_parts(pattern).ok()?;
    if !parts
        .iter()
        .any(|part| matches!(part, CapturePart::Capture(_)))
    {
        return None;
    }

    let boundaries = char_boundaries(path);
    let starts = if anchored {
        vec![0]
    } else {
        boundaries.clone()
    };
    for start in starts {
        let mut values = Vec::new();
        if let Some(end) = match_parts(path, &parts, 0, start, &boundaries, &mut values) {
            return Some(CaptureMatch { start, end, values });
        }
    }
    None
}

pub(crate) fn expand_capture_template(
    template: &str,
    names: &[String],
    values: &[String],
) -> Option<String> {
    let parts = parse_parts(template).ok()?;
    let mut result = String::new();
    for part in parts {
        match part {
            CapturePart::Literal(value) => result.push_str(&value),
            CapturePart::Capture(name) => {
                let index = names.iter().position(|expected| expected == &name)?;
                result.push_str(values.get(index)?);
            }
        }
    }
    Some(result)
}

fn parse_parts(pattern: &str) -> io::Result<Vec<CapturePart>> {
    let mut parts = Vec::new();
    let mut cursor = 0;
    while let Some(relative_start) = pattern[cursor..].find("{{") {
        let start = cursor + relative_start;
        push_literal(&mut parts, &pattern[cursor..start])?;

        let name_start = start + 2;
        let Some(relative_end) = pattern[name_start..].find("}}") else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unterminated capture group",
            ));
        };
        let end = name_start + relative_end;
        let name = &pattern[name_start..end];
        if !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "capture group name must contain only letters, digits, or underscore",
            ));
        }
        parts.push(CapturePart::Capture(name.to_owned()));
        cursor = end + 2;
    }
    push_literal(&mut parts, &pattern[cursor..])?;
    Ok(parts)
}

fn push_literal(parts: &mut Vec<CapturePart>, value: &str) -> io::Result<()> {
    if value.contains('{') || value.contains('}') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "capture pattern contains an invalid brace",
        ));
    }
    if !value.is_empty() {
        parts.push(CapturePart::Literal(value.to_owned()));
    }
    Ok(())
}

fn char_boundaries(value: &str) -> Vec<usize> {
    value
        .char_indices()
        .map(|(index, _)| index)
        .chain(std::iter::once(value.len()))
        .collect()
}

fn match_parts(
    path: &str,
    parts: &[CapturePart],
    part_index: usize,
    position: usize,
    boundaries: &[usize],
    values: &mut Vec<String>,
) -> Option<usize> {
    if part_index == parts.len() {
        return (position == path.len()).then_some(position);
    }

    match &parts[part_index] {
        CapturePart::Literal(literal) => {
            let rest = path.get(position..)?;
            if !rest.starts_with(literal) {
                return None;
            }
            match_parts(
                path,
                parts,
                part_index + 1,
                position + literal.len(),
                boundaries,
                values,
            )
        }
        CapturePart::Capture(_) => {
            for end in boundaries.iter().rev().copied() {
                if end <= position {
                    continue;
                }
                values.push(path[position..end].to_owned());
                if let Some(result) = match_parts(
                    path,
                    parts,
                    part_index + 1,
                    end,
                    boundaries,
                    values,
                ) {
                    return Some(result);
                }
                values.pop();
            }
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        capture_names, expand_capture_template, match_capture_pattern, validate_capture_output,
    };

    #[test]
    fn capture_match_is_greedy_and_suffix_anchored() {
        let matched = match_capture_pattern("lib/src/lib/foo.dart", "lib/{{}}.dart", false)
            .expect("capture should match");
        assert_eq!(matched.start, 0);
        assert_eq!(matched.end, "lib/src/lib/foo.dart".len());
        assert_eq!(matched.values, vec!["src/lib/foo"]);
    }

    #[test]
    fn anchored_capture_does_not_match_a_later_path_segment() {
        assert!(match_capture_pattern("web/lib/foo.dart", "lib/{{}}.dart", true).is_none());
        assert!(match_capture_pattern("lib/foo.dart", "lib/{{}}.dart", true).is_some());
    }

    #[test]
    fn named_captures_expand_in_output_order() {
        let names = capture_names("{{dir}}/{{file}}.dart").unwrap();
        let matched = match_capture_pattern(
            "somewhere/nested/file.dart",
            "{{dir}}/{{file}}.dart",
            false,
        )
        .unwrap();
        assert_eq!(
            expand_capture_template(
                "{{dir}}/generated/{{file}}.g.dart",
                &names,
                &matched.values,
            )
            .unwrap(),
            "somewhere/nested/generated/file.g.dart"
        );
    }

    #[test]
    fn capture_metadata_accepts_anchored_builder_mapping() {
        let names = capture_names("lib/assets/{{dir}}/{{file}}.txt").unwrap();
        validate_capture_output(
            &names,
            "lib/generated/{{dir}}/{{file}}.dart",
        )
        .unwrap();
    }
}
