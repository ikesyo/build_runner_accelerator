use super::asset_rpc::{
    batch_asset_request_context, missing_asset_response, validate_asset_request_context,
};
use super::client::{has_capability, is_worker_script, require_overlay_blob_capability};
use super::pool::{
    homogeneous_resolver_usage_key, remember_resolver_usage, target_worker_count,
    validate_memory_overlay,
};
use super::request::{BuildRequest, batch_blocked_assets};
use super::wire::{
    AssetInterner, BatchWire, BlockedAssetsCache, PlainAssetIds, batch_request_wires,
    batch_request_wires_with, batch_shared_fields, batch_shared_request_wires, build_wire,
    compute_asset_digest_delta, intern_asset_list, intern_overlay_blob, rollback_asset_dictionary,
    write_batch_frame,
};
use crate::visibility::AssetVisibility;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

#[cfg(unix)]
mod batch_transport {
    use super::*;
    use crate::protocol::{BINARY_BUILD_RESULT_MAGIC, write_binary_frame_with_magic, write_frame};
    use crate::worker::{LazyBuildState, WorkerClient};
    use crate::worker_kernel::WorkerArtifact;
    use crate::workspace::Workspace;
    use std::io;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    struct TemporaryRoot(PathBuf);

    impl Drop for TemporaryRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[derive(Clone, Copy)]
    enum BatchReply {
        Complete,
        Interrupted,
        DuplicateResult,
        Rejected,
    }

