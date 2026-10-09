use super::{BuilderManifestFile, rust_build_config_from_manifest};
use crate::builder::{BuildTo, BuilderKind};
use serde_json::json;

#[test]
fn dynamic_manifest_preserves_builder_phase_order() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "target_order": 0,
                "id": "example:phase-two",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".two"]
                }],
                "build_to": "source",
                "phase": 1,
                "target": "example:example",
                "package": "example",
                "is_root": true,
                "generate_for": ["lib/**/*.txt"]
            },
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "target_order": 0,
                "id": "example:phase-one",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".one"]
                }],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "is_root": true,
                "generate_for": ["lib/**/*.txt"]
            }
        ],
        "definitions": [
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:phase-two",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".two"]
                }],
                "build_to": "source",
                "phase": 1
            },
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:phase-one",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".one"]
                }],
                "build_to": "source",
                "phase": 0
            }
        ]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(
        config
            .builders
            .iter()
            .map(|builder| builder.definition.id.as_str())
            .collect::<Vec<_>>(),
        vec!["example:phase-one", "example:phase-two"]
    );
    assert_eq!(
        config
            .builders
            .iter()
            .map(|builder| builder.definition.phase)
            .collect::<Vec<_>>(),
        vec![0, 1]
    );
}
#[test]
fn configured_phase_is_the_global_worker_phase() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:phase-one",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".one"]
                }],
                "build_to": "cache",
                "phase": 3,
                "target_order": 0,
                "target": "example:example",
                "package": "example",
                "is_root": true,
                "generate_for": ["lib/**/*.txt"]
            },
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:phase-two",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".two"]
                }],
                "build_to": "cache",
                "phase": 7,
                "target_order": 0,
                "target": "example:example",
                "package": "example",
                "is_root": true,
                "generate_for": ["lib/**/*.txt"]
            }
        ],
        "definitions": [
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:phase-one",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".one"]
                }],
                "build_to": "cache",
                "phase": 0
            },
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:phase-two",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".two"]
                }],
                "build_to": "cache",
                "phase": 0
            }
        ]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(config.global_phase(&config.builders[0]), 3);
    assert_eq!(config.global_phase(&config.builders[1]), 7);
    assert_eq!(config.phase_count(), 8);
}

#[test]
fn dynamic_manifest_preserves_configured_input_exclusions() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".gen.txt"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "excluded_input_suffixes": [".later.txt"],
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".gen.txt"]
            }],
            "build_to": "source",
            "phase": 0,
            "excluded_input_suffixes": [".all.txt"]
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(config.builders[0].excluded_input_suffixes, [".later.txt"]);
    assert_eq!(
        config.builders[0].definition.excluded_input_suffixes,
        [".all.txt"]
    );
}

#[test]
fn dynamic_manifest_preserves_multiple_outputs() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".gen.txt", ".meta.txt"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".gen.txt", ".meta.txt"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(
        config.builders[0].definition.extensions[0].output_suffixes,
        vec![".gen.txt", ".meta.txt"]
    );
}

#[test]
fn dynamic_manifest_preserves_all_required_input_suffixes() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "required_input_suffixes": [".first", ".second"],
            "build_to": "cache",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "required_input_suffixes": [".first", ".second"],
            "build_to": "cache",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(
        config.builders[0].definition.required_input_suffixes,
        [".first", ".second"]
    );
}

#[test]
fn dynamic_manifest_preserves_optional_builder_flag() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:optional",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".optional.txt"]
            }],
            "is_optional": true,
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "output_is_optional": false,
            "id": "example:optional",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".optional.txt"]
            }],
            "is_optional": true,
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert!(config.builders[0].definition.is_optional);
}

#[test]
fn dynamic_manifest_preserves_trigger_metadata_and_digest() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "trigger_digest": "trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:trigger",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated.dart"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.dart"],
            "triggers": [
                {"kind": "import", "value": "example/marker.dart"},
                {"kind": "annotation", "value": "Marker"}
            ]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:trigger",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated.dart"]
            }],
            "build_to": "source",
            "phase": 0,
            "triggers": [
                {"kind": "import", "value": "example/marker.dart"},
                {"kind": "annotation", "value": "Marker"}
            ]
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(config.trigger_digest.as_deref(), Some("trigger-digest"));
    assert_eq!(
        config.builders[0].definition.triggers,
        vec![
            super::BuilderTrigger {
                kind: "import".to_owned(),
                value: "example/marker.dart".to_owned(),
            },
            super::BuilderTrigger {
                kind: "annotation".to_owned(),
                value: "Marker".to_owned(),
            },
        ]
    );
}

