#[test]
fn dirty_context_handles_unchanged_cycles_and_snapshot_changes() {
    let mut state = super::GraphState::default();
    for asset in ["a", "b", "c"] {
        state.assets.insert(
            asset.to_owned(),
            crate::snapshot::AssetSnapshot {
                exists: true,
                digest: "original".to_owned(),
                size: 1,
            },
        );
    }
    state.resolver_dep_graph = std::collections::BTreeMap::from([
        ("a".to_owned(), vec!["b".to_owned()]),
        (
            "b".to_owned(),
            vec!["a".to_owned(), "c".to_owned(), "missing".to_owned()],
        ),
    ]);
    let mut current = state.assets.clone();
    // Size is not dirty evidence: keep the presence/digest contract.
    current.get_mut("a").unwrap().size = 99;
    let context = state.dirty_context(&current);
    assert!(context.changed.is_empty());
    assert!(context.tainted.is_empty());
    assert!(context.reverse_deps().is_none());
    for case in ["digest", "exists", "removed", "added"] {
        let mut current = state.assets.clone();
        let changed = match case {
            "digest" => {
                current.get_mut("c").unwrap().digest.push('!');
                "c"
            }
            "exists" => {
                current.get_mut("c").unwrap().exists = false;
                "c"
            }
            "removed" => {
                current.remove("c");
                "c"
            }
            _ => {
                current.insert("missing".to_owned(), state.assets["c"].clone());
                "missing"
            }
        };
        let context = state.dirty_context(&current);
        assert_eq!(
            context.changed,
            std::collections::HashSet::from([changed]),
            "{case}"
        );
        assert_eq!(
            context.tainted,
            std::collections::HashSet::from([changed, "a", "b"]),
            "{case}"
        );
        assert_eq!(
            context.reverse_deps(),
            Some(&super::reverse_resolver_deps(&state.resolver_dep_graph)),
            "{case}"
        );
    }
}

#[test]
fn dirty_context_matches_lookup_reference_for_interleaved_snapshots() {
    // Every key is absent, missing, or present in each snapshot. Exhaustive
    // pairs cover empty maps, additions/removals at both tails and in the
    // middle, and equal IDs with different existence or content evidence.
    fn snapshot(mut pattern: usize, newer: bool) -> super::Snapshot {
        let mut result = super::Snapshot::new();
        for key in ["a", "b", "c", "d"] {
            match pattern % 3 {
                0 => {}
                state => {
                    result.insert(
                        key.to_owned(),
                        AssetSnapshot {
                            exists: state == 2,
                            digest: if newer && key == "b" { "new" } else { "old" }.into(),
                            size: u64::from(newer),
                        },
                    );
                }
            }
            pattern /= 3;
        }
        result
    }
    for previous in 0..81 {
        let state = super::GraphState {
            assets: snapshot(previous, false),
            // Duplicate edges, a cycle, and an absent dependency must not
            // alter the reverse closure or make its traversal unbounded.
            resolver_dep_graph: std::collections::BTreeMap::from([
                ("a".into(), vec!["b".into(), "b".into()]),
                ("b".into(), vec!["a".into(), "c".into()]),
                ("c".into(), vec!["d".into(), "missing".into()]),
            ]),
            ..Default::default()
        };
        for next in 0..81 {
            let current = snapshot(next, true);
            let expected: std::collections::HashSet<_> = state
                .assets
                .keys()
                .chain(current.keys())
                .filter(|key| {
                    let evidence = |entry: Option<&AssetSnapshot>| {
                        entry.map(|entry| (entry.exists, entry.digest.clone()))
                    };
                    evidence(state.assets.get(*key)) != evidence(current.get(*key))
                })
                .map(String::as_str)
                .collect();
            let mut tainted = expected.clone();
            loop {
                let before = tainted.len();
                for (node, deps) in &state.resolver_dep_graph {
                    if deps.iter().any(|dep| tainted.contains(dep.as_str())) {
                        tainted.insert(node.as_str());
                    }
                }
                if tainted.len() == before {
                    break;
                }
            }
            let actual = state.dirty_context(&current);
            assert_eq!(actual.changed, expected, "{previous}/{next}");
            assert_eq!(actual.tainted, tainted, "{previous}/{next}");
        }
    }
}