    fn check_response(lazy: bool, reply: BatchReply) -> io::Result<()> {
        let terminal = match reply {
            BatchReply::Complete => Some(1),
            BatchReply::DuplicateResult => Some(0),
            _ => None,
        };
        let root = TemporaryRoot(std::env::temp_dir().join(format!(
            "batch-transport-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        )));
        std::fs::create_dir_all(root.0.join(".dart_tool"))?;
        std::fs::write(root.0.join("pubspec.yaml"), "name: example\n")?;
        std::fs::write(
            root.0.join(".dart_tool/package_config.json"),
            r#"{"configVersion":2,"packages":[{"name":"example","rootUri":"../"}]}"#,
        )?;
        let workspace = Workspace::load(root.0.clone())?;
        let mut response = Vec::new();
        if matches!(reply, BatchReply::Rejected) {
            // Rejected before the worker accepts the new visibility hint.
            write_frame(
                &mut response,
                &json!({
                    "v": 1, "type": "error", "id": 1,
                    "error": "invalid build_batch child instance_key"
                }),
            )?;
        } else {
            for (id, more) in std::iter::once((0, true)).chain(terminal.map(|id| (id, false))) {
                write_binary_frame_with_magic(
                    &mut response,
                    BINARY_BUILD_RESULT_MAGIC,
                    &json!({
                        "v": 1, "id": 1, "encoding": "raw",
                        "type": if more {"build_batch_chunk"} else {"build_batch_result"},
                        "results": [{
                            "v": 1, "type": "build_result", "id": id, "status": "success",
                            "encoding": "raw", "execution_us": 5000,
                            "outputs": [{"asset": format!("example|{id}.bin"), "length": 3}],
                            "deleted": [], "reads": [], "resolver_reads": [],
                            "resolver_entrypoints": [], "resolver_used": false,
                            "glob_reads": [], "diagnostics": []
                        }],
                        "dep_graph": {format!("example|entry{id}.dart"): ["example|dep.dart"]},
                        "api_fingerprints": {format!("example|entry{id}.dart"): if id == 0 { json!({"digest": "d0", "fingerprint": "fp0"}) } else { json!(null) }}
                    }),
                    &[0, 255, id as u8],
                )?;
            }
        }
        std::fs::write(root.0.join("response.bin"), response)?;
        let executable = root.0.join("worker.sh");
        // Replay real binary frames, then close stdout to test interruption too.
        std::fs::write(
            &executable,
            "#!/bin/sh\ndd bs=1 count=4 of=/dev/null 2>/dev/null\ncat response.bin\n",
        )?;
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700))?;
        let mut worker = WorkerClient::start(
            &workspace.root,
            "unused",
            "unused",
            &WorkerArtifact::Aot(executable),
        )?;
        worker.blocked_assets_cache = super::super::wire::BlockedAssetsCache::new(true);
        worker
            .blocked_assets_cache
            .prepare_list(vec!["example|old.dart".to_owned()]);
        let blocked_assets = vec!["example|hidden.dart".to_owned()];
        worker
            .dep_graph
            .insert("example|existing.dart".to_owned(), vec![]);
        let requests = [build_request(0, false), build_request(0, false)];
        let mut overlay = BTreeMap::new();
        let mut deleted = blocked_assets.iter().cloned().collect();
        let visibility = AssetVisibility::default();
        let result = if lazy {
            worker.build_batch_lazy(
                &workspace,
                &requests,
                &mut overlay,
                &mut deleted,
                &visibility,
                &BTreeMap::new(),
                &mut LazyBuildState::new(BTreeSet::new()),
            )
        } else {
            worker.build_batch(&workspace, &requests, &overlay, &deleted, &visibility)
        };
        if terminal == Some(1) {
            let results = result?;
            assert_eq!(results.len(), 2);
            for (id, result) in results.iter().enumerate() {
                assert_eq!(result.id, id as u64);
                assert_eq!(result.execution_us, Some(5000));
                assert_eq!(result.outputs[0].bytes.as_ref(), &[0, 255, id as u8]);
                assert!(
                    worker
                        .dep_graph
                        .contains_key(&format!("example|entry{id}.dart"))
                );
            }
            assert_eq!(worker.dep_graph.len(), 3);
            assert_eq!(
                worker.api_fingerprints,
                BTreeMap::from([
                    (
                        "example|entry0.dart".to_owned(),
                        Some(crate::protocol::ApiFingerprintRecord {
                            digest: "d0".to_owned(),
                            fingerprint: "fp0".to_owned(),
                        }),
                    ),
                    ("example|entry1.dart".to_owned(), None),
                ])
            );
            // Both ordinary and lazy batches prime the same connection cache.
            assert_eq!(
                worker
                    .blocked_assets_cache
                    .prepare_list(blocked_assets.clone()),
                (vec![], true)
            );
        } else {
            assert!(result.is_err());
            // A retry must send a full list, including after rejection, malformed
            // results, or interruption. Successful calls above still reuse it.
            assert_eq!(
                worker
                    .blocked_assets_cache
                    .prepare_list(blocked_assets.clone()),
                (blocked_assets, false)
            );
            assert_eq!(worker.dep_graph.len(), 1, "partial dependencies escaped");
            assert!(worker.dep_graph.contains_key("example|existing.dart"));
            assert!(
                worker.api_fingerprints.is_empty(),
                "partial fingerprints escaped"
            );
        }
        Ok(())
    }

    #[test]
    fn normal_and_lazy_clients_receive_complete_fragmented_batches() -> io::Result<()> {
        for lazy in [false, true] {
            check_response(lazy, BatchReply::Complete)?;
        }
        Ok(())
    }

    #[test]
    fn normal_and_lazy_clients_resend_full_hint_after_rejection() -> io::Result<()> {
        for lazy in [false, true] {
            check_response(lazy, BatchReply::Rejected)?;
        }
        Ok(())
    }

    #[test]
    fn normal_and_lazy_clients_discard_invalid_or_interrupted_batches() -> io::Result<()> {
        for lazy in [false, true] {
            for reply in [BatchReply::DuplicateResult, BatchReply::Interrupted] {
                check_response(lazy, reply)?;
            }
        }
        Ok(())
    }
}

fn build_request(phase: u32, post_process: bool) -> BuildRequest {
    BuildRequest {
        part_phase_index: None,
        builder: "example:builder".to_owned(),
        input: "example|lib/input.txt".to_owned(),
        outputs: Vec::new(),
        options: serde_json::Map::new(),
        phase,
        instance_key: "example".to_owned(),
        is_root: true,
        api_cutoff: false,
        post_process,
        triggers: Vec::new(),
    }
}

#[test]
fn worker_count_follows_available_requests() {
    assert_eq!(target_worker_count(4, 0), 1);
    assert_eq!(target_worker_count(4, 1), 1);
    assert_eq!(target_worker_count(4, 3), 3);
    assert_eq!(target_worker_count(4, 8), 4);
    assert_eq!(target_worker_count(1, 8), 1);
}

#[test]
fn resolver_usage_is_classified_per_builder_instance() {
    let requests = vec![build_request(0, false), build_request(0, false)];
    assert_eq!(
        homogeneous_resolver_usage_key(&requests),
        Some(("example:builder".to_owned(), "example".to_owned()))
    );

    let mut different_instance = build_request(0, false);
    different_instance.instance_key = "another-instance".to_owned();
    assert_eq!(
        homogeneous_resolver_usage_key(&[build_request(0, false), different_instance]),
        None
    );

    assert_eq!(
        homogeneous_resolver_usage_key(&[build_request(0, false), build_request(0, true),]),
        None
    );
}

#[test]
fn resolver_usage_observations_only_promote_to_resolver_backed() {
    let key = ("example:builder".to_owned(), "example".to_owned());
    let mut usage = BTreeMap::new();
    remember_resolver_usage(&mut usage, key.clone(), false);
    assert_eq!(usage.get(&key), Some(&false));
    remember_resolver_usage(&mut usage, key.clone(), true);
    assert_eq!(usage.get(&key), Some(&true));
    remember_resolver_usage(&mut usage, key.clone(), false);
    assert_eq!(usage.get(&key), Some(&true));
}

#[test]
fn batch_blocked_assets_requires_one_visibility_context() {
    let requests = vec![build_request(0, false), build_request(0, false)];
    let visibility = AssetVisibility::default();
    let deleted = BTreeSet::new();
    assert_eq!(
        batch_blocked_assets(&requests, &visibility, &deleted).unwrap(),
        Vec::<String>::new()
    );

    let mixed = vec![build_request(0, false), build_request(1, false)];
    assert!(batch_blocked_assets(&mixed, &visibility, &deleted).is_err());
}

#[test]
fn typed_build_wires_match_the_json_message_shape() {
    // Telemetry injection adds fields to the typed wires only while a
    // session is active; unit tests run without one.
    if crate::telemetry::request_context().is_some() {
        return;
    }
    let mut normal = build_request(2, false);
    normal.part_phase_index = Some(1);
    normal.outputs = vec!["example|lib/input.out".to_owned()];
    normal.options =
        serde_json::Map::from_iter([("flag".to_owned(), serde_json::Value::Bool(true))]);
    let post = build_request(2, true);
    let requests = vec![normal, post];
    let blocked = vec!["example|hidden.dart".to_owned()];

    let wires = batch_request_wires(&requests, &mut PlainAssetIds);
    let wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 9,
        asset_dict_add: None,
        blocked_assets: blocked.as_slice(),
        blocked_assets_reuse: false,
        shared: None,
        asset_digests: None,
        requests: &wires,
    };
    let value = json!({
        "v": 1,
        "type": "build_batch",
        "id": 9,
        "blocked_assets": blocked,
        "blocked_assets_reuse": false,
        "requests": requests.iter().enumerate().map(|(index, request)| json!({
            "id": index as u64,
            "builder": request.builder,
            "input": request.input,
            "kind": if request.post_process { "post_process" } else { "normal" },
            "allowed_outputs": request.outputs,
            "options": request.options,
            "phase": request.phase,
            "part_phase_index": request.part_phase_index,
            "instance_key": request.instance_key,
            "is_root": request.is_root,
            "triggers": request.triggers,
        })).collect::<Vec<_>>(),
    });
    assert_eq!(serde_json::to_value(&wire).unwrap(), value);
    assert_eq!(
        serde_json::to_string(&wire).unwrap(),
        serde_json::to_string(&value).unwrap(),
        "serialized bytes keep the historical key order",
    );

