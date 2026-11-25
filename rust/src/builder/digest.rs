use super::{BuildTo, RustBuildConfig};
use crate::digest::digest_bytes;
use crate::workspace::Workspace;
use std::fs;
use std::io;

fn append_length_prefixed_strings(bytes: &mut Vec<u8>, values: &[String]) {
    bytes.extend_from_slice(&(values.len() as u64).to_be_bytes());
    for value in values {
        bytes.extend_from_slice(&(value.len() as u64).to_be_bytes());
        bytes.extend_from_slice(value.as_bytes());
    }
}

pub(crate) fn config_digest(workspace: &Workspace, config: &RustBuildConfig) -> io::Result<String> {
    let build_yaml = workspace.root.join("build.yaml");
    // The digest also gates reuse of the private action graph. Bump this
    // domain marker when the meaning of the graph inputs changes, so a graph
    // created before the lossless required-input, artifact-visibility, and
    // trigger state model cannot be reused silently.
    // Older workers could record success after a builder logged a severe
    // error. Never reuse those action results under scoped builder logging.
    let mut bytes = b"build-runner-accelerator-config-v7\0".to_vec();
    bytes.extend_from_slice(&fs::read(build_yaml).unwrap_or_default());
    bytes.extend_from_slice(&workspace.read_package_config()?);
    if let Some(signature) = &config.manifest_signature {
        bytes.extend_from_slice(signature.as_bytes());
    }
    if let Some(trigger_digest) = &config.trigger_digest {
        append_length_prefixed_strings(&mut bytes, std::slice::from_ref(trigger_digest));
    }
    for builder in &config.builders {
        bytes.extend_from_slice(builder.target.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(builder.package.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(&builder.target_order.to_be_bytes());
        bytes.extend_from_slice(&builder.phase.to_be_bytes());
        bytes.push(u8::from(builder.is_root));
        bytes.extend_from_slice(builder.definition.id.as_bytes());
        bytes.push(match builder.definition.kind {
            crate::builder::BuilderKind::Normal => 0,
            crate::builder::BuilderKind::PostProcess => 1,
        });
        let effective_definition = builder.effective_definition();
        for input_extension in &effective_definition.post_process_input_extensions {
            bytes.extend_from_slice(input_extension.as_bytes());
            bytes.push(0);
        }
        for extension in &effective_definition.extensions {
            bytes.extend_from_slice(extension.input_suffix.as_bytes());
            bytes.push(u8::from(extension.input_is_exact));
            bytes.push(u8::from(extension.input_is_capture));
            bytes.push(u8::from(extension.input_is_all));
            bytes.push(u8::from(extension.input_is_anchored));
            for suffix in &extension.output_suffixes {
                bytes.extend_from_slice(suffix.as_bytes());
                bytes.push(0);
            }
            bytes.push(0);
        }
        bytes.extend_from_slice(&builder.definition.phase.to_be_bytes());
        bytes.push(u8::from(builder.definition.is_optional));
        bytes.push(u8::from(builder.definition.output_is_optional));
        bytes.push(match builder.definition.build_to {
            BuildTo::Cache => 0,
            BuildTo::Source => 1,
        });
        // Keep the full ordered `required_inputs` list in the graph identity.
        // Length-prefix both the collection and each value so its boundaries
        // cannot collide with another field or another list shape.
        append_length_prefixed_strings(&mut bytes, &builder.definition.required_input_suffixes);
        for suffix in &builder.excluded_input_suffixes {
            bytes.extend_from_slice(suffix.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.generate_for {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.generate_for_exclude {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.target_sources {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        for pattern in &builder.target_sources_exclude {
            bytes.extend_from_slice(pattern.as_bytes());
            bytes.push(0);
        }
        if let Ok(options) = serde_json::to_vec(&builder.options) {
            bytes.extend_from_slice(&options);
        }
    }
    Ok(digest_bytes(&bytes))
}

#[cfg(test)]
mod tests {
    use super::append_length_prefixed_strings;

    fn encode(values: &[&str]) -> Vec<u8> {
        let values = values
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>();
        let mut bytes = Vec::new();
        append_length_prefixed_strings(&mut bytes, &values);
        bytes
    }

    #[test]
    fn required_input_suffix_encoding_preserves_collection_boundaries() {
        assert_ne!(encode(&[]), encode(&[".a"]));
        assert_ne!(encode(&[".ab", ".c"]), encode(&[".a", ".bc"]));
    }
}
