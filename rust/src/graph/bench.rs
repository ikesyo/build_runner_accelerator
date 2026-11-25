//! Opt-in benchmark of the production dirty-context path (no worker or IO).
use super::GraphState;
use crate::snapshot::AssetSnapshot;
use std::hint::black_box;
use std::time::Instant;

#[test]
#[ignore = "performance measurement; run release with --ignored --nocapture"]
fn dirty_context_benchmark() {
    for count in [64_usize, 4096, 32768] {
        let mut state = GraphState::default();
        for index in 0..count {
            let asset = format!("app|lib/model_{index:06}.dart");
            state.assets.insert(
                asset.clone(),
                AssetSnapshot {
                    exists: true,
                    digest: "0123456789abcdef".to_owned(),
                    size: 1024,
                },
            );
            // Shared dependency plus a local chain, similar to generated modules.
            state.resolver_dep_graph.insert(
                asset,
                vec![
                    "app|lib/shared.dart".to_owned(),
                    format!("app|lib/model_{:06}.dart", index.saturating_sub(1)),
                ],
            );
        }
        for case in ["no-op", "one-file", "broad"] {
            let mut current = state.assets.clone();
            if case == "one-file" {
                current.last_entry().unwrap().get_mut().digest.push('f');
            } else if case == "broad" {
                current.insert(
                    "app|lib/shared.dart".to_owned(),
                    AssetSnapshot {
                        exists: true,
                        digest: "changed".to_owned(),
                        size: 1,
                    },
                );
            }
            let repeats = if count == 64 { 1000 } else { 20 };
            for sample in 0..7 {
                let start = Instant::now();
                for _ in 0..repeats {
                    black_box(state.dirty_context(black_box(&current)));
                }
                eprintln!(
                    "dirty-context,{count},{case},{sample},{:.3}",
                    start.elapsed().as_secs_f64() * 1e6 / repeats as f64
                );
            }
        }
    }
}