    let single = build_wire(7, &requests[0], &blocked);
    let single_value = json!({
        "v": 1,
        "type": "build",
        "id": 7,
        "builder": requests[0].builder,
        "input": requests[0].input,
        "kind": "normal",
        "allowed_outputs": requests[0].outputs,
        "options": requests[0].options,
        "phase": requests[0].phase,
        "part_phase_index": requests[0].part_phase_index,
        "instance_key": requests[0].instance_key,
        "is_root": requests[0].is_root,
        "blocked_assets": blocked,
        "triggers": requests[0].triggers,
    });
    assert_eq!(serde_json::to_value(&single).unwrap(), single_value);
    assert_eq!(
        serde_json::to_string(&single).unwrap(),
        serde_json::to_string(&single_value).unwrap(),
    );
}

#[test]
fn batch_wires_carry_telemetry_contexts_in_order() {
    let requests = vec![
        build_request(2, false),
        build_request(2, false),
        build_request(2, false),
    ];
    let mut scripted = vec![
        Some(("parent-0".to_owned(), 10u64)),
        Some(("parent-1".to_owned(), 11u64)),
    ]
    .into_iter();
    let mut calls = 0usize;
    let wires = batch_request_wires_with(&requests, &mut PlainAssetIds, || {
        calls += 1;
        scripted.next().unwrap_or(None)
    });
    // One message-level draw, then one fresh draw per later request.
    assert_eq!(calls, 3);
    let values: Vec<serde_json::Value> = wires
        .iter()
        .map(|wire| serde_json::to_value(wire).unwrap())
        .collect();
    assert_eq!(values[0]["traceparent"].as_str(), Some("parent-0"));
    assert_eq!(values[0]["otel_report_id"].as_u64(), Some(10));
    assert_eq!(values[1]["traceparent"].as_str(), Some("parent-1"));
    assert_eq!(values[1]["otel_report_id"].as_u64(), Some(11));
    // The provider is exhausted: the fields are omitted, not null.
    assert!(values[2].get("traceparent").is_none());
    assert!(values[2].get("otel_report_id").is_none());

    // Without a session the provider is probed exactly once and no
    // telemetry fields are emitted.
    let mut calls = 0usize;
    let wires = batch_request_wires_with(&requests, &mut PlainAssetIds, || {
        calls += 1;
        None
    });
    assert_eq!(calls, 1);
    for wire in &wires {
        let value = serde_json::to_value(wire).unwrap();
        assert!(value.get("traceparent").is_none());
        assert!(value.get("otel_report_id").is_none());
    }
}

#[test]
fn api_cutoff_rides_requests_only_when_opted_in() {
    let plain = build_request(0, false);
    let wire = build_wire(1, &plain, &[]);
    let value = serde_json::to_value(&wire).unwrap();
    assert!(value.get("api_cutoff").is_none(), "absent unless opted in");

    let mut opted = build_request(0, false);
    opted.api_cutoff = true;
    let wire = build_wire(2, &opted, &[]);
    let value = serde_json::to_value(&wire).unwrap();
    assert_eq!(value["api_cutoff"], serde_json::json!(true));

    let wires = batch_request_wires(std::slice::from_ref(&opted), &mut PlainAssetIds);
    let value = serde_json::to_value(&wires[0]).unwrap();
    assert_eq!(value["api_cutoff"], serde_json::json!(true));

    let opted_batch = [opted.clone(), opted];
    let shared = batch_shared_fields(&opted_batch).expect("uniform opted batch");
    let value = serde_json::to_value(&shared).unwrap();
    assert_eq!(value["api_cutoff"], serde_json::json!(true));

    let mut mixed_opted = build_request(2, false);
    mixed_opted.api_cutoff = true;
    let mixed = vec![build_request(2, false), mixed_opted];
    assert!(batch_shared_fields(&mixed).is_none(), "mixed cutoff");
}

