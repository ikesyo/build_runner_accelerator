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