#[test]
fn resolver_cycle_detection_handles_shared_children_and_missing_leaves() {
    let mut state = super::GraphState {
        resolver_dep_graph: std::collections::BTreeMap::from([
            ("a".to_owned(), vec!["c".to_owned()]),
            ("b".to_owned(), vec!["c".to_owned()]),
            ("c".to_owned(), vec!["leaf".to_owned()]),
        ]),
        ..super::GraphState::default()
    };
    assert!(!state.has_resolver_cycle());
    state
        .resolver_dep_graph
        .insert("leaf".to_owned(), vec!["a".to_owned()]);
    assert!(state.has_resolver_cycle());
}
use super::codec::{Encoder, GRAPH_FORMAT_VERSION, GRAPH_MAGIC};
use super::{ActionState, GraphState};
use crate::protocol::GlobRead;
use crate::snapshot::{AssetSnapshot, Snapshot, glob_asset_key};
use std::collections::{BTreeMap, BTreeSet};

fn state_with_glob(glob: &GlobRead, digest: &str) -> GraphState {
    let mut assets = Snapshot::new();
    assets.insert(
        glob_asset_key(glob),
        AssetSnapshot {
            exists: true,
            digest: digest.to_owned(),
            size: 0,
        },
    );
    GraphState {
        schema_version: super::GRAPH_SCHEMA_VERSION,
        config_digest: String::new(),
        was_filtered: false,
        fingerprint_tracker: Default::default(),
        assets,
        actions: BTreeMap::new(),
        resolver_dep_graph: BTreeMap::new(),
        asset_fingerprints: BTreeMap::new(),
        output_locations: BTreeMap::new(),
        stock_input_order: BTreeMap::new(),
        stock_glob_members: BTreeMap::new(),
        watch_generated_sources: BTreeSet::new(),
        retained_output_state: false,
    }
}

fn action(glob: GlobRead) -> ActionState {
    ActionState {
        builder: "example:combining_builder".to_owned(),
        input: "app|lib/model.dart".to_owned(),
        glob_reads: vec![glob],
        status: "success".to_owned(),
        ..ActionState::default()
    }
}

#[test]
fn glob_membership_change_marks_action_dirty() {
    let glob = GlobRead {
        package: "app".to_owned(),
        pattern: "lib/model.*.part".to_owned(),
    };
    let state = state_with_glob(&glob, "before");
    let mut current = state.assets.clone();
    current
        .get_mut(&glob_asset_key(&glob))
        .expect("glob snapshot")
        .digest = "after".to_owned();

    assert!(state.changed_since_previous(&action(glob), &current, &BTreeMap::new()));
}

#[test]
fn unchanged_glob_does_not_mark_action_dirty() {
    let glob = GlobRead {
        package: "app".to_owned(),
        pattern: "lib/model.*.part".to_owned(),
    };
    let state = state_with_glob(&glob, "same");
    assert!(!state.changed_since_previous(&action(glob), &state.assets, &BTreeMap::new()));
}

#[test]
fn missing_dependency_becoming_present_marks_action_dirty() {
    let dependency = "app|lib/conditional.dart".to_owned();
    let mut assets = Snapshot::new();
    assets.insert(
        dependency.clone(),
        AssetSnapshot {
            exists: false,
            digest: "<missing>".to_owned(),
            size: 0,
        },
    );
    let state = GraphState {
        schema_version: super::GRAPH_SCHEMA_VERSION,
        assets,
        ..GraphState::default()
    };
    let action = ActionState {
        builder: "example:builder".to_owned(),
        input: "app|lib/model.dart".to_owned(),
        resolver_reads: vec![dependency.clone()],
        status: "success".to_owned(),
        ..ActionState::default()
    };
    let mut current = state.assets.clone();
    current.insert(
        dependency,
        AssetSnapshot {
            exists: true,
            digest: "actual".to_owned(),
            size: 1,
        },
    );

    assert!(state.changed_since_previous(&action, &current, &BTreeMap::new()));
}