#[test]
fn shared_batch_fields_require_a_uniform_multi_request_batch() {
    let requests = vec![build_request(2, false), build_request(2, false)];
    assert!(batch_shared_fields(&requests).is_some());
    assert!(
        batch_shared_fields(&requests[..1]).is_none(),
        "single request"
    );
    assert!(batch_shared_fields(&[]).is_none(), "empty batch");

    let mixed_phase = vec![build_request(2, false), build_request(3, false)];
    assert!(batch_shared_fields(&mixed_phase).is_none(), "mixed phase");

    let mixed_kind = vec![build_request(2, false), build_request(2, true)];
    assert!(batch_shared_fields(&mixed_kind).is_none(), "mixed kind");

    let mut other_instance = build_request(2, false);
    other_instance.instance_key = "other".to_owned();
    let mixed_instance = vec![build_request(2, false), other_instance];
    assert!(
        batch_shared_fields(&mixed_instance).is_none(),
        "mixed instance"
    );

    let mut other_root = build_request(2, false);
    other_root.is_root = false;
    let mixed_root = vec![build_request(2, false), other_root];
    assert!(batch_shared_fields(&mixed_root).is_none(), "mixed is_root");

    let mut other_part = build_request(2, false);
    other_part.part_phase_index = Some(0);
    let mixed_part = vec![build_request(2, false), other_part];
    assert!(
        batch_shared_fields(&mixed_part).is_none(),
        "mixed part index"
    );

    let mut other_builder = build_request(2, false);
    other_builder.builder = "example:other".to_owned();
    let mixed_builder = vec![build_request(2, false), other_builder];
    assert!(
        batch_shared_fields(&mixed_builder).is_none(),
        "mixed builder"
    );
}

#[test]
fn shared_batch_merges_back_to_the_full_batch_requests() {
    // See typed_build_wires_match_the_json_message_shape for why telemetry
    // must be inactive.
    if crate::telemetry::request_context().is_some() {
        return;
    }
    let requests = vec![build_request(2, false), build_request(2, false)];
    let blocked = vec!["example|hidden.dart".to_owned()];
    let shared = batch_shared_fields(&requests).expect("uniform batch lifts");
    let wires = batch_shared_request_wires(&requests, &mut PlainAssetIds);
    let value = serde_json::to_value(&BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 9,
        asset_dict_add: None,
        blocked_assets: blocked.as_slice(),
        blocked_assets_reuse: false,
        shared: Some(shared),
        asset_digests: None,
        requests: &wires,
    })
    .unwrap();

    // Simulate the worker-side merge: shared fields under each request,
    // with request fields winning.
    let shared_map = value["shared"].as_object().unwrap().clone();
    let merged: Vec<serde_json::Value> = value["requests"]
        .as_array()
        .unwrap()
        .iter()
        .map(|request| {
            let mut merged = shared_map.clone();
            merged.extend(request.as_object().unwrap().clone());
            serde_json::Value::Object(merged)
        })
        .collect();

    let full_wires = batch_request_wires(&requests, &mut PlainAssetIds);
    let full = serde_json::to_value(&BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 9,
        asset_dict_add: None,
        blocked_assets: blocked.as_slice(),
        blocked_assets_reuse: false,
        shared: None,
        asset_digests: None,
        requests: &full_wires,
    })
    .unwrap();
    assert_eq!(serde_json::Value::Array(merged), full["requests"]);
}

#[test]
fn required_worker_capabilities_are_detected() {
    let response = json!({
        "capabilities": [
            "asset-rpc-v1",
            "asset-rpc-binary-read-v1",
            "shared-blocked-assets-v1"
        ]
    });
    assert!(has_capability(&response, "asset-rpc-binary-read-v1"));
    assert!(has_capability(&response, "shared-blocked-assets-v1"));
    assert!(!has_capability(&response, "other-capability"));
    assert!(!has_capability(&json!({}), "asset-rpc-binary-read-v1"));
}

#[test]
fn missing_asset_response_uses_the_asset_not_found_message() {
    let response = missing_asset_response(42, "app|lib/missing.dart");

    assert_eq!(response["ok"], false);
    assert_eq!(response["error"], "asset not found: app|lib/missing.dart");
}

#[test]
fn dart_scripts_bypass_package_runner_and_kernel() {
    assert!(is_worker_script("/tmp/dynamic_worker.dart"));
    assert!(is_worker_script("relative_worker.dart"));
    assert!(!is_worker_script("example_builder:worker"));
}

#[test]
fn asset_request_context_must_match_the_rust_build_request() {
    let active_request = build_request(3, false);
    assert!(
        validate_asset_request_context(
            &json!({"build_id": 7, "phase": 3, "kind": "normal"}),
            &active_request,
            7,
        )
        .is_ok()
    );
    assert!(
        validate_asset_request_context(
            &json!({"build_id": 7, "phase": 4, "kind": "normal"}),
            &active_request,
            7,
        )
        .is_err()
    );
    assert!(
        validate_asset_request_context(
            &json!({"build_id": 7, "phase": 3, "kind": "post_process"}),
            &active_request,
            7,
        )
        .is_err()
    );
    assert!(
        validate_asset_request_context(
            &json!({"build_id": 7, "phase": 3, "kind": "normal"}),
            &active_request,
            8,
        )
        .is_err()
    );
}

#[test]
fn batch_asset_request_context_uses_the_matching_build_item() {
    let requests = vec![build_request(0, false), build_request(3, true)];
    let (build_id, active_request) =
        batch_asset_request_context(&json!({"build_id": 1}), &requests).unwrap();
    assert_eq!(build_id, 1);
    assert_eq!(active_request.phase, 3);
    assert!(active_request.post_process);
    assert!(batch_asset_request_context(&json!({"build_id": 2}), &requests).is_err());
}

