#[allow(dead_code)]
#[path = "../../../rust/src/digest.rs"]
mod production_digest;
// Evaluation-only kernels. Never linked into the distributed frontend.
use serde::Deserialize;
use serde_json::Value;
use std::{
    alloc::{GlobalAlloc, Layout, System},
    collections::{BTreeMap, HashMap, HashSet},
    hint::black_box,
    sync::atomic::{AtomicBool, AtomicUsize, Ordering::Relaxed},
    time::Instant,
};
struct Meter;
static COUNTING: AtomicBool = AtomicBool::new(false);
static ALLOCS: AtomicUsize = AtomicUsize::new(0);
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
// Accounting is enabled only in a separate, untimed invocation. All measured
// closures create and destroy their own allocations before returning.
unsafe impl GlobalAlloc for Meter {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if COUNTING.load(Relaxed) && !p.is_null() {
            ALLOCS.fetch_add(1, Relaxed);
            let live = LIVE.fetch_add(l.size(), Relaxed) + l.size();
            PEAK.fetch_max(live, Relaxed);
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        if COUNTING.load(Relaxed) {
            LIVE.fetch_sub(l.size(), Relaxed);
        }
        unsafe { System.dealloc(p, l) }
    }
}
#[global_allocator]
static ALLOCATOR: Meter = Meter;
fn measure(label: &str, mut f: impl FnMut()) {
    f();
    ALLOCS.store(0, Relaxed);
    LIVE.store(0, Relaxed);
    PEAK.store(0, Relaxed);
    COUNTING.store(true, Relaxed);
    f();
    COUNTING.store(false, Relaxed);
    let (a, p) = (ALLOCS.load(Relaxed), PEAK.load(Relaxed));
    let mut samples = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        let mut n = 0;
        while start.elapsed().as_millis() < 30 {
            f();
            n += 1;
        }
        samples.push(start.elapsed().as_secs_f64() * 1e9 / n as f64);
    }
    samples.sort_by(f64::total_cmp);
    println!("{label},{:.1},{a},{p}", samples[3]);
}
type Edges = BTreeMap<String, Vec<String>>;
fn closure<'a>(g: &'a Edges, seeds: &[&'a str], hash: bool) -> HashSet<&'a str> {
    let mut tree = BTreeMap::<&str, Vec<&str>>::new();
    let mut map = HashMap::<&str, Vec<&str>>::new();
    for (node, deps) in g {
        for dep in deps {
            if hash {
                map.entry(dep).or_default().push(node);
            } else {
                tree.entry(dep.as_str()).or_default().push(node);
            }
        }
    }
    let mut seen = HashSet::new();
    let mut stack = seeds.to_vec();
    while let Some(node) = stack.pop() {
        if seen.insert(node) {
            if let Some(parents) = if hash { map.get(node) } else { tree.get(node) } {
                stack.extend(parents);
            }
        }
    }
    seen
}
struct Index<'a> {
    ids: HashMap<&'a str, usize>,
    names: Vec<&'a str>,
    parents: Vec<Vec<usize>>,
}
impl<'a> Index<'a> {
    fn new(g: &'a Edges) -> Self {
        let mut ids = HashMap::new();
        let mut names = Vec::new();
        for s in g.keys().chain(g.values().flatten()) {
            if !ids.contains_key(s.as_str()) {
                ids.insert(s.as_str(), names.len());
                names.push(s.as_str());
            }
        }
        let mut parents = vec![Vec::new(); names.len()];
        for (node, deps) in g {
            for dep in deps {
                parents[ids[dep.as_str()]].push(ids[node.as_str()]);
            }
        }
        Self {
            ids,
            names,
            parents,
        }
    }
    // Benchmark domain: keys/dependencies are interned; production integration
    // must additionally handle newly changed assets outside this graph.
    fn walk(&self, seeds: &[&str], mode: usize) -> Vec<&'a str> {
        debug_assert!(seeds.iter().all(|seed| self.ids.contains_key(seed)));
        let n = self.names.len();
        let mut bits = if mode == 0 {
            vec![0u64; n.div_ceil(64)]
        } else {
            Vec::new()
        };
        let mut sparse = HashSet::new();
        let mut roaring = roaring::RoaringBitmap::new();
        let mut stack: Vec<_> = seeds
            .iter()
            .filter_map(|s| self.ids.get(s).copied())
            .collect();
        let mut found = Vec::new();
        while let Some(id) = stack.pop() {
            let fresh = match mode {
                0 => {
                    let mask = 1u64 << (id % 64);
                    let word = &mut bits[id / 64];
                    let fresh = *word & mask == 0;
                    *word |= mask;
                    fresh
                }
                1 => sparse.insert(id),
                _ => roaring.insert(id as u32),
            };
            if fresh {
                found.push(self.names[id]);
                stack.extend(&self.parents[id]);
            }
        }
        found
    }
}
fn graph(g: Edges, label: &str) {
    let keys: Vec<_> = g.keys().map(String::as_str).collect();
    if keys.is_empty() {
        return;
    }
    for (case, seeds) in [
        ("leaf", vec![keys[keys.len() - 1]]),
        ("shared", vec![keys[0]]),
        ("broad", keys.iter().step_by(10).copied().collect()),
    ] {
        let expected = closure(&g, &seeds, false);
        for hash in [false, true] {
            assert_eq!(expected, closure(&g, &seeds, hash));
            measure(
                &format!(
                    "graph/{label}/{case}/string-{}",
                    if hash { "hash" } else { "btree" }
                ),
                || {
                    black_box(closure(&g, &seeds, hash));
                },
            );
        }
        let index = Index::new(&g);
        for mode in 0..3 {
            assert_eq!(expected, index.walk(&seeds, mode).into_iter().collect());
            measure(&format!("graph/{label}/{case}/id-{mode}-rebuild"), || {
                let i = Index::new(&g);
                black_box(i.walk(&seeds, mode));
            });
            measure(&format!("graph/{label}/{case}/id-{mode}-reuse"), || {
                black_box(index.walk(&seeds, mode));
            });
        }
    }
    measure(&format!("graph/{label}/index"), || {
        black_box(Index::new(&g));
    });
}
fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |h, b| {
        (h ^ u64::from(*b)).wrapping_mul(0x100000001b3)
    })
}
fn hash(bytes: &[u8], label: &str) {
    measure(&format!("hash/{label}/fnv"), || {
        black_box(fnv(black_box(bytes)));
    });
    measure(&format!("hash/{label}/fnv-hex"), || {
        black_box(format!("{:016x}", fnv(black_box(bytes))));
    });
    measure(&format!("hash/{label}/xxh3-128-hex"), || {
        black_box(format!(
            "{:032x}",
            xxhash_rust::xxh3::xxh3_128(black_box(bytes))
        ));
    });
    measure(&format!("hash/{label}/blake3-hex"), || {
        black_box(production_digest::digest_bytes(black_box(bytes)));
    });
    measure(&format!("hash/{label}/xxh3-128"), || {
        black_box(xxhash_rust::xxh3::xxh3_128(black_box(bytes)));
    });
    measure(&format!("hash/{label}/blake3"), || {
        black_box(blake3::hash(black_box(bytes)));
    });
    measure(&format!("hash/{label}/crc32c"), || {
        black_box(crc32c::crc32c(black_box(bytes)));
    });
    measure(&format!("hash/{label}/xxh3-stream-8k"), || {
        let mut h = xxhash_rust::xxh3::Xxh3::new();
        for chunk in bytes.chunks(8192) {
            h.update(black_box(chunk));
        }
        black_box(h.digest128());
    });
    measure(&format!("hash/{label}/crc32c-stream-8k"), || {
        let mut h = 0;
        for chunk in bytes.chunks(8192) {
            h = crc32c::crc32c_append(h, black_box(chunk));
        }
        black_box(h);
    });
    if bytes.len() >= 4194304 {
        for algorithm in ["fnv", "xxh3", "blake3", "crc32c"] {
            measure(&format!("hash/{label}/{algorithm}-two-threads"), || {
                std::thread::scope(|scope| {
                    for chunk in bytes.chunks(bytes.len().div_ceil(2)) {
                        scope.spawn(move || match algorithm {
                            "fnv" => {
                                black_box(fnv(chunk));
                            }
                            "xxh3" => {
                                black_box(xxhash_rust::xxh3::xxh3_128(chunk));
                            }
                            "blake3" => {
                                black_box(blake3::hash(chunk));
                            }
                            _ => {
                                black_box(crc32c::crc32c(chunk));
                            }
                        });
                    }
                });
            });
        }
    }
    measure(&format!("hash/{label}/blake3-stream-8k"), || {
        let mut h = blake3::Hasher::new();
        for chunk in bytes.chunks(8192) {
            h.update(black_box(chunk));
        }
        black_box(h.finalize());
    });
}
#[derive(Deserialize)]
#[allow(dead_code)]
struct Config {
    #[serde(rename = "configVersion")]
    config_version: Option<u32>,
    packages: Vec<Package>,
}
#[derive(Deserialize)]
#[allow(dead_code)]
struct Package {
    name: String,
    #[serde(rename = "rootUri")]
    root: String,
    #[serde(rename = "packageUri", default)]
    uri: String,
    #[serde(rename = "languageVersion", default)]
    language: String,
}
fn json(bytes: &[u8], label: &str) {
    let expected: Value = serde_json::from_slice(bytes).unwrap();
    let mut copy = bytes.to_vec();
    let actual: Value = simd_json::serde::from_slice(&mut copy).unwrap();
    assert_eq!(expected, actual);
    assert_eq!(
        serde_json::to_vec(&expected).unwrap(),
        serde_json::to_vec(&actual).unwrap()
    );
    measure(&format!("json/{label}/serde-value"), || {
        black_box(serde_json::from_slice::<Value>(black_box(bytes)).unwrap());
    });
    measure(&format!("json/{label}/simd-value-copy"), || {
        let mut copy = bytes.to_vec();
        black_box(simd_json::serde::from_slice::<Value>(&mut copy).unwrap());
    });
    measure(&format!("json/{label}/serialize"), || {
        black_box(serde_json::to_vec(black_box(&expected)).unwrap());
    });
    measure(&format!("json/{label}/copy"), || {
        black_box(bytes.to_vec());
    });
    if serde_json::from_slice::<Config>(bytes).is_ok() {
        measure(&format!("json/{label}/serde-typed"), || {
            black_box(serde_json::from_slice::<Config>(black_box(bytes)).unwrap());
        });
    }
}
fn sets(n: usize, stride: usize) {
    let names: Vec<_> = (0..n)
        .map(|i| format!("app|lib/model_{i:06}.dart"))
        .collect();
    let a: Vec<_> = names
        .iter()
        .step_by(stride)
        .flat_map(|s| [s.as_str(), s.as_str()])
        .collect();
    let b: Vec<_> = names
        .iter()
        .skip(1)
        .step_by(2)
        .map(String::as_str)
        .collect();
    let expected = {
        let a: HashSet<_> = a.iter().copied().collect();
        let b: HashSet<_> = b.iter().copied().collect();
        (a.len(), a.intersection(&b).count(), a.union(&b).count())
    };
    measure(&format!("sets/n{n}-stride{stride}/string"), || {
        let a: HashSet<_> = a.iter().copied().collect();
        let b: HashSet<_> = b.iter().copied().collect();
        assert_eq!(
            (a.len(), a.intersection(&b).count(), a.union(&b).count()),
            expected
        );
        black_box(names.iter().filter(|s| a.contains(s.as_str())).count());
    });
    let ids: HashMap<_, _> = names
        .iter()
        .enumerate()
        .map(|(i, s)| (s.as_str(), i))
        .collect();
    for rebuild in [false, true] {
        measure(
            &format!(
                "sets/n{n}-stride{stride}/bits-{}",
                if rebuild { "rebuild" } else { "reuse" }
            ),
            || {
                let rebuilt;
                let ids = if rebuild {
                    rebuilt = names
                        .iter()
                        .enumerate()
                        .map(|(i, s)| (s.as_str(), i))
                        .collect::<HashMap<_, _>>();
                    &rebuilt
                } else {
                    &ids
                };
                let mut left = vec![0u64; n.div_ceil(64)];
                let mut right = left.clone();
                for s in &a {
                    let i = ids[s];
                    left[i / 64] |= 1 << (i % 64);
                }
                for s in &b {
                    let i = ids[s];
                    right[i / 64] |= 1 << (i % 64);
                }
                let count = left.iter().map(|w| w.count_ones() as usize).sum::<usize>();
                let intersect = left
                    .iter()
                    .zip(&right)
                    .map(|(a, b)| (a & b).count_ones() as usize)
                    .sum::<usize>();
                let union = left
                    .iter()
                    .zip(&right)
                    .map(|(a, b)| (a | b).count_ones() as usize)
                    .sum::<usize>();
                assert_eq!((count, intersect, union), expected);
                black_box(
                    names
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| left[i / 64] & (1 << (i % 64)) != 0)
                        .count(),
                );
            },
        );
    }
}

