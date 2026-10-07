use super::dirty::expand_dirty_dependents;
use super::execution::execution_order;
use super::part_directive::declares_part_directive;
use crate::builder::{BuildTo, BuilderDefinition, BuilderKind, ConfiguredBuilder, RustBuildConfig};
use crate::graph::{ActionState, GraphState};
use crate::plan::BuildSpec;
use crate::workspace::Workspace;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

fn configured_builder(id: &str, target: &str, target_order: u32, phase: u32) -> ConfiguredBuilder {
    ConfiguredBuilder {
        definition: Arc::new(BuilderDefinition {
            id: id.to_owned(),
            kind: BuilderKind::Normal,
            extensions: Vec::new(),
            post_process_input_extensions: Vec::new(),
            build_to: BuildTo::Source,
            phase,
            is_optional: false,
            output_is_optional: false,
            required_input_suffixes: Vec::new(),
            excluded_input_suffixes: Vec::new(),
            applies_builder: None,
            triggers: Vec::new(),
        }),
        target: target.to_owned(),
        package: "app".to_owned(),
        is_root: true,
        target_order,
        phase,
        excluded_input_suffixes: Vec::new(),
        generate_for: vec!["**".to_owned()],
        generate_for_exclude: Vec::new(),
        target_sources: vec!["**".to_owned()],
        target_sources_exclude: Vec::new(),
        options: BTreeMap::new(),
        runtime_extensions: None,
        runtime_post_process_input_extensions: None,
        part_directive_suffix: None,
    }
}

fn build_spec(builder: &ConfiguredBuilder, input: &str, outputs: &[&str]) -> BuildSpec {
    BuildSpec {
        builder: builder.definition.clone(),
        target: builder.target.clone(),
        package: builder.package.clone(),
        is_root: builder.is_root,
        phase: builder.phase,
        instance_key: format!(
            "{}|{}|{}|{}",
            builder.target, builder.definition.id, builder.phase, builder.package
        ),
        input: input.to_owned(),
        outputs: outputs.iter().map(|output| (*output).to_owned()).collect(),
        options: builder.options.clone(),
        part_directive_suffix: None,
    }
}

#[test]
fn execution_order_runs_cross_target_producer_before_consumer() {
    let builders = vec![
        // Target 0 consumes an output produced by target 1 in an earlier
        // phase. Phase order must win over target order.
        configured_builder("consumer", "app:consumer", 0, 1),
        configured_builder("producer", "app:producer", 1, 0),
    ];

    assert_eq!(execution_order(&builders), vec![1, 0]);
}

#[test]
fn dirty_dependents_use_planned_outputs_and_primary_inputs() {
    let producer_builder = configured_builder("producer", "app:producer", 0, 0);
    let consumer_builder = configured_builder("consumer", "app:consumer", 1, 1);
    let producer = build_spec(
        &producer_builder,
        "app|lib/seed.dart",
        &["app|lib/generated.dart"],
    );
    let consumer = build_spec(
        &consumer_builder,
        "app|lib/generated.dart",
        &["app|lib/consumer.txt"],
    );
    let state = GraphState {
        actions: BTreeMap::from([
            (
                producer.action_key(),
                ActionState {
                    builder: producer.builder.id.clone(),
                    input: producer.input.clone(),
                    status: "not_triggered".to_owned(),
                    ..ActionState::default()
                },
            ),
            (
                consumer.action_key(),
                ActionState {
                    builder: consumer.builder.id.clone(),
                    input: consumer.input.clone(),
                    status: "skipped_missing_input".to_owned(),
                    ..ActionState::default()
                },
            ),
        ]),
        ..GraphState::default()
    };
    let mut dirty = vec![producer.clone()];

    expand_dirty_dependents(&mut dirty, &[producer.clone(), consumer.clone()], &state);

    assert_eq!(
        dirty.iter().map(BuildSpec::action_key).collect::<Vec<_>>(),
        vec![producer.action_key(), consumer.action_key()]
    );

    // A producer with no prior output can emit a planned output after its
    // input changes, so the skipped consumer must be reconsidered this build.
    let mut successful_empty_state = state;
    successful_empty_state
        .actions
        .get_mut(&producer.action_key())
        .expect("producer action exists")
        .status = "success".to_owned();
    let mut dirty = vec![producer.clone()];
    expand_dirty_dependents(
        &mut dirty,
        &[producer.clone(), consumer.clone()],
        &successful_empty_state,
    );
    assert_eq!(
        dirty.iter().map(BuildSpec::action_key).collect::<Vec<_>>(),
        vec![producer.action_key(), consumer.action_key()]
    );
}

