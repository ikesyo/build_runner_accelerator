use super::asset_rpc::{
    batch_asset_request_context, missing_asset_response, validate_asset_request_context,
};
use super::client::{has_capability, is_worker_script, require_overlay_blob_capability};
use super::pool::{
    balanced_request_ranges, homogeneous_resolver_usage_key, remember_resolver_usage,
    resolver_worker_limit, target_worker_count, validate_memory_overlay,
};
use super::request::{BuildRequest, batch_blocked_assets};
use crate::visibility::AssetVisibility;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

fn build_request(phase: u32, post_process: bool) -> BuildRequest {
    BuildRequest {
        builder: "example:builder".to_owned(),
        input: "example|lib/input.txt".to_owned(),
        outputs: Vec::new(),
        options: BTreeMap::new(),
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
fn resolver_cap_limits_startup_before_a_later_wider_phase() {
    for (jobs, default) in [(1, 1), (2, 2), (4, 2)] {
        for (cap, expected) in [
            (None, default),
            (Some(1), 1),
            (Some(2), jobs.min(2)),
            (Some(usize::MAX), jobs),
        ] {
            let limit = resolver_worker_limit(jobs, cap);
            assert_eq!(target_worker_count(jobs, 8).min(limit), expected);
            assert_eq!(target_worker_count(jobs, 1).min(limit), 1);
            // A subsequent unrestricted phase can extend the resident pool.
            assert_eq!(target_worker_count(jobs, 8), jobs);
        }
    }
}

#[test]
fn requests_are_split_into_balanced_contiguous_batches() {
    assert_eq!(
        balanced_request_ranges(10, 3),
        vec![(0, 4), (4, 7), (7, 10)]
    );
    assert_eq!(balanced_request_ranges(3, 3), vec![(0, 1), (1, 2), (2, 3)]);
    assert_eq!(balanced_request_ranges(2, 4), vec![(0, 1), (1, 2)]);
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
