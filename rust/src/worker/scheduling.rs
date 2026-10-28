//! Input granularity shared by ordinary and workspace dispatch.
use std::ops::Range;
use std::time::Duration;

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
}

/// Learn within one application, never across package/builder contexts. Start
/// with single-input probes; cheap work amortizes IPC in bounded batches, while
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
            // A 20ms target still leases one input when ordinary worker/IPC
            // latency is 10–20ms. Amortize that latency without making a
            // learned batch unbounded or grouping slow inputs together.
            .map(|micros| (100_000 / micros.max(1)).clamp(1, 16) as usize)
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

    #[test]
    fn probes_balance_stragglers_and_cheap_batches_leave_a_parallel_tail() {
        let mut batch = AdaptiveBatch::default();
        assert_eq!(batch.size(100, 3), 1);
        batch.observe(Duration::from_millis(1), 1);
        assert_eq!(batch.size(100, 3), 16);
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
        inputs.observe(Duration::from_millis(15), 1);
        assert_eq!(inputs.take(3), Some(1..7));
        // A straggler in an otherwise cheap batch must shrink the next lease.
        inputs.observe(Duration::from_millis(1200), 6);
        assert_eq!(inputs.take(3), Some(7..8));
    }
}