#[test]
fn part_directive_scanner_matches_source_gen_semantics() {
    // Declared with the expected URI.
    assert!(declares_part_directive(
        "part 'foo.g.dart';\n",
        "foo.g.dart"
    ));
    // Double quotes, extra spacing, raw-string prefix, leading directives.
    assert!(declares_part_directive(
        "library x;\npart   \"foo.g.dart\";\n",
        "foo.g.dart"
    ));
    assert!(declares_part_directive("part r'foo.g.dart';", "foo.g.dart"));
    assert!(declares_part_directive(
        "import 'a.dart';\npart 'other.dart';\npart 'foo.g.dart';",
        "foo.g.dart"
    ));
    // Different URI does not qualify.
    assert!(!declares_part_directive("part 'foo.g.dart';", "bar.g.dart"));
    assert!(!declares_part_directive(
        "part 'foo.freezed.dart';",
        "foo.g.dart"
    ));
    // `part of` is a part-of declaration, never a part list.
    assert!(!declares_part_directive(
        "part of 'foo.g.dart';",
        "foo.g.dart"
    ));
    assert!(!declares_part_directive("part of foo;\n", "foo.g.dart"));
    // Word boundary: "departure" and "parts" are not the keyword.
    assert!(!declares_part_directive(
        "departure 'foo.g.dart';\n",
        "foo.g.dart"
    ));
    // A `part 'uri'` shape inside a comment over-matches to running the
    // action — the conservative direction.
    assert!(declares_part_directive(
        "// part 'foo.g.dart' is missing\nimport 'dart:io';",
        "foo.g.dart"
    ));
    // Comments between `part` and the URI are valid Dart trivia.
    assert!(declares_part_directive(
        "part /* note */ 'foo.g.dart';",
        "foo.g.dart"
    ));
    assert!(declares_part_directive(
        "part // note\n'foo.g.dart';",
        "foo.g.dart"
    ));
    // Unterminated comment or an unrecognized token after `part` is
    // ambiguous — keep the action.
    assert!(declares_part_directive(
        "part /* note 'foo.g.dart';",
        "foo.g.dart"
    ));
    assert!(declares_part_directive("part foo;", "foo.g.dart"));
    // Triple-quoted URIs are valid Dart and are parsed normally.
    assert!(declares_part_directive(
        "part '''foo.g.dart''';",
        "foo.g.dart"
    ));
    assert!(declares_part_directive(
        "part \"\"\"foo.g.dart\"\"\";",
        "foo.g.dart"
    ));
    assert!(declares_part_directive(
        "part r'''foo.g.dart''';",
        "foo.g.dart"
    ));
    // A lone quote inside a triple-quoted URI does not terminate it.
    assert!(!declares_part_directive(
        "part '''don't.dart''';",
        "foo.g.dart"
    ));
    assert!(!declares_part_directive(
        "part '''other.dart''';",
        "foo.g.dart"
    ));
    // Conservative: escaped and unterminated URIs keep the action.
    assert!(declares_part_directive(
        "part 'foo\\u002eg.dart';",
        "foo.g.dart"
    ));
    assert!(declares_part_directive("part 'foo.g.dart", "foo.g.dart"));
    assert!(declares_part_directive("part '''foo.g.dart", "foo.g.dart"));
    assert!(declares_part_directive(
        "// kept as part 'cause x\npart 'foo.g.dart';",
        "foo.g.dart"
    ));
    assert!(declares_part_directive(
        "// kept as part 'cause x\rpart 'foo.g.dart';",
        "foo.g.dart"
    ));
}