#[test]
fn schema_8_graph_body_decodes_for_recovery_validation() {
    // A journal written by the schema 8 binary lacks the schema 9
    // fields. Publication recovery validates that body with
    // decode_checked(.., false) before ordinary load invalidation
    // can run, so it must decode with its own layout.
    let previous = GraphState {
        schema_version: 8,
        config_digest: "previous configuration".to_owned(),
        asset_fingerprints: BTreeMap::from([(
            "app|lib/model.dart".to_owned(),
            crate::protocol::ApiFingerprintRecord {
                digest: "digest".to_owned(),
                fingerprint: "fingerprint".to_owned(),
            },
        )]),
        actions: BTreeMap::from([(
            "step".to_owned(),
            ActionState {
                resolver_content_reads: vec!["app|lib/dep.dart".to_owned()],
                ..ActionState::default()
            },
        )]),
        ..GraphState::default()
    };
    let mut encoder = Encoder::new();
    encoder.write_graph_state(&previous).unwrap();
    let payload = encoder.finish();
    let mut bytes = GRAPH_MAGIC.to_vec();
    bytes.push(GRAPH_FORMAT_VERSION);
    bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&payload);
    let decoded = GraphState::decode_checked(&bytes, false).unwrap();
    assert_eq!(decoded.config_digest, "previous configuration");
    assert!(decoded.asset_fingerprints.is_empty());
    assert!(decoded.actions["step"].resolver_content_reads.is_empty());
}

#[test]
fn schema_9_graph_body_decodes_for_recovery_validation() {
    // A journal written by the schema 9 binary stores bare
    // fingerprint strings and already has resolver content
    // reads. Publication recovery validates that body with
    // decode_checked(.., false) before ordinary load
    // invalidation can run, so it must decode with its own
    // layout; the fingerprints come back with an empty digest,
    // which no snapshot digest can match.
    let previous = GraphState {
        schema_version: 9,
        config_digest: "previous configuration".to_owned(),
        asset_fingerprints: BTreeMap::from([(
            "app|lib/model.dart".to_owned(),
            crate::protocol::ApiFingerprintRecord {
                digest: "digest".to_owned(),
                fingerprint: "fingerprint".to_owned(),
            },
        )]),
        actions: BTreeMap::from([(
            "step".to_owned(),
            ActionState {
                resolver_content_reads: vec!["app|lib/dep.dart".to_owned()],
                ..ActionState::default()
            },
        )]),
        ..GraphState::default()
    };
    let mut encoder = Encoder::new();
    encoder.write_graph_state(&previous).unwrap();
    let payload = encoder.finish();
    let mut bytes = GRAPH_MAGIC.to_vec();
    bytes.push(GRAPH_FORMAT_VERSION);
    bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&payload);
    let decoded = GraphState::decode_checked(&bytes, false).unwrap();
    assert_eq!(decoded.config_digest, "previous configuration");
    assert_eq!(
        decoded.asset_fingerprints["app|lib/model.dart"],
        crate::protocol::ApiFingerprintRecord {
            digest: String::new(),
            fingerprint: "fingerprint".to_owned(),
        }
    );
    assert_eq!(
        decoded.actions["step"].resolver_content_reads,
        vec!["app|lib/dep.dart".to_owned()]
    );
}

#[test]
fn old_graph_schema_is_not_compatible() {
    let state = GraphState {
        schema_version: 1,
        config_digest: "same".to_owned(),
        ..GraphState::default()
    };
    assert!(!state.is_compatible("same"));
}