fn chunks(path: &str, capacity: usize, mut update: impl FnMut(&[u8])) {
    use std::io::Read;
    let mut file = std::fs::File::open(path).unwrap();
    let mut buffer = vec![0; capacity];
    loop {
        let n = file.read(&mut buffer).unwrap();
        if n == 0 {
            break;
        }
        update(&buffer[..n]);
    }
}
fn file_stream(path: &str, capacity: usize, algorithm: &str) -> String {
    match algorithm {
        "fnv" => {
            let mut h = 0xcbf29ce484222325u64;
            chunks(path, capacity, |bytes| {
                for b in bytes {
                    h = (h ^ u64::from(*b)).wrapping_mul(0x100000001b3);
                }
            });
            format!("{h:016x}")
        }
        "xxh3" => {
            let mut h = xxhash_rust::xxh3::Xxh3::new();
            chunks(path, capacity, |bytes| h.update(bytes));
            format!("{:032x}", h.digest128())
        }
        "crc32c" => {
            let mut h = 0;
            chunks(path, capacity, |bytes| h = crc32c::crc32c_append(h, bytes));
            format!("{h:08x}")
        }
        _ => {
            let mut h = blake3::Hasher::new();
            chunks(path, capacity, |bytes| {
                h.update(bytes);
            });
            format!("b3-{}", h.finalize().to_hex())
        }
    }
}
fn file_buffered(path: &str, algorithm: &str) -> String {
    let bytes = std::fs::read(path).unwrap();
    match algorithm {
        "fnv" => format!("{:016x}", fnv(&bytes)),
        "xxh3" => format!("{:032x}", xxhash_rust::xxh3::xxh3_128(&bytes)),
        "crc32c" => format!("{:08x}", crc32c::crc32c(&bytes)),
        _ => production_digest::digest_bytes(&bytes),
    }
}