struct TemporaryWorkspace(PathBuf);

impl TemporaryWorkspace {
    fn new() -> io::Result<Self> {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "build-stage-output-reuse-{}-{nonce}",
            std::process::id()
        ));
        let temporary = Self(root);
        fs::create_dir_all(temporary.0.join(".dart_tool"))?;
        fs::create_dir_all(temporary.0.join("lib"))?;
        fs::write(temporary.0.join("pubspec.yaml"), "name: app\n")?;
        fs::write(
            temporary.0.join(".dart_tool/package_config.json"),
            r#"{"configVersion":2,"packages":[{"name":"app","rootUri":"../"}]}"#,
        )?;
        Ok(temporary)
    }
}

impl Drop for TemporaryWorkspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn commit_preserves_dynamic_output_reused_from_deleted_action() -> io::Result<()> {
    use super::commit::{CommitInputs, commit};
    use super::transaction::PendingTransaction;

    let temporary = TemporaryWorkspace::new()?;
    let workspace = Workspace::load(temporary.0.clone())?;
    let mut builder = configured_builder("post_process", "app:default", 0, 0);
    Arc::make_mut(&mut builder.definition).kind = BuilderKind::PostProcess;
    let old_spec = build_spec(&builder, "app|lib/old.txt", &[]);
    let new_spec = build_spec(&builder, "app|lib/new.txt", &[]);
    let output = "app|lib/shared.out".to_owned();
    let obsolete_output = "app|lib/obsolete.out".to_owned();
    let new_bytes = b"replacement output".to_vec();
    fs::write(temporary.0.join("lib/shared.out"), b"obsolete output")?;
    fs::write(temporary.0.join("lib/obsolete.out"), b"no longer needed")?;
    fs::write(temporary.0.join("lib/new.txt"), b"new input")?;
    let old_action = ActionState {
        builder: builder.definition.id.clone(),
        input: old_spec.input.clone(),
        outputs: vec![output.clone(), obsolete_output.clone()],
        status: "success".to_owned(),
        ..ActionState::default()
    };
    let new_action = ActionState {
        builder: builder.definition.id.clone(),
        input: new_spec.input.clone(),
        outputs: vec![output.clone()],
        output_digests: BTreeMap::from([(output.clone(), crate::digest::digest_bytes(&new_bytes))]),
        status: "success".to_owned(),
        ..ActionState::default()
    };
    let mut state = GraphState {
        actions: BTreeMap::from([(old_spec.action_key(), old_action.clone())]),
        ..GraphState::default()
    };
    let build_config = RustBuildConfig {
        builders: vec![builder.clone()],
        worker_entrypoint: None,
        manifest_signature: None,
        trigger_digest: None,
        definitions: BTreeMap::from([(builder.definition.id.clone(), builder.definition.clone())]),
    };
    let mut transaction =
        PendingTransaction::new(&[], &state, vec![(old_spec.action_key(), old_action)]);
    transaction.pending_outputs.push((
        builder.definition.clone(),
        output.clone(),
        new_bytes.clone().into(),
    ));
    transaction
        .pending_actions
        .push((new_spec.action_key(), new_action.clone()));
    let state_path = temporary.0.join(".dart_tool/graph-v3.bin");
    let scanned_packages = BTreeSet::from(["app".to_owned()]);

    commit(
        &mut state,
        CommitInputs {
            workspace: &workspace,
            state_path: &state_path,
            build_config: &build_config,
            config_digest: "test-config".to_owned(),
            scanned_packages: &scanned_packages,
            // Post-process outputs are dynamic, so the plan cannot protect
            // the reused asset through expected_outputs.
            expected_outputs: BTreeSet::new(),
            transaction,
        },
    )?;

