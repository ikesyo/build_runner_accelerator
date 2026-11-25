use super::*;
use crate::graph::ActionState;

fn graph(edges: &[(&str, &[&str])]) -> BTreeMap<String, Vec<String>> {
    edges
        .iter()
        .map(|(asset, deps)| {
            (
                asset.to_string(),
                deps.iter().map(|dep| dep.to_string()).collect(),
            )
        })
        .collect()
}

fn view<'a>(
    graph: &'a BTreeMap<String, Vec<String>>,
    fingerprints: &'a BTreeMap<String, String>,
) -> (GraphView<'a>, FingerprintView<'a>) {
    (
        GraphView {
            base: graph,
            overrides: None,
        },
        FingerprintView {
            base: fingerprints,
            overrides: None,
        },
    )
}

fn fingerprints(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(asset, fp)| (asset.to_string(), fp.to_string()))
        .collect()
}

#[test]
fn fold_propagates_leaf_changes_and_ignores_unrelated() {
    let edges = graph(&[("a", &["b"]), ("b", &["c"]), ("c", &[])]);
    let fps = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc")]);
    let (g, f) = view(&edges, &fps);
    let before = fold_all(&["a".into()], &g, &f, "seed").expect("folds");
    let changed = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc2")]);
    let (g2, f2) = view(&edges, &changed);
    let after = fold_all(&["a".into()], &g2, &f2, "seed").expect("folds");
    assert_ne!(before, after, "a leaf API change must reach the root");
    let unrelated = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc"), ("z", "fz")]);
    let (g3, f3) = view(&edges, &unrelated);
    assert_eq!(
        before,
        fold_all(&["a".into()], &g3, &f3, "seed").expect("folds")
    );
    let (g4, f4) = view(&edges, &fps);
    assert_ne!(
        before,
        fold_all(&["a".into()], &g4, &f4, "other-seed").expect("folds"),
        "the seed binds the fold to the resolution environment"
    );
}

#[test]
fn fold_collapses_cycles() {
    let edges = graph(&[("a", &["b"]), ("b", &["a", "c"]), ("c", &[])]);
    let fps = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc")]);
    let (g, f) = view(&edges, &fps);
    let folds = fold_all(&["a".into(), "b".into()], &g, &f, "seed").expect("folds");
    assert_eq!(folds["a"], folds["b"], "cycle members share one fold");
    let changed = fingerprints(&[("a", "fa"), ("b", "fb"), ("c", "fc2")]);
    let (g2, f2) = view(&edges, &changed);
    let after = fold_all(&["a".into(), "b".into()], &g2, &f2, "seed").expect("folds");
    assert_ne!(folds, after);
}

#[test]
fn fold_requires_every_fingerprint() {
    let edges = graph(&[("a", &["b"]), ("b", &[])]);
    let fps = fingerprints(&[("a", "fa")]);
    let (g, f) = view(&edges, &fps);
    assert_eq!(fold_all(&["a".into()], &g, &f, "seed"), None);
}

fn state_with(edges: &[(&str, &[&str])], fps: &[(&str, &str)], action: ActionState) -> GraphState {
    // Recorded fingerprints are bound to snapshot entries whose
    // digests carry the `b3-` prefix the records omit.
    let asset_fingerprints = fps
        .iter()
        .map(|(asset, fp)| {
            (
                asset.to_string(),
                ApiFingerprintRecord {
                    digest: format!("digest-of-{asset}"),
                    fingerprint: fp.to_string(),
                },
            )
        })
        .collect();
    let assets = fps
        .iter()
        .map(|(asset, _)| {
            (
                asset.to_string(),
                crate::snapshot::AssetSnapshot {
                    exists: true,
                    digest: format!("b3-digest-of-{asset}"),
                    size: 0,
                },
            )
        })
        .collect();
    GraphState {
        resolver_dep_graph: graph(edges),
        asset_fingerprints,
        assets,
        actions: BTreeMap::from([("app|target:app:consumer".to_string(), action)]),
        ..GraphState::default()
    }
}

fn recorded_closure(state: &GraphState, candidates: &[Candidate]) -> BTreeSet<String> {
    let roots: Vec<String> = candidates
        .iter()
        .flat_map(|candidate| candidate.roots.iter().cloned())
        .collect();
    forward_closure(
        &GraphView {
            base: &state.resolver_dep_graph,
            overrides: None,
        },
        &roots,
    )
}