#[test]
fn old_workers_cannot_silently_ignore_overlay_blobs() {
    let old = json!({"capabilities": ["asset-rpc-binary-read-v1", "build-result-binary-v1", "shared-blocked-assets-v1"]});
    assert!(require_overlay_blob_capability(&old).is_err());
    assert!(
        require_overlay_blob_capability(&json!({"capabilities": ["reset-overlay-blob-v1"]}))
            .is_ok()
    );
}

#[test]
fn memory_transport_rejects_missing_source_and_cache_updates() {
    let source = "app|lib/generated.dart".to_string();
    let cache = "app|lib/generated.part".to_string();
    let sources = BTreeSet::from([source.clone()]);
    let caches = BTreeSet::from([cache.clone()]);
    let mut overlay = BTreeMap::from([
        (source.clone(), Arc::<[u8]>::from([1])),
        (cache.clone(), Arc::from([])),
    ]);
    assert!(validate_memory_overlay(&overlay, &sources, &caches).is_ok());
    for asset in [&source, &cache] {
        let bytes = overlay.remove(asset).unwrap();
        let error = validate_memory_overlay(&overlay, &sources, &caches).unwrap_err();
        assert!(error.to_string().contains(asset));
        overlay.insert(asset.clone(), bytes);
        assert!(validate_memory_overlay(&overlay, &sources, &caches).is_ok());
    }
    assert!(validate_memory_overlay(&BTreeMap::new(), &BTreeSet::new(), &BTreeSet::new()).is_ok());
}

#[test]
fn blocked_assets_reuse_tracks_exact_lists_per_connection() {
    let assets = vec!["example|lib/hidden.dart".to_owned()];
    let mut cache = BlockedAssetsCache::default();
    // A worker without the capability always receives the full list.
    assert_eq!(cache.prepare_list(assets.clone()), (assets.clone(), false));
    assert_eq!(cache.prepare_list(assets.clone()), (assets.clone(), false));
    cache.capable = true;
    assert_eq!(cache.prepare_list(assets.clone()), (assets.clone(), false));
    assert_eq!(cache.prepare_list(assets.clone()), (vec![], true));
    // Phase/deletion/context changes replace the cache, including an empty list.
    assert_eq!(cache.prepare_list(vec![]), (vec![], false));
    assert_eq!(cache.prepare_list(vec![]), (vec![], true));
    assert_eq!(cache.prepare_list(assets.clone()), (assets.clone(), false));
    let mut other = BlockedAssetsCache::new(true);
    assert_eq!(other.prepare_list(assets.clone()), (assets, false));
}

#[test]
fn interner_rollback_restores_the_pre_message_dictionary() {
    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    assert_eq!(interner.intern("pkg|lib/kept.dart"), 0);
    drop(interner);
    let checkpoint = dictionary.len();

    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    assert_eq!(interner.intern("pkg|lib/failed.dart"), 1);
    assert_eq!(interner.additions, ["pkg|lib/failed.dart"]);
    drop(interner);
    rollback_asset_dictionary(&mut dictionary, &mut index, checkpoint);
    assert_eq!(dictionary, ["pkg|lib/kept.dart"]);
    assert_eq!(index.len(), 1);

    // Re-interning after a rollback assigns the same indexes the failed
    // message used, so the worker's dictionary stays aligned.
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    assert_eq!(interner.intern("pkg|lib/failed.dart"), 1);
    assert_eq!(interner.intern("pkg|lib/kept.dart"), 0);
}

#[test]
fn interned_batch_wire_replaces_ids_with_dictionary_indexes() {
    let mut first = build_request(2, false);
    first.outputs = vec!["example|lib/out.txt".to_owned()];
    let mut second = build_request(2, false);
    second.input = "example|lib/other.txt".to_owned();
    let requests = vec![first, second];
    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let blocked = interner.intern_list(&["example|lib/hidden.dart".to_owned()]);
    let wires = batch_request_wires_with(&requests, &mut interner, || None);
    let wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 9,
        asset_dict_add: Some(interner.additions),
        blocked_assets: blocked,
        blocked_assets_reuse: false,
        shared: None,
        asset_digests: None,
        requests: &wires,
    };
    let value = serde_json::to_value(&wire).unwrap();
    assert_eq!(
        value["asset_dict_add"],
        json!([
            "example|lib/hidden.dart",
            "example|lib/input.txt",
            "example|lib/out.txt",
            "example|lib/other.txt",
        ])
    );
    assert_eq!(value["blocked_assets"], json!([0]));
    assert_eq!(value["requests"][0]["input"], json!(1));
    assert_eq!(value["requests"][0]["allowed_outputs"], json!([2]));
    assert_eq!(value["requests"][1]["input"], json!(3));
    assert_eq!(dictionary.len(), 4);

    // A later message over the same dictionary adds nothing and reuses
    // the established indexes.
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let wires = batch_request_wires_with(&requests, &mut interner, || None);
    assert!(interner.additions.is_empty());
    let value = serde_json::to_value(&wires[0]).unwrap();
    assert_eq!(value["input"], json!(1));
}

