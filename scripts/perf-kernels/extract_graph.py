#!/usr/bin/env python3
"""Extract resolver edges from the current binary graph for kernel evaluation.

This is a diagnostic reader, never used to authorize graph reuse. The production
reader remains responsible for validation. Output is local raw benchmark data.
"""
import argparse
import json
import struct
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('graph', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
data = memoryview(a.graph.read_bytes())
offset = 0

def take(n):
    global offset
    out = data[offset:offset+n]
    if len(out) != n:
        raise ValueError('truncated graph')
    offset += n
    return out

def u32():
    return struct.unpack('>I', take(4))[0]

def string():
    return bytes(take(u32())).decode('utf-8')

def strings():
    return [string() for _ in range(u32())]

magic = bytes(take(5))
payload_length = u32()
if magic != b'BRAG\x03' or payload_length != len(data) - 9 or u32() != 7:
    raise ValueError('expected format 3, schema 7; inspect before adapting')
string()
take(1)
assets = {}
for _ in range(u32()):
    key = string(); exists = bool(take(1)[0]); digest = string(); size = struct.unpack('>Q', take(8))[0]
    assets[key] = {'exists': exists, 'digest': digest, 'size': size}
for _ in range(u32()):
    string()
    if take(1)[0]:
        string(); string(); string()
    string(); string()
    strings(); strings(); strings()
    for _ in range(u32()):
        string(); string()
    strings()
    for _ in range(u32()):
        string(); string()
    string()
edges = {}
for _ in range(u32()):
    key = string()
    edges[key] = strings()
a.output.write_text(json.dumps(edges, ensure_ascii=False))
print(f'{len(edges)} nodes, {sum(map(len, edges.values()))} edges')

a.output.with_suffix('.assets.json').write_text(json.dumps(assets))
