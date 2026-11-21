mod asset_rpc;
mod client;
#[cfg(feature = "ffi-spike")]
pub(crate) use client::WorkerConnection;
mod lazy;
mod overlay_blob;
mod pool;
mod request;
mod scheduling;
mod workspace;

#[cfg(test)]
mod tests;

pub(crate) use client::{ApiUnitEvidence, WorkerClient};
#[allow(unused_imports)] // Preserve the existing crate::worker::LazyBuildResult path.
pub(crate) use lazy::LazyBuildResult;
pub(crate) use lazy::LazyBuildState;
pub(crate) use pool::{PoolMetrics, WorkerPool, shared_analysis_cache_enabled};
pub(crate) use request::BuildRequest;
pub(crate) use scheduling::InputQueue;

pub(crate) use workspace::{WorkspaceBaseline, WorkspaceDispatch, WorkspaceLease};