    assert_eq!(fs::read(temporary.0.join("lib/shared.out"))?, new_bytes);
    assert!(!temporary.0.join("lib/obsolete.out").exists());
    assert!(!state.assets.contains_key(&obsolete_output));
    assert!(!state.actions.contains_key(&old_spec.action_key()));
    assert_eq!(state.actions.get(&new_spec.action_key()), Some(&new_action));
    assert_eq!(GraphState::load(&state_path)?, state);
    Ok(())
}

#[test]
fn output_registration_shares_buffers_and_releases_aborted_transaction() -> io::Result<()> {
    use super::results::record_build_result;
    use super::transaction::PendingTransaction;
    use crate::protocol::BuildResult;

    let temporary = TemporaryWorkspace::new()?;
    let workspace = Workspace::load(temporary.0.clone())?;
    let builder = configured_builder("producer", "app:default", 0, 0);
    let asset = "app|lib/input.out";
    let spec = build_spec(&builder, "app|lib/input.txt", &[asset]);
    fs::write(temporary.0.join("lib/input.txt"), b"input")?;
    fs::write(temporary.0.join("lib/input.out"), b"committed")?;
    let state = GraphState::default();
    // Also cover an empty output and the pre-existing overlay reference held
    // by a demand-built optional result before ordinary result registration.
    for bytes in [vec![], vec![0, 255, 1, 128]] {
        for optional in [false, true] {
            let result: BuildResult = serde_json::from_value(serde_json::json!({
                "type": "build_result", "id": 1, "status": "success",
                "outputs": [{"asset": asset, "bytes": bytes}],
                "resolver_used": false,
            }))?;
            let weak = Arc::downgrade(&result.outputs[0].bytes);
            let mut pending = PendingTransaction::new(&[], &state, Vec::new());
            if optional {
                pending
                    .overlay
                    .insert(asset.into(), Arc::clone(&result.outputs[0].bytes));
            }
            record_build_result(&workspace, &state, &spec, result, &mut pending)?;
            let overlay = &pending.overlay[asset];
            let commit_bytes = &pending.pending_outputs[0].2;
            assert!(Arc::ptr_eq(overlay, commit_bytes));
            assert_eq!(Arc::strong_count(overlay), 2);
            assert_eq!(overlay.as_ref(), bytes);
            assert_eq!(fs::read(temporary.0.join("lib/input.out"))?, b"committed");
            // A later action failure aborts the pending transaction. Removing
            // visibility must leave the bytes available for commit until then.
            pending.overlay.remove(asset);
            assert_eq!(pending.pending_outputs[0].2.as_ref(), bytes);
            drop(pending);
            assert!(weak.upgrade().is_none());
            assert_eq!(fs::read(temporary.0.join("lib/input.out"))?, b"committed");
        }
    }
    Ok(())
}

fn dirty_test_config(builders: &[ConfiguredBuilder]) -> RustBuildConfig {
    RustBuildConfig {
        builders: builders.to_vec(),
        worker_entrypoint: None,
        manifest_signature: None,
        trigger_digest: None,
        definitions: builders
            .iter()
            .map(|builder| (builder.definition.id.clone(), builder.definition.clone()))
            .collect(),
    }
}

