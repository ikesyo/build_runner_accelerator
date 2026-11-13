//! Input granularity shared by ordinary and workspace dispatch.
use std::ops::Range;
use std::time::Duration;

// Limit estimated input work, never IPC or batch setup, to protect stragglers.
const LEASE_WORK_TARGET: Duration = Duration::from_secs(2);

#[derive(Default)]
pub(crate) struct InputQueue {
    next: usize,
    total: usize,
    batch: AdaptiveBatch,
}

impl InputQueue {
    pub(crate) fn new(total: usize) -> Self {
        Self {
            total,
            ..Self::default()
        }
    }

    pub(crate) fn remaining(&self) -> usize {
        self.total - self.next
    }

    pub(crate) fn take(&mut self, workers: usize) -> Option<Range<usize>> {
        let size = self.batch.size(self.remaining(), workers);
        if size == 0 {
            return None;
        }
        let range = self.next..self.next + size;
        self.next = range.end;
        Some(range)
    }

    pub(crate) fn observe(&mut self, elapsed: Duration, inputs: usize) {
        self.batch.observe(elapsed, inputs);
    }

    pub(crate) fn observe_results(
        &mut self,
        elapsed: Duration,
        results: &[crate::protocol::BuildResult],
    ) {
        // Use the slowest action, rather than hiding an outlier in a batch
        // average. Legacy diagnostic workers may omit timing; remain
        // conservative by falling back to their whole round-trip duration.
        let slowest = results.iter().try_fold(0_u64, |maximum, result| {
            result.execution_us.map(|micros| maximum.max(micros))
        });
        match slowest {
            Some(micros) => self.observe(Duration::from_micros(micros), 1),
            None => self.observe(elapsed, results.len()),
        }
    }
}

/// Learn within one application, never across package/builder contexts. Start
/// with single-input probes; cheap work amortizes IPC in proportional batches, while
/// slow work and the tail retain fine-grained balancing.
#[derive(Default)]
pub(crate) struct AdaptiveBatch {
    micros_per_input: Option<u128>,
}

impl AdaptiveBatch {
    pub(crate) fn size(&self, remaining: usize, workers: usize) -> usize {
        if remaining == 0 {
            return 0;
        }
        let timed = self
            .micros_per_input
            .map(|micros| {
                (LEASE_WORK_TARGET.as_micros() / micros.max(1)).clamp(1, usize::MAX as u128)
                    as usize
            })
            .unwrap_or(1);
        timed.min((remaining / workers.max(1).saturating_mul(2)).max(1))
    }

    pub(crate) fn observe(&mut self, elapsed: Duration, inputs: usize) {
        let sample = elapsed.as_micros() / inputs.max(1) as u128;
        self.micros_per_input = Some(match self.micros_per_input {
            // React immediately to expensive work; decay warm-up costs quickly.
            Some(previous) if sample < previous => (previous + 3 * sample) / 4,
            _ => sample,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(micros: Option<u64>) -> crate::protocol::BuildResult {
        serde_json::from_value(serde_json::json!({
            "type": "build_result", "id": 0, "status": "success",
            "resolver_used": false, "execution_us": micros
        }))
        .unwrap()
    }

    #[test]
    fn probes_balance_stragglers_and_cheap_batches_leave_a_parallel_tail() {
        let mut batch = AdaptiveBatch::default();
        assert_eq!(batch.size(100, 3), 1);
        batch.observe(Duration::from_millis(1), 1);
        assert_eq!(batch.size(100, 3), 16);
        assert_eq!(batch.size(26_000, 2), 2000);
        assert_eq!(batch.size(12, 3), 2);
        assert_eq!(batch.size(9, 3), 1);
        assert_eq!(batch.size(6, 3), 1);
        assert_eq!(batch.size(0, 3), 0);
        batch.observe(Duration::from_secs(2), 1);
        assert_eq!(batch.size(100, 3), 1);
    }

    #[test]
    fn amortizes_worker_latency_but_reverts_to_probes_after_expensive_work() {
        let mut inputs = InputQueue::new(240);
        assert_eq!(inputs.take(3), Some(0..1));
        inputs.observe_results(Duration::from_secs(5), &[result(Some(15_000))]);
        assert_eq!(inputs.take(3), Some(1..40));
        // A straggler in an otherwise cheap batch must shrink the next lease.
        let mut results: Vec<_> = (0..39).map(|_| result(Some(15_000))).collect();
        results[10] = result(Some(16_000_000));
        inputs.observe_results(Duration::from_secs(17), &results);
        assert_eq!(inputs.take(3), Some(40..41));
    }

    #[test]
    fn analyzer_costs_amortize_setup_and_slow_inputs_remain_individual() {
        let mut batch = AdaptiveBatch::default();
        batch.observe(Duration::from_millis(150), 1);
        assert_eq!(batch.size(3000, 8), 13);
        batch.observe(Duration::from_millis(200), 1);
        assert_eq!(batch.size(3000, 8), 10);
        batch.observe(Duration::from_secs(16), 1);
        assert_eq!(batch.size(3000, 8), 1);
    }

    #[test]
    fn large_phases_do_not_pay_setup_for_every_input() {
        for total in [3163, 26_000] {
            for workers in [2, 8] {
                for overhead_ms in [129, 5000] {
                    let mut queue = InputQueue::new(total);
                    let mut next = 0;
                    let mut leases = 0;
                    while let Some(range) = queue.take(workers) {
                        assert_eq!(range.start, next);
                        next = range.end;
                        leases += 1;
                        // Model the reported fixed batch cost plus real input work.
                        queue.observe_results(
                            Duration::from_millis(overhead_ms + 2 * range.len() as u64),
                            &(0..range.len())
                                .map(|_| result(Some(2000)))
                                .collect::<Vec<_>>(),
                        );
                    }
                    assert_eq!(next, total);
                    assert_eq!(queue.remaining(), 0);
                    assert!(
                        leases < 150,
                        "{total} inputs, {workers} workers: {leases} leases"
                    );
                }
            }
        }
    }

    #[test]
    fn absent_action_timings_use_conservative_round_trip_cost() {
        let mut queue = InputQueue::new(1000);
        queue.observe_results(Duration::from_secs(16), &[result(None)]);
        assert_eq!(queue.take(2), Some(0..1));
    }
}