#[test]
fn binary_graph_round_trip_preserves_state() {
    let state = GraphState {
        schema_version: super::GRAPH_SCHEMA_VERSION,
        config_digest: "config".to_owned(),
        was_filtered: true,
        fingerprint_tracker: Default::default(),
        retained_output_state: true,
        watch_generated_sources: BTreeSet::from(["app|lib/omitted.mid".to_owned()]),
        stock_glob_members: BTreeMap::from([(
            "step".to_owned(),
            BTreeMap::from([(
                "app|lib/*.dart".to_owned(),
                vec![
                    "app|lib/source.dart".to_owned(),
                    "app|lib/generated.dart".to_owned(),
                ],
            )]),
        )]),
        stock_input_order: BTreeMap::from([(
            "step".to_owned(),
            vec!["app|lib/b.dart".to_owned(), "app|lib/a.dart".to_owned()],
        )]),
        output_locations: BTreeMap::from([("app|lib/model.g.dart".to_owned(), true)]),
        assets: Snapshot::from([(
            "app|lib/model.dart".to_owned(),
            AssetSnapshot {
                exists: true,
                digest: "asset-digest".to_owned(),
                size: 12,
            },
        )]),
        resolver_dep_graph: BTreeMap::from([(
            "app|lib/model.dart".to_owned(),
            vec!["app|lib/conditional.dart".to_owned()],
        )]),
        asset_fingerprints: BTreeMap::from([(
            "app|lib/model.dart".to_owned(),
            crate::protocol::ApiFingerprintRecord {
                digest: "digest".to_owned(),
                fingerprint: "fingerprint".to_owned(),
            },
        )]),
        actions: BTreeMap::from([(
            "example:builder|app|lib/model.dart".to_owned(),
            ActionState {
                shared_part: Some(crate::shared_library::SharedContribution {
                    header: "// dart format off\npart of '../model.dart';\n\n".into(),
                    imports: "// === example:builder imports.\nimport 'dart:math' as i0;\n\n"
                        .into(),
                    source: "// === example:builder contribution.\nclass Generated {}\n\n".into(),
                }),
                builder: "example:builder".to_owned(),
                input: "app|lib/model.dart".to_owned(),
                reads: vec!["app|lib/model.dart".to_owned()],
                resolver_reads: vec!["app|lib/conditional.dart".to_owned()],
                resolver_content_reads: vec!["app|lib/other.dart".to_owned()],
                resolver_entrypoints: vec!["app|lib/model.dart".to_owned()],
                glob_reads: vec![GlobRead {
                    package: "app".to_owned(),
                    pattern: "lib/*.part".to_owned(),
                }],
                outputs: vec!["app|lib/model.g.dart".to_owned()],
                output_digests: BTreeMap::from([(
                    "app|lib/model.g.dart".to_owned(),
                    "output-digest".to_owned(),
                )]),
                status: "success".to_owned(),
            },
        )]),
    };
    let unique = format!(
        "build-runner-accelerator-graph-{}-{}.bin",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos()
    );
    let path = std::env::temp_dir().join(unique);

    state.save(&path).expect("save graph");
    let bytes = std::fs::read(&path).expect("read graph");
    assert_eq!(&bytes[..GRAPH_MAGIC.len()], GRAPH_MAGIC);
    assert_eq!(bytes[GRAPH_MAGIC.len()], GRAPH_FORMAT_VERSION);
    assert_eq!(
        GraphState::load_without_recovery(&path).expect("load graph"),
        state
    );

    std::fs::remove_file(path).expect("remove graph");
}