#[test]
fn asset_digest_delta_reports_updates_and_removals() {
    let sent: std::collections::HashMap<String, String> = [
        ("pkg|lib/same.dart".to_owned(), "aaa".to_owned()),
        ("pkg|lib/changed.dart".to_owned(), "bbb".to_owned()),
        ("pkg|lib/removed.dart".to_owned(), "ccc".to_owned()),
    ]
    .into_iter()
    .collect();
    let staged: std::collections::BTreeMap<String, String> = [
        ("pkg|lib/same.dart".to_owned(), "aaa".to_owned()),
        ("pkg|lib/changed.dart".to_owned(), "ddd".to_owned()),
        ("pkg|lib/added.dart".to_owned(), "eee".to_owned()),
    ]
    .into_iter()
    .collect();

    // Capability off or nothing staged: no delta is ever attached.
    assert!(compute_asset_digest_delta(false, &sent, Some(&staged)).is_empty());
    assert!(compute_asset_digest_delta(true, &sent, None).is_empty());
    // Already current: no delta.
    let current: std::collections::BTreeMap<String, String> = sent
        .iter()
        .map(|(asset, digest)| (asset.clone(), digest.clone()))
        .collect();
    assert!(compute_asset_digest_delta(true, &sent, Some(&current)).is_empty());

    let mut delta = compute_asset_digest_delta(true, &sent, Some(&staged));
    delta.sort();
    assert_eq!(
        delta,
        vec![
            ("pkg|lib/added.dart".to_owned(), Some("eee".to_owned())),
            ("pkg|lib/changed.dart".to_owned(), Some("ddd".to_owned())),
            ("pkg|lib/removed.dart".to_owned(), None),
        ]
    );
}

#[test]
fn interned_batch_wire_carries_asset_digests_by_index() {
    let requests = vec![build_request(2, false)];
    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let wires = batch_request_wires_with(&requests, &mut interner, || None);
    let digests: std::collections::BTreeMap<String, Option<String>> = [
        (
            interner.intern("example|lib/input.txt").to_string(),
            Some("2cf24dba".to_owned()),
        ),
        (interner.intern("example|lib/gone.txt").to_string(), None),
    ]
    .into_iter()
    .collect();
    let wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 11,
        asset_dict_add: Some(interner.additions),
        blocked_assets: Vec::<u32>::new(),
        blocked_assets_reuse: false,
        shared: None,
        asset_digests: Some(digests),
        requests: &wires,
    };
    let value = serde_json::to_value(&wire).unwrap();
    assert_eq!(value["asset_digests"], json!({"0": "2cf24dba", "1": null}));
}

#[test]
fn interned_shared_batch_wire_keeps_indexes_outside_shared_fields() {
    let requests = vec![build_request(2, false), build_request(2, false)];
    let shared = batch_shared_fields(&requests).expect("uniform batch");
    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let wires = batch_shared_request_wires(&requests, &mut interner);
    let wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 10,
        asset_dict_add: Some(interner.additions),
        blocked_assets: Vec::<u32>::new(),
        blocked_assets_reuse: true,
        shared: Some(shared),
        asset_digests: None,
        requests: &wires,
    };
    let value = serde_json::to_value(&wire).unwrap();
    assert_eq!(value["asset_dict_add"], json!(["example|lib/input.txt"]));
    assert_eq!(value["shared"]["builder"], json!("example:builder"));
    assert_eq!(value["requests"][0]["input"], json!(0));
    assert_eq!(value["requests"][1]["input"], json!(0));
    assert!(value["requests"][0].get("builder").is_none());
}

#[test]
fn interned_reset_values_rewrite_lists_and_overlay_index() {
    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let list = intern_asset_list(
        &json!(["example|lib/a.dart", "example|lib/b.dart"]),
        &mut interner,
    );
    assert_eq!(list, json!([0, 1]));
    // The overlay index reuses the indexes the list just established, and
    // its offsets and descriptor fields pass through unchanged.
    let blob = intern_overlay_blob(
        &json!({
            "path": "blob.bin",
            "length": 3,
            "index": {"example|lib/b.dart": {"offset": 0, "length": 3}},
        }),
        &mut interner,
    );
    assert_eq!(blob["index"], json!({"1": {"offset": 0, "length": 3}}));
    assert_eq!(blob["path"], json!("blob.bin"));
    assert_eq!(blob["length"], json!(3));
    // The blob introduced no additions beyond the list's own two ids.
    assert_eq!(
        interner.additions,
        vec!["example|lib/a.dart", "example|lib/b.dart"]
    );
    // Null and index-less descriptors pass through untouched.
    assert_eq!(
        intern_overlay_blob(&serde_json::Value::Null, &mut interner),
        serde_json::Value::Null
    );
    assert_eq!(
        intern_overlay_blob(&json!({"path": "blob.bin", "length": 0}), &mut interner),
        json!({"path": "blob.bin", "length": 0})
    );
}

