//! Stock virtual primary inputs: plan and track them, but never expose bytes.

pub(crate) const PATHS: [&str; 4] = ["$package$", "lib/$lib$", "test/$test$", "web/$web$"];

pub(crate) fn is_placeholder_path(path: &str) -> bool {
    PATHS.contains(&path)
}

pub(crate) fn is_placeholder_asset(asset: &str) -> bool {
    asset
        .split_once('|')
        .is_some_and(|(_, path)| is_placeholder_path(path))
}