#[test]
fn merge_api_fingerprints_replaces_and_removes() {
    fn record(digest: &str, fingerprint: &str) -> crate::protocol::ApiFingerprintRecord {
        crate::protocol::ApiFingerprintRecord {
            digest: digest.to_owned(),
            fingerprint: fingerprint.to_owned(),
        }
    }
    let mut state = GraphState {
        asset_fingerprints: BTreeMap::from([
            ("app|lib/a.dart".to_owned(), record("d-old", "old")),
            ("app|lib/b.dart".to_owned(), record("d-b", "kept")),
        ]),
        ..GraphState::default()
    };
    state.merge_api_fingerprints(BTreeMap::from([
        ("app|lib/a.dart".to_owned(), Some(record("d-new", "new"))),
        ("app|lib/b.dart".to_owned(), None),
        ("app|lib/c.dart".to_owned(), Some(record("d-c", "added"))),
        ("app|lib/d.dart".to_owned(), None),
    ]));
    assert_eq!(
        state.asset_fingerprints,
        BTreeMap::from([
            ("app|lib/a.dart".to_owned(), record("d-new", "new")),
            ("app|lib/c.dart".to_owned(), record("d-c", "added")),
        ])
    );
}

#[test]
fn merge_api_fingerprints_drops_conflicting_reports_for_the_build() {
    fn record(digest: &str, fingerprint: &str) -> crate::protocol::ApiFingerprintRecord {
        crate::protocol::ApiFingerprintRecord {
            digest: digest.to_owned(),
            fingerprint: fingerprint.to_owned(),
        }
    }
    let mut state = GraphState::default();
    // Two workers observe the same asset at different bytes after
    // a mid-build edit: neither report can be trusted as the
    // basis for the build's outputs, so the evidence is dropped.
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/a.dart".to_owned(),
        Some(record("d-1", "f-1")),
    )]));
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/a.dart".to_owned(),
        Some(record("d-2", "f-2")),
    )]));
    assert!(!state.asset_fingerprints.contains_key("app|lib/a.dart"));
    // A later report in the same build cannot resurrect it, even
    // one that agrees with the first observation.
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/a.dart".to_owned(),
        Some(record("d-1", "f-1")),
    )]));
    assert!(!state.asset_fingerprints.contains_key("app|lib/a.dart"));
    // An unavailable report after a recorded one is a
    // disagreement too, and a later agreeing report cannot
    // resurrect the evidence within the build.
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/c.dart".to_owned(),
        Some(record("d-c", "f-c")),
    )]));
    state.merge_api_fingerprints(BTreeMap::from([("app|lib/c.dart".to_owned(), None)]));
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/c.dart".to_owned(),
        Some(record("d-c", "f-c")),
    )]));
    assert!(!state.asset_fingerprints.contains_key("app|lib/c.dart"));
    // Agreeing reports are kept, and the next build boundary
    // clears the conflict so fresh evidence counts again.
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/b.dart".to_owned(),
        Some(record("d-b", "f-b")),
    )]));
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/b.dart".to_owned(),
        Some(record("d-b", "f-b")),
    )]));
    assert_eq!(
        state.asset_fingerprints.get("app|lib/b.dart"),
        Some(&record("d-b", "f-b"))
    );
    state.update_assets(BTreeMap::from([(
        "app|lib/a.dart".to_owned(),
        crate::snapshot::AssetSnapshot {
            exists: true,
            digest: "d-1".to_owned(),
            size: 1,
        },
    )]));
    assert!(!state.fingerprint_tracker.has_conflicts());
    state.merge_api_fingerprints(BTreeMap::from([(
        "app|lib/a.dart".to_owned(),
        Some(record("d-1", "f-1")),
    )]));
    assert_eq!(
        state.asset_fingerprints.get("app|lib/a.dart"),
        Some(&record("d-1", "f-1"))
    );
}

