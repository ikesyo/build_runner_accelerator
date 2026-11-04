#!/usr/bin/env python3
"""Create a diagnostic-only Rust source copy; build separately before profiling.

Logs hash calls/size/compute ns, snapshot reads, IPC JSON parse sizes/times and
the enclosing workspace/manifest wall stages. Run with WALL_TRACE=1 for surrounding stage costs.
Logging overhead makes this unsuitable for elapsed-time comparisons.
"""
import argparse
import subprocess
import tarfile
import io
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('destination',type=Path)
p.add_argument('--revision', default='origin/main')
a=p.parse_args()
repo=Path(__file__).resolve().parents[2]
root=a.destination
root.mkdir(parents=True,exist_ok=False)
archive = subprocess.check_output(['git', 'archive', a.revision + ':rust'], cwd=repo)
with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
    tar.extractall(root, filter='data')
path=root/'src/digest.rs'
source=path.read_text()
assert 'pub fn digest_bytes(bytes: &[u8]) -> String {\n    let mut hash' in source, 'Expected baseline FNV; inspect a changed revision before profiling'
s=source.replace('pub fn digest_bytes', '#[track_caller]\npub fn digest_bytes').replace('    let mut hash =','    let start = std::time::Instant::now();\n    let mut hash =',1)
s=s.replace('    format!("{hash:016x}")','    let out = format!("{hash:016x}");\n    eprintln!("perf-hash,{},{},{},{}", bytes.len(), start.elapsed().as_nanos(), std::panic::Location::caller().file(), std::panic::Location::caller().line());\n    out')
path.write_text(s)
path=root/'src/snapshot.rs'
s=path.read_text().replace('            let bytes = std::fs::read(&path)?;', '            let start = std::time::Instant::now();\n            let bytes = std::fs::read(&path)?;\n            eprintln!("perf-read,{},{},{}", path.display(), bytes.len(), start.elapsed().as_nanos());')
path.write_text(s)
path=root/'src/protocol.rs'
s=path.read_text()
s=s.replace('        return Ok(IncomingFrame::Binary(BinaryFrame {','        eprintln!("perf-json,binary-metadata,{},{}", metadata_length, start.elapsed().as_nanos());\n        return Ok(IncomingFrame::Binary(BinaryFrame {')
s=s.replace('    serde_json::from_slice(&payload)\n        .map(IncomingFrame::Json)\n        .map_err(io::Error::other)','    let result = serde_json::from_slice(&payload).map(IncomingFrame::Json).map_err(io::Error::other);\n    eprintln!("perf-json,control,{},{}", payload.len(), start.elapsed().as_nanos());\n    result')
s=s.replace('        let metadata = serde_json::from_slice', '        perf_dump_json(&payload[metadata_start..bytes_start]);\n        let start = std::time::Instant::now();\n        let metadata = serde_json::from_slice')
s=s.replace('    let result = serde_json::from_slice(&payload)', '    perf_dump_json(&payload);\n    let start = std::time::Instant::now();\n    let result = serde_json::from_slice(&payload)')
s=s.replace('    let payload = serde_json::to_vec(message).map_err(io::Error::other)?;', '    let start = std::time::Instant::now();\n    let payload = serde_json::to_vec(message).map_err(io::Error::other)?;\n    eprintln!("perf-json-write,control,{},{}", payload.len(), start.elapsed().as_nanos());')
s=s.replace('    let metadata = serde_json::to_vec(metadata).map_err(io::Error::other)?;', '    let start = std::time::Instant::now();\n    let metadata = serde_json::to_vec(metadata).map_err(io::Error::other)?;\n    eprintln!("perf-json-write,binary-metadata,{},{}", metadata.len(), start.elapsed().as_nanos());')
s += '\nfn perf_dump_json(bytes: &[u8]) {\n    if let Ok(dir) = std::env::var("PERF_JSON_DIRECTORY") {\n        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);\n        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);\n        let _ = std::fs::write(std::path::Path::new(&dir).join(format!("{}-{n}.json", std::process::id())), bytes);\n    }\n}\n'
path.write_text(s)
print(root)