#[test]
fn interned_batch_wire_preserves_exact_key_order_and_empty_dict_add() {
    if crate::telemetry::request_context().is_some() {
        return;
    }
    let mut request = build_request(2, false);
    request.outputs = vec!["example|lib/out.txt".to_owned()];
    let requests = vec![request];
    let blocked = vec!["example|lib/hidden.dart".to_owned()];

    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let interned_blocked = interner.intern_list(&blocked);
    let wires = batch_request_wires(&requests, &mut interner);
    let wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 9,
        asset_dict_add: Some(interner.additions),
        blocked_assets: interned_blocked,
        blocked_assets_reuse: false,
        shared: None,
        asset_digests: None,
        requests: &wires,
    };
    let expected = json!({
        "v": 1,
        "type": "build_batch",
        "id": 9,
        "asset_dict_add": [
            "example|lib/hidden.dart",
            "example|lib/input.txt",
            "example|lib/out.txt",
        ],
        "blocked_assets": [0],
        "blocked_assets_reuse": false,
        "requests": [{
            "id": 0,
            "builder": "example:builder",
            "input": 1,
            "kind": "normal",
            "allowed_outputs": [2],
            "options": {},
            "phase": 2,
            "part_phase_index": null,
            "instance_key": "example",
            "is_root": true,
            "triggers": [],
        }],
    });
    assert_eq!(
        serde_json::to_string(&wire).unwrap(),
        serde_json::to_string(&expected).unwrap(),
        "interned envelope must place asset_dict_add right after id",
    );

    // An interned envelope with no new dictionary entries must still emit
    // `"asset_dict_add":[]` so the worker recognizes interned mode.
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let interned_blocked = interner.intern_list(&blocked);
    let wires = batch_request_wires(&requests, &mut interner);
    assert!(interner.additions.is_empty());
    let wire_empty_add = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 10,
        asset_dict_add: Some(interner.additions),
        blocked_assets: interned_blocked,
        blocked_assets_reuse: true,
        shared: None,
        asset_digests: None,
        requests: &wires,
    };
    let expected_empty_add = json!({
        "v": 1,
        "type": "build_batch",
        "id": 10,
        "asset_dict_add": [],
        "blocked_assets": [0],
        "blocked_assets_reuse": true,
        "requests": [{
            "id": 0,
            "builder": "example:builder",
            "input": 1,
            "kind": "normal",
            "allowed_outputs": [2],
            "options": {},
            "phase": 2,
            "part_phase_index": null,
            "instance_key": "example",
            "is_root": true,
            "triggers": [],
        }],
    });
    assert_eq!(
        serde_json::to_string(&wire_empty_add).unwrap(),
        serde_json::to_string(&expected_empty_add).unwrap(),
    );

    // Plain mode omits `asset_dict_add` completely.
    let plain_wires = batch_request_wires(&requests, &mut PlainAssetIds);
    let plain_wire = BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 11,
        asset_dict_add: None,
        blocked_assets: blocked.as_slice(),
        blocked_assets_reuse: false,
        shared: None,
        asset_digests: None,
        requests: &plain_wires,
    };
    assert!(
        !serde_json::to_string(&plain_wire)
            .unwrap()
            .contains("\"asset_dict_add\"")
    );
}

#[test]
fn shared_batch_request_omits_part_phase_index_so_merge_preserves_shared_value() {
    if crate::telemetry::request_context().is_some() {
        return;
    }
    let mut first = build_request(2, false);
    first.part_phase_index = Some(1);
    let mut second = build_request(2, false);
    second.part_phase_index = Some(1);
    second.input = "example|lib/other.txt".to_owned();
    let requests = vec![first, second];

    let shared = batch_shared_fields(&requests).expect("uniform batch lifts");
    let wires = batch_shared_request_wires(&requests, &mut PlainAssetIds);
    let value = serde_json::to_value(&BatchWire {
        v: 1,
        message_type: "build_batch",
        id: 4,
        asset_dict_add: None,
        blocked_assets: &[] as &[String],
        blocked_assets_reuse: false,
        shared: Some(shared),
        asset_digests: None,
        requests: &wires,
    })
    .unwrap();

    assert_eq!(value["shared"]["part_phase_index"], json!(1));
    for child in value["requests"].as_array().unwrap() {
        assert!(
            child.get("part_phase_index").is_none(),
            "child must omit part_phase_index so worker merge does not clobber shared.part_phase_index"
        );
    }

    let shared_map = value["shared"].as_object().unwrap().clone();
    for child in value["requests"].as_array().unwrap() {
        let mut merged = shared_map.clone();
        merged.extend(child.as_object().unwrap().clone());
        assert_eq!(merged["part_phase_index"], json!(1));
    }
}