#[test]
fn dynamic_manifest_rejects_unsupported_trigger_kind() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:trigger",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated.dart"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.dart"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:trigger",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated.dart"]
            }],
            "build_to": "source",
            "phase": 0,
            "triggers": [{"kind": "library", "value": "example/marker.dart"}]
        }]
    }))
    .unwrap();
    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert!(error.to_string().contains("unsupported trigger"));
}

#[test]
fn dynamic_manifest_accepts_multiple_extension_mappings() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [
                {
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".multi"]
                },
                {
                    "input_suffix": "lib/special.txt",
                    "input_match": "exact",
                    "input_anchored": true,
                    "output_suffixes": ["lib/special.generated.txt"]
                }
            ],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [
                {
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".multi"]
                },
                {
                    "input_suffix": "lib/special.txt",
                    "input_match": "exact",
                    "input_anchored": true,
                    "output_suffixes": ["lib/special.generated.txt"]
                }
            ],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(config.builders[0].definition.extensions.len(), 2);
    assert_eq!(
        config.builders[0].definition.extensions[1].output_suffixes,
        ["lib/special.generated.txt"]
    );
    assert!(config.builders[0].definition.extensions[1].input_is_exact);
}

#[test]
fn dynamic_manifest_accepts_all_input_mapping() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:all",
            "kind": "normal",
            "extensions": [{
                "input_suffix": "",
                "input_match": "all",
                "input_anchored": false,
                "output_suffixes": [".all"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["**"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:all",
            "kind": "normal",
            "extensions": [{
                "input_suffix": "",
                "input_match": "all",
                "input_anchored": false,
                "output_suffixes": [".all"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    let extension = &config.builders[0].definition.extensions[0];
    assert!(extension.input_is_all);
    assert!(!extension.input_is_exact);
    assert!(!extension.input_is_capture);
    assert_eq!(extension.input_suffix, "");
}

#[test]
fn dynamic_manifest_rejects_non_empty_all_input_metadata() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:all",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "all",
                "input_anchored": false,
                "output_suffixes": [".all"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["**"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:all",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "all",
                "input_anchored": false,
                "output_suffixes": [".all"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("unsupported build extension metadata")
    );
}

#[test]
fn dynamic_manifest_accepts_post_process_definition() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".gen.txt"],
            "build_to": "cache",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.gen.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".gen.txt"],
            "build_to": "cache",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(config.builders[0].definition.kind, BuilderKind::PostProcess);
    assert_eq!(config.builders[0].definition.build_to, BuildTo::Cache);
    assert_eq!(
        config.builders[0].definition.post_process_input_extensions,
        [".gen.txt"]
    );
    assert!(config.builders[0].definition.extensions.is_empty());
    assert!(config.builders[0].definition.output_is_optional);
}

#[test]
fn dynamic_manifest_accepts_source_post_process_definition() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".gen.txt"],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.gen.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".gen.txt"],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(config.builders[0].definition.kind, BuilderKind::PostProcess);
    assert_eq!(config.builders[0].definition.build_to, BuildTo::Source);
}

#[test]
fn singular_output_field_is_accepted_during_manifest_transition() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".gen.txt"],
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".gen.txt"],
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(
        config.builders[0].definition.extensions[0].output_suffixes,
        [".gen.txt"]
    );
}

