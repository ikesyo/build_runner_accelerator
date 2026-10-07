use crate::plan::BuildSpec;
use crate::protocol::BuildResult;
use crate::workspace::Workspace;
use std::collections::BTreeMap;
use std::sync::Arc;

pub(super) fn part_directive_filter_disabled() -> bool {
    std::env::var("BUILD_RUNNER_ACCELERATOR_PART_FILTER").is_ok_and(|value| value == "0")
}

/// Whether the spec's action provably emits nothing: the builders the
/// manifest flags with `part_directive_suffix` can only produce output when
/// the input declares the generated file as a `part` directive, matching
/// source_gen's `hasExpectedPartDirective` (literal URI equality against
/// `<stem><suffix>`). Any doubt — unreadable input, non-UTF8 bytes, escaped
/// or unterminated URIs — keeps the action.
pub(super) fn part_directive_skips(
    workspace: &Workspace,
    overlay: &BTreeMap<String, Arc<[u8]>>,
    spec: &BuildSpec,
) -> bool {
    let Some(suffix) = spec.part_directive_suffix.as_deref() else {
        return false;
    };
    let input_path = spec
        .input
        .split_once('|')
        .map(|(_, path)| path)
        .unwrap_or(&spec.input);
    let stem = input_path
        .rsplit('/')
        .next()
        .and_then(|name| name.strip_suffix(".dart"));
    let Some(stem) = stem else { return false };
    let expected = format!("{stem}{suffix}");
    let disk_bytes;
    let bytes = match overlay.get(&spec.input) {
        Some(bytes) => bytes.as_ref(),
        None => {
            disk_bytes = match workspace.read_asset_or_cache_shared(&spec.input) {
                Ok(bytes) => bytes,
                Err(_) => return false,
            };
            disk_bytes.as_slice()
        }
    };
    let Ok(source) = std::str::from_utf8(bytes) else {
        return false;
    };
    !declares_part_directive(source, &expected)
}

pub(super) fn declares_part_directive(source: &str, expected: &str) -> bool {
    let bytes = source.as_bytes();
    let len = bytes.len();
    let mut i = 0usize;
    while i + 4 <= len {
        if &bytes[i..i + 4] != b"part"
            || (i > 0 && is_ident_byte(bytes[i - 1]))
            || (i + 4 < len && is_ident_byte(bytes[i + 4]))
        {
            i += 1;
            continue;
        }
        let mut j = i + 4;
        // Dart allows trivia — whitespace and comments — between `part` and
        // its URI, e.g. `part /* note */ 'foo.g.dart';`.
        loop {
            while j < len && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            if j + 1 < len && bytes[j] == b'/' && bytes[j + 1] == b'/' {
                j += 2;
                while j < len && bytes[j] != b'\n' {
                    j += 1;
                }
                continue;
            }
            if j + 1 < len && bytes[j] == b'/' && bytes[j + 1] == b'*' {
                let mut k = j + 2;
                while k + 1 < len && !(bytes[k] == b'*' && bytes[k + 1] == b'/') {
                    k += 1;
                }
                if k + 1 >= len {
                    // Unterminated comment — ambiguous; keep the action.
                    return true;
                }
                j = k + 2;
                continue;
            }
            break;
        }
        // `part of 'uri'` declares this library as a part, not a part list.
        if j + 2 <= len
            && &bytes[j..j + 2] == b"of"
            && (j + 2 == len || !is_ident_byte(bytes[j + 2]))
        {
            i += 4;
            continue;
        }
        // Optional raw-string prefix.
        if j + 1 < len && bytes[j] == b'r' && (bytes[j + 1] == b'\'' || bytes[j + 1] == b'"') {
            j += 1;
        }
        if j < len && (bytes[j] == b'\'' || bytes[j] == b'"') {
            let quote = bytes[j];
            // `part '''uri'''` / `part """uri"""` are valid Dart: the URI is
            // terminated by the same quote repeated three times.
            let quote_len = if j + 2 < len && bytes[j + 1] == quote && bytes[j + 2] == quote {
                3
            } else {
                1
            };
            let rest = &source[j + quote_len..];
            let end = if quote_len == 3 {
                rest.as_bytes().windows(3).position(|w| w == [quote; 3])
            } else {
                match rest.find(|character: char| {
                    character == quote as char || character == '\n' || character == '\r'
                }) {
                    Some(end) if rest.as_bytes()[end] == quote => Some(end),
                    _ => None,
                }
            };
            match end {
                Some(end) => {
                    let uri = &rest[..end];
                    if uri.contains('\\') {
                        return true;
                    }
                    if uri == expected {
                        return true;
                    }
                    i = j + quote_len + end + quote_len;
                    continue;
                }
                // Unterminated string literal — let the real builder see it.
                None => return true,
            }
        } else if j < len {
            // Anything else after `part` is a shape this scanner does not
            // model — ambiguous, so keep the action.
            return true;
        }
        i += 4;
    }
    false
}

fn is_ident_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$'
}

pub(super) fn empty_build_result(spec: &BuildSpec) -> BuildResult {
    BuildResult {
        message_type: "build_result".to_owned(),
        id: 0,
        status: "success".to_owned(),
        outputs: Vec::new(),
        deleted: Vec::new(),
        reads: vec![spec.input.clone()],
        resolver_reads: Vec::new(),
        resolver_entrypoints: Vec::new(),
        resolver_used: false,
        glob_reads: Vec::new(),
        diagnostics: Vec::new(),
        error: None,
    }
}