#[test]
fn write_batch_frame_matches_all_four_wire_modes_byte_for_byte() {
    if crate::telemetry::request_context().is_some() {
        return;
    }
    let mut first = build_request(2, false);
    first.part_phase_index = Some(1);
    first.outputs = vec!["example|lib/first.out".to_owned()];
    let mut second = build_request(2, false);
    second.part_phase_index = Some(1);
    second.input = "example|lib/second.txt".to_owned();
    second.outputs = vec!["example|lib/second.out".to_owned()];
    let requests = vec![first, second];
    let blocked = vec!["example|lib/hidden.dart".to_owned()];
    let digest_delta = vec![
        ("example|lib/input.txt".to_owned(), Some("aaa".to_owned())),
        ("example|lib/gone.txt".to_owned(), None),
    ];

    let decode_payload = |framed: &[u8]| -> String {
        let len = u32::from_be_bytes(framed[..4].try_into().unwrap()) as usize;
        assert_eq!(framed.len(), 4 + len);
        String::from_utf8(framed[4..].to_vec()).unwrap()
    };

    let mut buffer = Vec::new();

    // 1. Plain + full
    let mut framed = Vec::new();
    let written = write_batch_frame(
        &mut framed,
        &mut buffer,
        1,
        &requests,
        &blocked,
        false,
        &digest_delta,
        None,
        &mut PlainAssetIds,
    )
    .unwrap();
    assert_eq!(written, framed.len());
    let expected_plain_full = json!({
        "v": 1,
        "type": "build_batch",
        "id": 1,
        "blocked_assets": ["example|lib/hidden.dart"],
        "blocked_assets_reuse": false,
        "asset_digests": {
            "example|lib/gone.txt": null,
            "example|lib/input.txt": "aaa",
        },
        "requests": [
            {
                "id": 0,
                "builder": "example:builder",
                "input": "example|lib/input.txt",
                "kind": "normal",
                "allowed_outputs": ["example|lib/first.out"],
                "options": {},
                "phase": 2,
                "part_phase_index": 1,
                "instance_key": "example",
                "is_root": true,
                "triggers": [],
            },
            {
                "id": 1,
                "builder": "example:builder",
                "input": "example|lib/second.txt",
                "kind": "normal",
                "allowed_outputs": ["example|lib/second.out"],
                "options": {},
                "phase": 2,
                "part_phase_index": 1,
                "instance_key": "example",
                "is_root": true,
                "triggers": [],
            },
        ],
    });
    assert_eq!(
        decode_payload(&framed),
        serde_json::to_string(&expected_plain_full).unwrap(),
    );

    // 2. Plain + shared
    let mut framed = Vec::new();
    let shared = batch_shared_fields(&requests);
    let written = write_batch_frame(
        &mut framed,
        &mut buffer,
        2,
        &requests,
        &blocked,
        true,
        &digest_delta,
        shared,
        &mut PlainAssetIds,
    )
    .unwrap();
    assert_eq!(written, framed.len());
    let expected_plain_shared = json!({
        "v": 1,
        "type": "build_batch",
        "id": 2,
        "blocked_assets": ["example|lib/hidden.dart"],
        "blocked_assets_reuse": true,
        "shared": {
            "builder": "example:builder",
            "phase": 2,
            "kind": "normal",
            "part_phase_index": 1,
            "instance_key": "example",
            "is_root": true,
        },
        "asset_digests": {
            "example|lib/gone.txt": null,
            "example|lib/input.txt": "aaa",
        },
        "requests": [
            {
                "id": 0,
                "input": "example|lib/input.txt",
                "allowed_outputs": ["example|lib/first.out"],
                "options": {},
                "triggers": [],
            },
            {
                "id": 1,
                "input": "example|lib/second.txt",
                "allowed_outputs": ["example|lib/second.out"],
                "options": {},
                "triggers": [],
            },
        ],
    });
    assert_eq!(
        decode_payload(&framed),
        serde_json::to_string(&expected_plain_shared).unwrap(),
    );

    // 3. Interned + full (order: blocked -> digest_delta -> requests)
    let mut dictionary = Vec::new();
    let mut index = std::collections::HashMap::new();
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let mut framed = Vec::new();
    let written = write_batch_frame(
        &mut framed,
        &mut buffer,
        3,
        &requests,
        &blocked,
        false,
        &digest_delta,
        None,
        &mut interner,
    )
    .unwrap();
    assert_eq!(written, framed.len());
    let expected_interned_full = json!({
        "v": 1,
        "type": "build_batch",
        "id": 3,
        "asset_dict_add": [
            "example|lib/hidden.dart",
            "example|lib/input.txt",
            "example|lib/gone.txt",
            "example|lib/first.out",
            "example|lib/second.txt",
            "example|lib/second.out",
        ],
        "blocked_assets": [0],
        "blocked_assets_reuse": false,
        "asset_digests": {
            "1": "aaa",
            "2": null,
        },
        "requests": [
            {
                "id": 0,
                "builder": "example:builder",
                "input": 1,
                "kind": "normal",
                "allowed_outputs": [3],
                "options": {},
                "phase": 2,
                "part_phase_index": 1,
                "instance_key": "example",
                "is_root": true,
                "triggers": [],
            },
            {
                "id": 1,
                "builder": "example:builder",
                "input": 4,
                "kind": "normal",
                "allowed_outputs": [5],
                "options": {},
                "phase": 2,
                "part_phase_index": 1,
                "instance_key": "example",
                "is_root": true,
                "triggers": [],
            },
        ],
    });
    assert_eq!(
        decode_payload(&framed),
        serde_json::to_string(&expected_interned_full).unwrap(),
    );

    // 4. Interned + shared (reusing dictionary -> empty asset_dict_add)
    let mut interner = AssetInterner::new(&mut dictionary, &mut index);
    let mut framed = Vec::new();
    let shared = batch_shared_fields(&requests);
    let written = write_batch_frame(
        &mut framed,
        &mut buffer,
        4,
        &requests,
        &blocked,
        true,
        &digest_delta,
        shared,
        &mut interner,
    )
    .unwrap();
    assert_eq!(written, framed.len());
    let expected_interned_shared = json!({
        "v": 1,
        "type": "build_batch",
        "id": 4,
        "asset_dict_add": [],
        "blocked_assets": [0],
        "blocked_assets_reuse": true,
        "shared": {
            "builder": "example:builder",
            "phase": 2,
            "kind": "normal",
            "part_phase_index": 1,
            "instance_key": "example",
            "is_root": true,
        },
        "asset_digests": {
            "1": "aaa",
            "2": null,
        },
        "requests": [
            {
                "id": 0,
                "input": 1,
                "allowed_outputs": [3],
                "options": {},
                "triggers": [],
            },
            {
                "id": 1,
                "input": 4,
                "allowed_outputs": [5],
                "options": {},
                "triggers": [],
            },
        ],
    });
    assert_eq!(
        decode_payload(&framed),
        serde_json::to_string(&expected_interned_shared).unwrap(),
    );
}