#[test]
fn dirty_outputs_read_each_physical_path_once_per_pass() -> io::Result<()> {
    use super::dirty::collect_output_digests;
    use crate::plan::{output_digest, output_path};
    use std::sync::Mutex;

    let temporary = TemporaryWorkspace::new()?;
    fs::write(
        temporary.0.join(".dart_tool/package_config.json"),
        format!(
            r#"{{"configVersion":2,"packages":[{{"name":"app","rootUri":"../"}},{{"name":"alias","rootUri":"{}"}}]}}"#,
            temporary.0.display()
        ),
    )?;
    let workspace = Workspace::load(temporary.0.clone())?;
    let source = configured_builder("source", "app:default", 0, 0);
    let mut cache = configured_builder("cache", "app:default", 0, 1);
    Arc::make_mut(&mut cache.definition).build_to = BuildTo::Cache;
    let config = dirty_test_config(&[source.clone(), cache.clone()]);
    let shared = "app|lib/shared.out";
    let missing = "app|lib/missing.out";
    let recorded_only = "app|lib/optional.out";
    let declared_only = "app|lib/new.out";
    let source_path = output_path(&workspace, &source.definition, shared)?;
    let cache_path = output_path(&workspace, &cache.definition, shared)?;
    fs::write(&source_path, b"source bytes")?;
    fs::create_dir_all(cache_path.parent().unwrap())?;
    fs::write(&cache_path, b"cache bytes")?;
    fs::write(
        temporary.0.join("lib/optional.out"),
        b"dynamic optional bytes",
    )?;
    fs::write(temporary.0.join("lib/new.out"), b"new bytes")?;
    let state = GraphState {
        actions: BTreeMap::from([
            (
                "a".to_owned(),
                ActionState {
                    builder: source.definition.id.clone(),
                    outputs: vec![shared.into(), missing.into(), recorded_only.into()],
                    ..ActionState::default()
                },
            ),
            (
                "b".to_owned(),
                ActionState {
                    builder: cache.definition.id.clone(),
                    outputs: vec![shared.into()],
                    ..ActionState::default()
                },
            ),
            // Unknown builders were ignored by the previous recorded-output scan.
            (
                "c".to_owned(),
                ActionState {
                    builder: "unknown".into(),
                    outputs: vec!["invalid asset".into()],
                    ..ActionState::default()
                },
            ),
        ]),
        ..GraphState::default()
    };
    let specs = vec![
        build_spec(&source, "app|lib/input", &[shared, missing, declared_only]),
        build_spec(&cache, "app|lib/input", &[shared]),
        build_spec(&source, "app|lib/other", &[shared, missing]),
        // Different logical IDs resolving to the same package file also share a read.
        build_spec(&source, "alias|lib/input", &["alias|lib/shared.out"]),
    ];
    let reads = Mutex::new(BTreeMap::<PathBuf, usize>::new());
    let collect = || {
        collect_output_digests(&workspace, &state, &config, &specs, |path| {
            *reads.lock().unwrap().entry(path.to_owned()).or_default() += 1;
            output_digest(path)
        })
    };
    let (recorded, declared) = collect()?;
    assert_eq!(reads.lock().unwrap().len(), 5);
    assert!(reads.lock().unwrap().values().all(|count| *count == 1));
    assert_eq!(
        recorded[0],
        (shared, Some(crate::digest::digest_bytes(b"source bytes")))
    );
    assert_eq!(recorded[1], (missing, None));
    assert_eq!(recorded[2].0, recorded_only);
    assert_eq!(
        recorded[3],
        (shared, Some(crate::digest::digest_bytes(b"cache bytes")))
    );
    assert_eq!(declared[0][0], recorded[0]);
    assert_eq!(declared[0][1], recorded[1]);
    assert_eq!(declared[0][2].0, declared_only);
    assert_eq!(declared[1][0], recorded[3]);
    assert_eq!(declared[2], declared[0][..2]);
    assert_eq!(declared[3][0].0, "alias|lib/shared.out");
    assert_eq!(declared[3][0].1, declared[0][0].1);

    // No result (including a cached miss) survives the next dirty analysis.
    reads.lock().unwrap().clear();
    fs::write(&source_path, b"edited bytes")?;
    fs::remove_file(&cache_path)?;
    fs::write(temporary.0.join("lib/missing.out"), b"now present")?;
    let (recorded, declared) = collect()?;
    assert!(reads.lock().unwrap().values().all(|count| *count == 1));
    assert_eq!(
        declared[0][0].1,
        Some(crate::digest::digest_bytes(b"edited bytes"))
    );
    assert_eq!(
        declared[0][1].1,
        Some(crate::digest::digest_bytes(b"now present"))
    );
    assert_eq!(recorded[3].1, None);
    assert_eq!(declared[1][0].1, None);
    // A fresh graph must still deduplicate aliases and overlapping declarations.
    let empty_state = GraphState::default();
    reads.lock().unwrap().clear();
    let (recorded, declared) =
        collect_output_digests(&workspace, &empty_state, &config, &specs, |path| {
            *reads.lock().unwrap().entry(path.to_owned()).or_default() += 1;
            output_digest(path)
        })?;
    assert!(recorded.is_empty());
    assert_eq!(reads.lock().unwrap().len(), 4);
    assert!(reads.lock().unwrap().values().all(|count| *count == 1));
    assert_eq!(declared[3][0].1, declared[0][0].1);
    reads.lock().unwrap().clear();
    super::dirty::check_unrecorded_outputs(&workspace, &specs, |path| {
        *reads.lock().unwrap().entry(path.to_owned()).or_default() += 1;
        output_digest(path)
    })?;
    assert_eq!(reads.lock().unwrap().len(), 4);
    assert!(reads.lock().unwrap().values().all(|count| *count == 1));
    let (recorded, declared) =
        collect_output_digests(&workspace, &state, &config, &[], output_digest)?;
    assert_eq!(recorded.len(), 4);
    assert!(declared.is_empty());
    let empty = collect_output_digests(&workspace, &empty_state, &config, &[], |_| {
        panic!("empty output set must not read")
    })?;
    assert!(empty.0.is_empty() && empty.1.is_empty());
    Ok(())
}