#[test]
fn dynamic_manifest_accepts_capture_mapping() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:capture",
            "kind": "normal",
            "extensions": [{
                "input_suffix": "lib/assets/{{dir}}/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": true,
                "output_suffixes": ["lib/generated/{{dir}}/{{file}}.dart"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/assets/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:capture",
            "kind": "normal",
            "extensions": [{
                "input_suffix": "lib/assets/{{dir}}/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": true,
                "output_suffixes": ["lib/generated/{{dir}}/{{file}}.dart"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();
    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert!(config.builders[0].definition.extensions[0].input_is_capture);
    assert!(config.builders[0].definition.extensions[0].input_is_anchored);
}
#[test]
fn dynamic_manifest_preserves_per_application_runtime_mapping() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".static"]
            }],
            "build_to": "cache",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": false,
            "generate_for": ["**"],
            "runtime_mapping": {
                "extensions": [{
                    "input_suffix": ".dart",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".runtime"]
                }]
            }
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".static"]
            }],
            "build_to": "cache",
            "phase": 0
        }]
    }))
    .unwrap();

    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert!(!config.builders[0].is_root);
    assert_eq!(
        config.builders[0].definition.extensions[0].output_suffixes,
        [".static".to_owned()]
    );
    assert_eq!(
        config.builders[0].effective_definition().extensions[0].output_suffixes,
        [".runtime"]
    );
}

#[test]
fn dynamic_manifest_rejects_unsupported_version() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "builders": [],
        "definitions": [],
        "version": 7,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart"
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(error.to_string(), "unsupported builder manifest version: 7");
}

#[test]
fn dynamic_manifest_rejects_missing_worker_entrypoint() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "builders": [],
        "definitions": [],
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": ""
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "builder manifest has no worker entrypoint"
    );
}

#[test]
fn dynamic_manifest_rejects_duplicate_definitions() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "builders": [],
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "definitions": [
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:builder",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".generated"]
                }],
                "build_to": "source",
                "phase": 0
            },
            {
                "required_input_suffixes": [],
                "excluded_input_suffixes": [],
                "generate_for": [],
                "generate_for_exclude": [],
                "target_sources": [],
                "target_sources_exclude": [],
                "triggers": [],
                "options": {},
                "is_optional": false,
                "output_is_optional": false,
                "id": "example:builder",
                "kind": "normal",
                "extensions": [{
                    "input_suffix": ".txt",
                    "input_match": "suffix",
                    "input_anchored": false,
                    "output_suffixes": [".generated"]
                }],
                "build_to": "source",
                "phase": 0
            }
        ]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "builder manifest contains duplicate definitions"
    );
}

#[test]
fn dynamic_manifest_rejects_configured_builder_without_definition() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:configured",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:other",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "configured builder is missing from definitions: example:configured"
    );
}

#[test]
fn dynamic_manifest_rejects_configured_builder_without_generate_for() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example"
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "configured builder has no generate_for: example:builder"
    );
}

#[test]
fn dynamic_manifest_rejects_configured_builder_without_target_scope() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "configured builder has no target scope: example:builder"
    );
}

#[test]
fn dynamic_manifest_rejects_invalid_input_match() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "regex",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".txt",
                "input_match": "regex",
                "input_anchored": false,
                "output_suffixes": [".generated"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "unsupported input match for example:builder: regex"
    );
}

#[test]
fn dynamic_manifest_rejects_invalid_capture_output() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:capture",
            "kind": "normal",
            "extensions": [{
                "input_suffix": "lib/assets/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": false,
                "output_suffixes": ["lib/generated/{{missing}}.dart"]
            }],
            "build_to": "source",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/assets/**/*.txt"]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:capture",
            "kind": "normal",
            "extensions": [{
                "input_suffix": "lib/assets/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": false,
                "output_suffixes": ["lib/generated/{{missing}}.dart"]
            }],
            "build_to": "source",
            "phase": 0
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("unsupported build extension metadata")
    );
}

#[test]
fn dynamic_manifest_rejects_post_process_triggers() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".generated"],
            "build_to": "cache",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.generated"],
            "triggers": [{"kind": "import", "value": "example/marker.dart"}]
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".generated"],
            "build_to": "cache",
            "phase": 0,
            "triggers": [{"kind": "import", "value": "example/marker.dart"}]
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "unsupported triggers for post-process builder: example:post"
    );
}

