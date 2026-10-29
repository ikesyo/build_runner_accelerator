//! Incremental readiness and indexed package-affinity selection.
use std::cmp::Reverse;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

type Key = (bool, Reverse<usize>, usize);

#[derive(Default)]
struct Candidates {
    all: BTreeSet<Key>,
    packages: BTreeMap<String, BTreeSet<Key>>,
}

impl Candidates {
    fn insert(&mut self, package: &str, key: Key) {
        self.all.insert(key);
        self.packages.entry(package.into()).or_default().insert(key);
    }

    fn remove(&mut self, package: &str, key: &Key) {
        self.all.remove(key);
        let entries = self.packages.get_mut(package).expect("indexed package");
        entries.remove(key);
        if entries.is_empty() {
            self.packages.remove(package);
        }
    }

    fn choose(&self, package: Option<&str>) -> Option<Key> {
        let first = *self.all.first()?;
        // Participation wins over affinity; affinity wins over remaining work.
        package
            .and_then(|package| self.packages.get(package))
            .and_then(BTreeSet::first)
            .copied()
            .filter(|key| key.0 == first.0)
            .or(Some(first))
    }
}

struct Entry {
    key: Key,
    package: String,
    owner: Option<usize>,
}

#[derive(Default)]
pub(super) struct ReadyInputs {
    entries: BTreeMap<usize, Entry>,
    shared: Candidates,
    pinned: BTreeMap<usize, Candidates>,
}

impl ReadyInputs {
    pub(super) fn remove(&mut self, index: usize) {
        if let Some(entry) = self.entries.remove(&index) {
            match entry.owner {
                Some(owner) => self.pinned.get_mut(&owner).expect("indexed owner"),
                None => &mut self.shared,
            }
            .remove(&entry.package, &entry.key);
        }
    }

    pub(super) fn insert(
        &mut self,
        index: usize,
        package: &str,
        remaining: usize,
        in_flight: usize,
        owner: Option<usize>,
    ) {
        self.remove(index);
        if remaining == 0 || (owner.is_some() && in_flight > 0) {
            return;
        }
        let key = (in_flight > 0, Reverse(remaining), index);
        match owner {
            Some(owner) => self.pinned.entry(owner).or_default(),
            None => &mut self.shared,
        }
        .insert(package, key);
        self.entries.insert(
            index,
            Entry {
                key,
                package: package.into(),
                owner,
            },
        );
    }

    pub(super) fn choose(&self, worker: usize, package: Option<&str>) -> Option<usize> {
        [
            self.shared.choose(package),
            self.pinned.get(&worker).and_then(|set| set.choose(package)),
        ]
        .into_iter()
        .flatten()
        .min_by_key(|key| {
            let entry = &self.entries[&key.2];
            (key.0, Some(entry.package.as_str()) != package, key.1, key.2)
        })
        .map(|key| key.2)
    }
}

/// Process each dependency edge once, on application completion.
pub(super) struct ReadyApplications {
    pending: Vec<usize>,
    successors: Vec<Vec<usize>>,
    pub(super) newly_ready: VecDeque<usize>,
    pub(super) inputs: ReadyInputs,
}

impl ReadyApplications {
    pub(super) fn new(dependencies: &[Vec<usize>], phase: &[usize]) -> Self {
        let mut queue = Self {
            pending: vec![0; dependencies.len()],
            successors: vec![Vec::new(); dependencies.len()],
            newly_ready: VecDeque::new(),
            inputs: ReadyInputs::default(),
        };
        for &index in phase {
            queue.pending[index] = dependencies[index].len();
            for &dependency in &dependencies[index] {
                queue.successors[dependency].push(index);
            }
            if queue.pending[index] == 0 {
                queue.newly_ready.push_back(index);
            }
        }
        queue
    }

    pub(super) fn finish(&mut self, index: usize) {
        for &successor in &self.successors[index] {
            self.pending[successor] -= 1;
            if self.pending[successor] == 0 {
                self.newly_ready.push_back(successor);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_preserves_participation_affinity_and_worker_pinning() {
        let mut ready = ReadyInputs::default();
        ready.insert(0, "a", 20, 1, None);
        ready.insert(1, "b", 2, 0, None);
        ready.insert(2, "c", 5, 0, None);
        assert_eq!(ready.choose(0, Some("a")), Some(2));
        assert_eq!(ready.choose(0, Some("b")), Some(1));
        ready.insert(3, "a", 10, 0, Some(1));
        assert_eq!(ready.choose(0, Some("a")), Some(2));
        assert_eq!(ready.choose(1, Some("a")), Some(3));
        ready.insert(3, "a", 9, 1, Some(1));
        assert_eq!(ready.choose(1, Some("a")), Some(2));
        ready.remove(1);
        ready.remove(2);
        assert_eq!(ready.choose(0, Some("b")), Some(0));
        ready.remove(0);
        assert_eq!(ready.choose(0, None), None);
    }
}