fn main() {
    println!("case,median_ns,allocations,peak_heap_bytes");
    if std::env::args().nth(1).as_deref() == Some("compat") {
        for input in [
            r#"{"z":1,"a":"\uD83D\uDE00\n日本語","z":2}"#,
            r#"[18446744073709551615,-9223372036854775808,1.5,-0.0,1e300]"#,
            r#"[1e400]"#,
            r#""\uD800""#,
            r#"{"x":NaN}"#,
            r#"[1,]"#,
        ] {
            let a = serde_json::from_str::<Value>(input);
            let mut bytes = input.as_bytes().to_vec();
            let b = simd_json::serde::from_slice::<Value>(&mut bytes);
            println!("compat,{input:?},serde={a:?},simd={b:?}");
        }
        return;
    }
    let kind = std::env::args().nth(1).unwrap_or("all".into());
    if kind == "sets" || kind == "all" {
        for n in [64, 4096, 32768] {
            for stride in [1, 10, 100] {
                sets(n, stride);
            }
        }
    }
    if kind == "graph" || kind == "all" {
        for n in [64_usize, 4096, 32768] {
            for degree in [2, 32] {
                let mut g = Edges::new();
                for i in 0..n {
                    g.insert(
                        format!("app|lib/model_{i:06}.dart"),
                        (0..degree)
                            .map(|j| format!("app|lib/model_{:06}.dart", i.saturating_sub(j + 1)))
                            .collect(),
                    );
                }
                graph(g, &format!("n{n}-d{degree}"));
            }
        }
        if let Ok(path) = std::env::var("PERF_GRAPH") {
            graph(
                serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap(),
                "real",
            );
        }
    }
    if kind == "hash" || kind == "all" {
        for n in [16, 128, 4096, 65536, 4194304] {
            hash(&vec![b'x'; n], &format!("bytes{n}"));
        }
    }
    if kind == "stream" {
        for path in std::env::args().skip(2) {
            for algorithm in ["fnv", "xxh3", "crc32c", "blake3"] {
                let expected = file_buffered(&path, algorithm);
                measure(&format!("file/{path}/{algorithm}/buffered"), || {
                    black_box(file_buffered(&path, algorithm));
                });
                for capacity in [8192, 65536] {
                    assert_eq!(expected, file_stream(&path, capacity, algorithm));
                    measure(
                        &format!("file/{path}/{algorithm}/stream-{capacity}"),
                        || {
                            black_box(file_stream(&path, capacity, algorithm));
                        },
                    );
                }
            }
        }
        return;
    }
    for path in std::env::args().skip(2) {
        let bytes = std::fs::read(&path).unwrap();
        if kind == "hash" {
            hash(&bytes, &path);
            measure(&format!("read/{path}"), || {
                black_box(std::fs::read(&path).unwrap());
            });
        }
        if kind == "json" {
            json(&bytes, &path);
            measure(&format!("read/{path}"), || {
                black_box(std::fs::read(&path).unwrap());
            });
        }
    }
}
