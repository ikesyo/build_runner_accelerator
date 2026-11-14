use super::asset_rpc::{
    batch_asset_request_context, missing_asset_response, validate_asset_request_context,
};
use super::client::{has_capability, is_worker_script, require_overlay_blob_capability};
use super::pool::{
    homogeneous_resolver_usage_key, remember_resolver_usage, target_worker_count,
    validate_memory_overlay,
};
use super::request::{BuildRequest, batch_blocked_assets};
use crate::visibility::AssetVisibility;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

#[cfg(unix)]
mod batch_transport {
    use super::*;
    use crate::protocol::{BINARY_BUILD_RESULT_MAGIC, write_binary_frame_with_magic};
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

    fn check_response(lazy: bool, terminal: Option<u64>) -> io::Result<()> {
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
                    "dep_graph": {format!("example|entry{id}.dart"): ["example|dep.dart"]}
                }),
                &[0, 255, id as u8],
            )?;
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
        worker.blocked_assets_cache = super::super::client::BlockedAssetsCache::new(true);
        worker
            .dep_graph
            .insert("example|existing.dart".to_owned(), vec![]);
        let requests = [build_request(0, false), build_request(0, false)];
        let mut overlay = BTreeMap::new();
        let mut deleted = BTreeSet::new();
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
            // Both ordinary and lazy batches prime the same connection cache.
            assert_eq!(
                worker.blocked_assets_cache.prepare(Vec::new()),
                (vec![], true)
            );
        } else {
            assert!(result.is_err());
            assert_eq!(worker.dep_graph.len(), 1, "partial dependencies escaped");
            assert!(worker.dep_graph.contains_key("example|existing.dart"));
        }
        Ok(())
    }

    #[test]
    fn normal_and_lazy_clients_receive_complete_fragmented_batches() -> io::Result<()> {
        for lazy in [false, true] {
            check_response(lazy, Some(1))?;
        }
        Ok(())
    }

    #[test]
    fn normal_and_lazy_clients_discard_invalid_or_interrupted_batches() -> io::Result<()> {
        for lazy in [false, true] {
            check_response(lazy, None)?;
            check_response(lazy, Some(0))?;
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
    use super::client::BlockedAssetsCache;
    let assets = vec!["example|lib/hidden.dart".to_owned()];
    let mut cache = BlockedAssetsCache::default();
    // A worker without the capability always receives the full list.
    assert_eq!(cache.prepare(assets.clone()), (assets.clone(), false));
    assert_eq!(cache.prepare(assets.clone()), (assets.clone(), false));
    cache.capable = true;
    assert_eq!(cache.prepare(assets.clone()), (assets.clone(), false));
    assert_eq!(cache.prepare(assets.clone()), (vec![], true));
    // Phase/deletion/context changes replace the cache, including an empty list.
    assert_eq!(cache.prepare(vec![]), (vec![], false));
    assert_eq!(cache.prepare(vec![]), (vec![], true));
    assert_eq!(cache.prepare(assets.clone()), (assets.clone(), false));
    let mut other = BlockedAssetsCache::new(true);
    assert_eq!(other.prepare(assets.clone()), (assets, false));
}
