    use super::{rust_build_config_from_manifest, BuilderManifestFile};
    use crate::builder::{BuildTo, BuilderKind};
    use serde_json::json;

    #[test]
    fn dynamic_manifest_preserves_builder_phase_order() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "source",
                    "phase": 1,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                },
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "source",
                    "phase": 0,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                }
            ],
            "definitions": [
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "source",
                    "phase": 1
                },
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "cache",
                    "phase": 3,
                    "target_order": 0,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                },
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
                    "build_to": "cache",
                    "phase": 7,
                    "target_order": 0,
                    "target": "example:example",
                    "package": "example",
                    "generate_for": ["lib/**/*.txt"]
                }
            ],
            "definitions": [
                {
                    "id": "example:phase-one",
                    "input_suffix": ".txt",
                    "output_suffixes": [".one"],
                    "build_to": "cache",
                    "phase": 0
                },
                {
                    "id": "example:phase-two",
                    "input_suffix": ".txt",
                    "output_suffixes": [".two"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "excluded_input_suffixes": [".later.txt"],
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt"],
                "build_to": "source",
                "phase": 0,
                "excluded_input_suffixes": [".all.txt"]
            }]
        }))
        .unwrap();
        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert_eq!(
            config.builders[0].excluded_input_suffixes,
            [".later.txt"]
        );
        assert_eq!(
            config.builders[0].definition.excluded_input_suffixes,
            [".all.txt"]
        );
    }

    #[test]
    fn dynamic_manifest_preserves_multiple_outputs() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt", ".meta.txt"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".gen.txt", ".meta.txt"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".generated"],
                "required_input_suffixes": [".first", ".second"],
                "build_to": "cache",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffixes": [".generated"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:optional",
                "input_suffix": ".txt",
                "output_suffixes": [".optional.txt"],
                "is_optional": true,
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:optional",
                "input_suffix": ".txt",
                "output_suffixes": [".optional.txt"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "trigger_digest": "trigger-digest",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.dart"],
                "triggers": [
                    {"kind": "import", "value": "example/marker.dart"},
                    {"kind": "annotation", "value": "Marker"}
                ]
            }],
            "definitions": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.dart"]
            }],
            "definitions": [{
                "id": "example:trigger",
                "input_suffix": ".dart",
                "output_suffixes": [".generated.dart"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "extensions": [
                    {
                        "input_suffix": ".txt",
                        "input_match": "suffix",
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
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "extensions": [
                    {
                        "input_suffix": ".txt",
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:all",
                "extensions": [{
                    "input_suffix": "",
                    "input_match": "all",
                    "output_suffixes": [".all"]
                }],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["**"]
            }],
            "definitions": [{
                "id": "example:all",
                "extensions": [{
                    "input_suffix": "",
                    "input_match": "all",
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:all",
                "input_suffix": ".dart",
                "input_match": "all",
                "output_suffixes": [".all"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["**"]
            }],
            "definitions": [{
                "id": "example:all",
                "input_suffix": ".dart",
                "input_match": "all",
                "output_suffixes": [".all"],
                "build_to": "source",
                "phase": 0
            }]
        }))
        .unwrap();
        let error = rust_build_config_from_manifest(manifest).unwrap_err();
        assert!(error.to_string().contains("unsupported build extension metadata"));
    }

    #[test]
    fn dynamic_manifest_accepts_post_process_definition() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:post",
                "kind": "post_process",
                "input_extensions": [".gen.txt"],
                "build_to": "cache",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.gen.txt"]
            }],
            "definitions": [{
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
            config.builders[0]
                .definition
                .post_process_input_extensions,
            [".gen.txt"]
        );
        assert!(config.builders[0].definition.extensions.is_empty());
        assert!(config.builders[0].definition.output_is_optional);
    }

    #[test]
    fn dynamic_manifest_accepts_source_post_process_definition() {
        let manifest: BuilderManifestFile = serde_json::from_value(json!({
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:post",
                "kind": "post_process",
                "input_extensions": [".gen.txt"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.gen.txt"]
            }],
            "definitions": [{
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffix": ".gen.txt",
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".txt",
                "output_suffix": ".gen.txt",
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:capture",
                "input_suffix": "lib/assets/{{dir}}/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": true,
                "output_suffixes": ["lib/generated/{{dir}}/{{file}}.dart"],
                "build_to": "source",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "generate_for": ["lib/assets/**/*.txt"]
            }],
            "definitions": [{
                "id": "example:capture",
                "input_suffix": "lib/assets/{{dir}}/{{file}}.txt",
                "input_match": "capture",
                "input_anchored": true,
                "output_suffixes": ["lib/generated/{{dir}}/{{file}}.dart"],
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
            "version": 8,
            "fingerprint": "fingerprint",
            "worker_entrypoint": "dynamic_worker.dart",
            "builders": [{
                "id": "example:builder",
                "input_suffix": ".dart",
                "output_suffixes": [".static"],
                "build_to": "cache",
                "phase": 0,
                "target": "example:example",
                "package": "example",
                "is_root": false,
                "generate_for": ["**"],
                "runtime_mapping": {
                    "extensions": [{
                        "input_suffix": ".dart",
                        "output_suffixes": [".runtime"]
                    }]
                }
            }],
            "definitions": [{
                "id": "example:builder",
                "input_suffix": ".dart",
                "output_suffixes": [".static"],
                "build_to": "cache",
                "phase": 0
            }]
        })).unwrap();

        let config = rust_build_config_from_manifest(manifest).unwrap();
        assert!(!config.builders[0].is_root);
        assert_eq!(
            config.builders[0].definition.extensions[0].output_suffixes,
            [".static".to_owned()]
        );
        assert_eq!(
            config.builders[0]
                .effective_definition()
                .extensions[0]
                .output_suffixes,
            [".runtime"]
        );
    }