#[test]
fn dirty_outputs_propagate_non_not_found_errors() -> io::Result<()> {
    use super::dirty::collect_output_digests;
    use crate::plan::output_digest;
    let temporary = TemporaryWorkspace::new()?;
    let workspace = Workspace::load(temporary.0.clone())?;
    let builder = configured_builder("source", "app:default", 0, 0);
    let config = dirty_test_config(std::slice::from_ref(&builder));
    let specs = vec![build_spec(
        &builder,
        "app|lib/input",
        &["app|lib/directory"],
    )];
    fs::create_dir(temporary.0.join("lib/directory"))?;
    let error = collect_output_digests(
        &workspace,
        &GraphState::default(),
        &config,
        &specs,
        output_digest,
    )
    .unwrap_err();
    assert_ne!(error.kind(), io::ErrorKind::NotFound);
    let error =
        super::dirty::check_unrecorded_outputs(&workspace, &specs, output_digest).unwrap_err();
    assert_ne!(error.kind(), io::ErrorKind::NotFound);
    // Also exercise a deterministic permission error independent of runner UID.
    let error = collect_output_digests(&workspace, &GraphState::default(), &config, &specs, |_| {
        Err(io::Error::from(io::ErrorKind::PermissionDenied))
    })
    .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    Ok(())
}