#[test]
fn update_assets_drops_fingerprints_of_changed_and_removed_assets() {
    let entry = |digest: &str| crate::snapshot::AssetSnapshot {
        exists: true,
        digest: digest.to_owned(),
        size: 1,
    };
    let record = |fingerprint: &str| crate::protocol::ApiFingerprintRecord {
        digest: format!("d-{fingerprint}"),
        fingerprint: fingerprint.to_owned(),
    };
    let mut state = GraphState {
        assets: BTreeMap::from([
            ("app|lib/a.dart".to_owned(), entry("aaa")),
            ("app|lib/b.dart".to_owned(), entry("bbb")),
            ("app|lib/c.dart".to_owned(), entry("ccc")),
        ]),
        asset_fingerprints: BTreeMap::from([
            ("app|lib/a.dart".to_owned(), record("fa")),
            ("app|lib/b.dart".to_owned(), record("fb")),
            ("app|lib/c.dart".to_owned(), record("fc")),
        ]),
        ..GraphState::default()
    };
    state.update_assets(BTreeMap::from([
        ("app|lib/a.dart".to_owned(), entry("aaa")),
        ("app|lib/b.dart".to_owned(), entry("changed")),
    ]));
    assert_eq!(
        state.asset_fingerprints,
        BTreeMap::from([("app|lib/a.dart".to_owned(), record("fa"))])
    );
}

#[test]
fn superseded_or_deleted_reports_are_dropped() {
    let entry = |digest: &str| crate::snapshot::AssetSnapshot {
        exists: true,
        digest: digest.to_owned(),
        size: 1,
    };
    let record = |fingerprint: &str| crate::protocol::ApiFingerprintRecord {
        digest: format!("d-{fingerprint}"),
        fingerprint: fingerprint.to_owned(),
    };
    let mut state = GraphState {
        assets: BTreeMap::from([
            ("app|lib/a.dart".to_owned(), entry("aaa")),
            ("app|lib/gone.dart".to_owned(), entry("ggg")),
            ("app|lib/restored.dart".to_owned(), entry("rrr")),
        ]),
        ..GraphState::default()
    };
    state.merge_api_fingerprints(BTreeMap::from([
        ("app|lib/a.dart".to_owned(), Some(record("fresh-a"))),
        ("app|lib/gone.dart".to_owned(), Some(record("fresh-g"))),
        (
            "app|lib/restored.dart".to_owned(),
            Some(record("intermediate")),
        ),
    ]));
    // The transaction rewrote a.dart after the walk fingerprinted
    // it and restored restored.dart to its previous bytes: neither
    // report is evidence for the committed bytes, and the
    // previous-vs-final comparison cannot tell for restored.dart.
    // gone.dart is absent from the final snapshot.
    state.supersede_api_fingerprint_reports(&BTreeSet::from([
        "app|lib/a.dart".to_owned(),
        "app|lib/restored.dart".to_owned(),
    ]));
    state.update_assets(BTreeMap::from([
        ("app|lib/a.dart".to_owned(), entry("changed")),
        ("app|lib/restored.dart".to_owned(), entry("rrr")),
    ]));
    assert!(state.asset_fingerprints.is_empty());
}

#[test]
fn update_assets_keeps_fingerprints_reported_by_the_current_build() {
    let entry = |digest: &str| crate::snapshot::AssetSnapshot {
        exists: true,
        digest: digest.to_owned(),
        size: 1,
    };
    let record = |fingerprint: &str| crate::protocol::ApiFingerprintRecord {
        digest: format!("d-{fingerprint}"),
        fingerprint: fingerprint.to_owned(),
    };
    let mut state = GraphState {
        assets: BTreeMap::from([("app|lib/a.dart".to_owned(), entry("aaa"))]),
        asset_fingerprints: BTreeMap::from([("app|lib/a.dart".to_owned(), record("stale"))]),
        ..GraphState::default()
    };
    // The build relearns the edited asset and a brand-new one;
    // both reports are fresh evidence for the new snapshot.
    state.merge_api_fingerprints(BTreeMap::from([
        ("app|lib/a.dart".to_owned(), Some(record("fresh"))),
        ("app|lib/new.dart".to_owned(), Some(record("new"))),
    ]));
    state.update_assets(BTreeMap::from([
        ("app|lib/a.dart".to_owned(), entry("changed")),
        ("app|lib/new.dart".to_owned(), entry("nnn")),
    ]));
    assert_eq!(
        state.asset_fingerprints,
        BTreeMap::from([
            ("app|lib/a.dart".to_owned(), record("fresh")),
            ("app|lib/new.dart".to_owned(), record("new")),
        ])
    );
}

