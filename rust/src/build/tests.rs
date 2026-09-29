use super::dirty::expand_dirty_dependents;
use super::execution::execution_order;
use super::part_directive::declares_part_directive;
use crate::builder::{BuildTo, BuilderDefinition, BuilderKind, ConfiguredBuilder};
use crate::graph::{ActionState, GraphState};
use crate::plan::BuildSpec;
use std::collections::BTreeMap;
use std::sync::Arc;


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

    assert!(
        dirty
            .iter()
            .any(|spec| spec.action_key() == consumer.action_key())
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
        &[producer, consumer.clone()],
        &successful_empty_state,
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