#[test]
fn dirty_analysis_preserves_logical_id_replay_and_recorded_outputs() -> io::Result<()> {
    use super::dirty::analyze;
    use super::planning::PlannedActions;
    use crate::digest::digest_bytes;
    use crate::metrics::FilesystemMetrics;
    use crate::visibility::AssetVisibility;

    let temporary = TemporaryWorkspace::new()?;
    let workspace = Workspace::load(temporary.0.clone())?;
    let source = configured_builder("source", "app:default", 0, 0);
    let mut cache = configured_builder("cache", "app:default", 0, 1);
    Arc::make_mut(&mut cache.definition).build_to = BuildTo::Cache;
    let mut optional = configured_builder("optional", "app:default", 0, 2);
    Arc::make_mut(&mut optional.definition).is_optional = true;
    let config = dirty_test_config(&[source.clone(), cache.clone(), optional.clone()]);
    let shared = "app|lib/shared.out";
    let source_spec = build_spec(&source, "app|lib/source", &[shared]);
    let cache_spec = build_spec(&cache, "app|lib/cache", &[shared]);
    let optional_spec = build_spec(&optional, "app|lib/optional", &[]);
    let deleted_spec = build_spec(&source, "app|lib/deleted", &[]);
    let action = |spec: &BuildSpec, output: &str, bytes: &[u8]| ActionState {
        builder: spec.builder.id.clone(),
        input: spec.input.clone(),
        outputs: vec![output.into()],
        output_digests: BTreeMap::from([(output.into(), digest_bytes(bytes))]),
        status: "success".into(),
        ..ActionState::default()
    };
    let state = GraphState {
        schema_version: crate::graph::GRAPH_SCHEMA_VERSION,
        config_digest: "config".into(),
        actions: BTreeMap::from([
            (
                source_spec.action_key(),
                action(&source_spec, shared, b"source"),
            ),
            (
                cache_spec.action_key(),
                action(&cache_spec, shared, b"cache"),
            ),
            (
                optional_spec.action_key(),
                action(&optional_spec, "app|lib/dynamic.out", b"optional"),
            ),
            (
                deleted_spec.action_key(),
                action(&deleted_spec, "app|lib/obsolete.out", b"obsolete"),
            ),
        ]),
        ..GraphState::default()
    };
    let plan = PlannedActions {
        specs: vec![
            source_spec.clone(),
            cache_spec.clone(),
            optional_spec.clone(),
        ],
        generated_output_locations: BTreeMap::new(),
        visibility: AssetVisibility::default(),
    };
    let cache_path = crate::plan::output_path(&workspace, &cache.definition, shared)?;
    fs::create_dir_all(cache_path.parent().unwrap())?;
    fs::write(&cache_path, b"cache")?;
    fs::write(temporary.0.join("lib/shared.out"), b"source")?;
    fs::write(temporary.0.join("lib/dynamic.out"), b"optional")?;
    fs::write(temporary.0.join("lib/obsolete.out"), b"obsolete")?;
    let snapshot = BTreeMap::new();
    let check = || {
        analyze(
            &workspace,
            &state,
            &config,
            "config",
            &snapshot,
            &plan,
            &mut FilesystemMetrics::default(),
        )
    };
    let result = check()?;
    // Each spec overrides the recorded shared ID immediately before its check.
    assert!(result.dirty.is_empty());
    assert!(result.lazy_force_keys.is_empty());
    assert_eq!(
        result.deleted_actions,
        vec![(
            deleted_spec.action_key(),
            state.actions[&deleted_spec.action_key()].clone()
        )]
    );

    fs::write(temporary.0.join("lib/shared.out"), b"edited")?;
    fs::remove_file(temporary.0.join("lib/dynamic.out"))?;
    let result = check()?;
    assert_eq!(
        result
            .dirty
            .iter()
            .map(BuildSpec::action_key)
            .collect::<Vec<_>>(),
        vec![source_spec.action_key()]
    );
    assert_eq!(
        result.lazy_force_keys,
        BTreeSet::from([optional_spec.action_key()])
    );

    fs::write(temporary.0.join("lib/shared.out"), b"source")?;
    fs::remove_file(&cache_path)?;
    let result = check()?;
    // A missing cache declaration does not erase the preceding source digest.
    assert_eq!(
        result
            .dirty
            .iter()
            .map(BuildSpec::action_key)
            .collect::<Vec<_>>(),
        vec![cache_spec.action_key()]
    );
    assert_eq!(
        result.lazy_force_keys,
        BTreeSet::from([optional_spec.action_key()])
    );
    let fresh = analyze(
        &workspace,
        &GraphState::default(),
        &config,
        "config",
        &snapshot,
        &plan,
        &mut FilesystemMetrics::default(),
    )?;
    assert_eq!(
        fresh
            .dirty
            .iter()
            .map(BuildSpec::action_key)
            .collect::<Vec<_>>(),
        vec![source_spec.action_key(), cache_spec.action_key()]
    );
    assert_eq!(
        fresh.lazy_force_keys,
        BTreeSet::from([optional_spec.action_key()])
    );
    assert!(fresh.deleted_actions.is_empty());

    Ok(())
}