#[test]
fn old_binary_format_and_schema_are_discarded_without_removing_files() {
    let root = std::env::temp_dir().join(format!("accelerator-old-graph-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("graph.bin");
    let source = root.join("source.dart");
    let output = root.join("source.g.dart");
    std::fs::write(&source, b"user source").unwrap();
    std::fs::write(&output, b"existing output").unwrap();
    for (format, schema) in [
        (1, super::GRAPH_SCHEMA_VERSION),
        (2, super::GRAPH_SCHEMA_VERSION),
        (99, super::GRAPH_SCHEMA_VERSION),
        (GRAPH_FORMAT_VERSION, 1),
        (GRAPH_FORMAT_VERSION, 7),
        (GRAPH_FORMAT_VERSION, 8),
    ] {
        let previous = GraphState {
            schema_version: schema,
            config_digest: "obsolete configuration".to_owned(),
            ..GraphState::default()
        };
        let mut encoder = Encoder::new();
        encoder.write_graph_state(&previous).unwrap();
        let mut payload = encoder.finish();
        match format {
            // Empty format-1 metadata ends after resolver edges.
            1 => payload.truncate(payload.len() - 17),
            2 => {
                payload.pop();
            }
            _ => {}
        }
        let mut bytes = GRAPH_MAGIC.to_vec();
        bytes.push(format);
        bytes.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&payload);
        std::fs::write(&path, &bytes).unwrap();
        let state = GraphState::load_without_recovery(&path).unwrap();
        assert!(state.actions.is_empty());
        assert!(state.config_digest.is_empty());
        assert_eq!(state.schema_version, super::GRAPH_SCHEMA_VERSION);
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert_eq!(std::fs::read(&source).unwrap(), b"user source");
        assert_eq!(std::fs::read(&output).unwrap(), b"existing output");
    }
    assert!(
        GraphState::load_without_recovery(&root).is_err(),
        "filesystem IO errors stay explicit"
    );
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn graph_requires_binary_header() {
    let unique = format!(
        "build-runner-accelerator-invalid-{}-{}.bin",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos()
    );
    let path = std::env::temp_dir().join(unique);
    std::fs::write(&path, b"{}\n").expect("write invalid graph");

    let error = GraphState::load_checked(&path).expect_err("invalid graph should fail");
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    let recovered = GraphState::load_without_recovery(&path).expect("regenerate invalid graph");
    assert!(recovered.actions.is_empty());
    assert!(path.exists());

    std::fs::remove_file(path).expect("remove invalid graph");
}

#[test]
fn unchanged_metadata_does_not_require_persist() {
    let assets = Snapshot::new();
    let mut state = GraphState {
        schema_version: super::GRAPH_SCHEMA_VERSION,
        config_digest: "same".to_owned(),
        assets: assets.clone(),
        ..GraphState::default()
    };

    assert!(!state.update_metadata_if_changed("same", assets));
}

#[test]
fn changed_metadata_is_applied_and_requires_persist() {
    let mut state = GraphState {
        schema_version: 1,
        config_digest: "old".to_owned(),
        ..GraphState::default()
    };
    let mut assets = Snapshot::new();
    assets.insert(
        "app|lib/model.dart".to_owned(),
        AssetSnapshot {
            exists: true,
            digest: "digest".to_owned(),
            size: 6,
        },
    );

    assert!(state.update_metadata_if_changed("new", assets.clone()));
    assert_eq!(state.schema_version, super::GRAPH_SCHEMA_VERSION);
    assert_eq!(state.config_digest, "new");
    assert_eq!(state.assets, assets);
}
