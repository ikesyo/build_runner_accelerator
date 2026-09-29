mod asset_rpc;
mod client;
mod lazy;
mod pool;
mod request;

#[cfg(test)]
mod tests;

pub(crate) use client::WorkerClient;
pub(crate) use lazy::{LazyBuildResult, LazyBuildState};
pub(crate) use pool::{PoolMetrics, WorkerPool, shared_analysis_cache_enabled};
pub(crate) use request::BuildRequest;

#[cfg(test)]
pub(super) use asset_rpc::{
    batch_asset_request_context, missing_asset_response, validate_asset_request_context,
};
#[cfg(test)]
pub(super) use client::{has_capability, is_worker_script};
#[cfg(test)]
pub(super) use pool::{
    balanced_request_ranges, homogeneous_resolver_usage_key, remember_resolver_usage,
    target_worker_count,
};
#[cfg(test)]
pub(super) use request::batch_blocked_assets;