#[test]
fn evaluate_marks_only_proven_clean_actions() {
    let action = ActionState {
        builder: "app:consumer".into(),
        input: "app|lib/main.dart".into(),
        resolver_entrypoints: vec!["app|lib/main.dart".into()],
        ..ActionState::default()
    };
    let state = state_with(
        &[("app|lib/main.dart", &["app|lib/dep.dart"])],
        &[
            ("app|lib/main.dart", "f-main"),
            ("app|lib/dep.dart", "f-dep"),
        ],
        action,
    );
    let candidates = vec![Candidate {
        key: "app|target:app:consumer".into(),
        builder: "app:consumer".into(),
        roots: vec!["app|lib/main.dart".into()],
    }];
    let assessment = Assessment {
        query: vec![("app|lib/dep.dart".into(), "d2".into())],
        first_package: "app".into(),
        recorded_closure: recorded_closure(&state, &candidates),
        candidates,
        deleted: BTreeSet::new(),
        appeared: BTreeSet::new(),
        unstable_generated: BTreeSet::new(),
    };
    let unchanged = BTreeMap::from([(
        "app|lib/dep.dart".to_string(),
        ApiUnitEvidence {
            fingerprint: Some("f-dep".into()),
            deps: Some(vec![]),
        },
    )]);
    let evidence = evaluate(
        &state,
        &assessment,
        &unchanged,
        "seed",
        &mut CutoffDiagnostics::default(),
    );
    assert!(evidence.clean_actions.contains("app|target:app:consumer"));
    assert_eq!(
        evidence.learned.get("app|lib/dep.dart"),
        Some(&Some(ApiFingerprintRecord {
            digest: "d2".to_string(),
            fingerprint: "f-dep".to_string(),
        }))
    );
    let changed = BTreeMap::from([(
        "app|lib/dep.dart".to_string(),
        ApiUnitEvidence {
            fingerprint: Some("f-dep-2".into()),
            deps: Some(vec![]),
        },
    )]);
    let evidence = evaluate(
        &state,
        &assessment,
        &changed,
        "seed",
        &mut CutoffDiagnostics::default(),
    );
    assert!(evidence.clean_actions.is_empty());
    // An unanswered unit is no evidence at all.
    let evidence = evaluate(
        &state,
        &assessment,
        &BTreeMap::new(),
        "seed",
        &mut CutoffDiagnostics::default(),
    );
    assert!(evidence.clean_actions.is_empty());
    // A unit that appeared since the previous snapshot is an
    // existence change: matching fingerprints cannot prove the
    // recorded output was not produced while it was missing.
    let appeared_candidates = vec![Candidate {
        key: "app|target:app:consumer".into(),
        builder: "app:consumer".into(),
        roots: vec!["app|lib/main.dart".into()],
    }];
    let appeared_assessment = Assessment {
        query: assessment.query.clone(),
        first_package: assessment.first_package.clone(),
        recorded_closure: recorded_closure(&state, &appeared_candidates),
        candidates: appeared_candidates,
        deleted: BTreeSet::new(),
        appeared: BTreeSet::from(["app|lib/dep.dart".to_string()]),
        unstable_generated: BTreeSet::new(),
    };
    let evidence = evaluate(
        &state,
        &appeared_assessment,
        &unchanged,
        "seed",
        &mut CutoffDiagnostics::default(),
    );
    assert!(evidence.clean_actions.is_empty());
    // Evidence for a unit that was never queried binds to no
    // snapshot digest and is ignored outright: the same reply
    // plus a volunteered entry for the importing unit (claiming
    // a different fingerprint and no deps) changes nothing.
    let mut with_volunteered = unchanged.clone();
    with_volunteered.insert(
        "app|lib/main.dart".to_string(),
        ApiUnitEvidence {
            fingerprint: Some("f-main-other".into()),
            deps: Some(vec![]),
        },
    );
    let evidence = evaluate(
        &state,
        &assessment,
        &with_volunteered,
        "seed",
        &mut CutoffDiagnostics::default(),
    );
    assert!(evidence.clean_actions.contains("app|target:app:consumer"));
}