#[test]
fn dynamic_manifest_rejects_mismatched_normal_runtime_mapping() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated.dart"]
            }],
            "build_to": "cache",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.dart"],
            "runtime_mapping": {"input_extensions": [".runtime.dart"]}
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:builder",
            "kind": "normal",
            "extensions": [{
                "input_suffix": ".dart",
                "input_match": "suffix",
                "input_anchored": false,
                "output_suffixes": [".generated.dart"]
            }],
            "build_to": "cache",
            "phase": 0
        }]
    }))
    .unwrap();

    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert_eq!(
        error.to_string(),
        "invalid runtime mapping for example:builder: normal builders cannot carry input_extensions"
    );
}

#[test]
fn dynamic_manifest_preserves_post_process_runtime_mapping() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9,
        "fingerprint": "fingerprint",
        "trigger_digest": "stock-trigger-digest",
        "worker_entrypoint": "dynamic_worker.dart",
        "builders": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "target_order": 0,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".static"],
            "build_to": "cache",
            "phase": 0,
            "target": "example:example",
            "package": "example",
            "is_root": true,
            "generate_for": ["lib/**/*.static"],
            "runtime_mapping": {"input_extensions": [".runtime"]}
        }],
        "definitions": [{
            "required_input_suffixes": [],
            "excluded_input_suffixes": [],
            "generate_for": [],
            "generate_for_exclude": [],
            "target_sources": [],
            "target_sources_exclude": [],
            "triggers": [],
            "options": {},
            "is_optional": false,
            "output_is_optional": false,
            "id": "example:post",
            "kind": "post_process",
            "input_extensions": [".static"],
            "build_to": "cache",
            "phase": 0
        }]
    }))
    .unwrap();

    let config = rust_build_config_from_manifest(manifest).unwrap();
    assert_eq!(
        config.builders[0].definition.post_process_input_extensions,
        [".static"]
    );
    assert_eq!(
        config.builders[0]
            .effective_definition()
            .post_process_input_extensions,
        [".runtime"]
    );
    assert_eq!(config.phase_count(), 1);
}

#[test]
fn flattened_manifest_is_rejected_without_guessing_extensions() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "builders": [],
        "version": 9, "fingerprint": "x", "trigger_digest": "digest", "worker_entrypoint": "worker.dart",
        "trigger_digest": "stock-trigger-digest",
        "definitions": [{
        "required_input_suffixes": [],
        "excluded_input_suffixes": [],
        "generate_for": [],
        "generate_for_exclude": [],
        "target_sources": [],
        "target_sources_exclude": [],
        "triggers": [],
        "options": {},
        "is_optional": false,
        "output_is_optional": false,"id": "app:copy", "kind": "normal", "input_suffix": ".txt", "output_suffix": ".out", "phase": 0, "build_to": "source"}]
    })).unwrap();
    assert!(rust_build_config_from_manifest(manifest).is_err());
}
#[test]
fn configured_manifest_requires_root_bit() {
    let manifest: BuilderManifestFile = serde_json::from_value(json!({
        "version": 9, "fingerprint": "x", "trigger_digest": "digest", "worker_entrypoint": "worker.dart",
        "trigger_digest": "stock-trigger-digest",
        "definitions": [{
        "required_input_suffixes": [],
        "excluded_input_suffixes": [],
        "generate_for": [],
        "generate_for_exclude": [],
        "target_sources": [],
        "target_sources_exclude": [],
        "triggers": [],
        "options": {},
        "is_optional": false,
        "output_is_optional": false,"id": "app:copy", "kind": "normal", "extensions": [{"input_suffix": ".txt", "input_match": "suffix", "input_anchored": false, "output_suffixes": [".out"]}], "phase": 0, "build_to": "source"}],
        "builders": [{
        "required_input_suffixes": [],
        "excluded_input_suffixes": [],
        "generate_for_exclude": [],
        "target_sources": [],
        "target_sources_exclude": [],
        "triggers": [],
        "options": {},
        "is_optional": false,
        "output_is_optional": false,
        "target_order": 0,"id": "app:copy", "kind": "normal", "phase": 0, "build_to": "source", "target": "app:app", "package": "app", "generate_for": ["**"]}]
    })).unwrap();
    let error = rust_build_config_from_manifest(manifest).unwrap_err();
    assert!(error.to_string().contains("is_root"));
}