#[test]
fn evaluate_diagnostics_attribute_outcomes() {
    let action = ActionState {
        builder: "app:consumer".into(),
        input: "app|lib/main.dart".into(),
        resolver_entrypoints: vec!["app|lib/main.dart".into()],
        ..ActionState::default()
    };
    let state = state_with(
        &[("app|lib/main.dart", &["app|lib/dep.dart"])],
        &[
            ("app|lib/main.dart", "f-main"),
            ("app|lib/dep.dart", "f-dep"),
        ],
        action,
    );
    let candidates = vec![Candidate {
        key: "app|target:app:consumer".into(),
        builder: "app:consumer".into(),
        roots: vec!["app|lib/main.dart".into()],
    }];
    let assessment = Assessment {
        query: vec![("app|lib/dep.dart".into(), "d2".into())],
        first_package: "app".into(),
        recorded_closure: recorded_closure(&state, &candidates),
        candidates,
        deleted: BTreeSet::new(),
        appeared: BTreeSet::new(),
        unstable_generated: BTreeSet::new(),
    };
    let unchanged = BTreeMap::from([(
        "app|lib/dep.dart".to_string(),
        ApiUnitEvidence {
            fingerprint: Some("f-dep".into()),
            deps: Some(vec![]),
        },
    )]);
    let mut diagnostics = CutoffDiagnostics {
        enabled: true,
        ..Default::default()
    };
    let evidence = evaluate(&state, &assessment, &unchanged, "seed", &mut diagnostics);
    assert!(evidence.clean_actions.contains("app|target:app:consumer"));
    assert_eq!(diagnostics.evaluate["app:consumer"].signature_unchanged, 1);
    // An unstable generated asset in the closure disqualifies
    // the whole action, and the diagnostics attribute it to
    // that rule.
    let mut diagnostics = CutoffDiagnostics {
        enabled: true,
        ..Default::default()
    };
    let blocked_candidates = vec![Candidate {
        key: "app|target:app:consumer".into(),
        builder: "app:consumer".into(),
        roots: vec!["app|lib/main.dart".into()],
    }];
    let blocked_assessment = Assessment {
        query: assessment.query.clone(),
        first_package: assessment.first_package.clone(),
        recorded_closure: recorded_closure(&state, &blocked_candidates),
        candidates: blocked_candidates,
        deleted: BTreeSet::new(),
        appeared: BTreeSet::new(),
        unstable_generated: BTreeSet::from(["app|lib/dep.dart".to_string()]),
    };
    let evidence = evaluate(
        &state,
        &blocked_assessment,
        &unchanged,
        "seed",
        &mut diagnostics,
    );
    assert!(evidence.clean_actions.is_empty());
    assert_eq!(diagnostics.evaluate["app:consumer"].generated_asset, 1);
    assert_eq!(diagnostics.evaluate["app:consumer"].signature_unchanged, 0);
}

#[test]
fn evaluate_rejects_fingerprints_not_bound_to_the_snapshot() {
    let action = ActionState {
        builder: "app:consumer".into(),
        input: "app|lib/main.dart".into(),
        resolver_entrypoints: vec!["app|lib/main.dart".into()],
        ..ActionState::default()
    };
    let mut state = state_with(
        &[("app|lib/main.dart", &["app|lib/dep.dart"])],
        &[
            ("app|lib/main.dart", "f-main"),
            ("app|lib/dep.dart", "f-dep"),
        ],
        action,
    );
    // The recorded fingerprint for the changed unit describes
    // other bytes than the previous snapshot's (a worker learned
    // it from a mid-build edit the commit did not record). Even
    // though the preflight answer matches it, it is not evidence
    // about the snapshot's content and must not waive the action.
    state
        .asset_fingerprints
        .get_mut("app|lib/dep.dart")
        .expect("recorded fingerprint")
        .digest = "digest-of-newer-content".into();
    let candidates = vec![Candidate {
        key: "app|target:app:consumer".into(),
        builder: "app:consumer".into(),
        roots: vec!["app|lib/main.dart".into()],
    }];
    let assessment = Assessment {
        query: vec![("app|lib/dep.dart".into(), "d2".into())],
        first_package: "app".into(),
        recorded_closure: recorded_closure(&state, &candidates),
        candidates,
        deleted: BTreeSet::new(),
        appeared: BTreeSet::new(),
        unstable_generated: BTreeSet::new(),
    };
    let answers = BTreeMap::from([(
        "app|lib/dep.dart".to_string(),
        ApiUnitEvidence {
            fingerprint: Some("f-dep".into()),
            deps: Some(vec![]),
        },
    )]);
    let evidence = evaluate(
        &state,
        &assessment,
        &answers,
        "seed",
        &mut CutoffDiagnostics::default(),
    );
    assert!(evidence.clean_actions.is_empty());
}
