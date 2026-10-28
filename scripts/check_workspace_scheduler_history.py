#!/usr/bin/env python3
"""Check actual builder intervals, independent of worker-count metrics."""
import json
from pathlib import Path
import sys

history, jobs, cross, same = sys.argv[1:5]
ready = int(sys.argv[5]) if len(sys.argv) > 5 else 0
jobs, cross, same = int(jobs), int(cross), int(same)
records = [json.loads(path.read_text()) for path in Path(history).glob('*.json')]
pairs = {}
for record in records:
    key = (record['package'], record['stage'], record['input'])
    pairs.setdefault(key, {})[record['event']] = record
intervals = []
for key, events in pairs.items():
    assert set(events) == {'start', 'end'}, (key, events)
    start, end = events['start'], events['end']
    assert start['pid'] == end['pid'] and start['time'] < end['time'], key
    intervals.append((key, start['time'], end['time'], start['pid']))
assert len({interval[3] for interval in intervals}) <= jobs, intervals
points = sorted((time, delta) for _, start, end, _ in intervals for time, delta in [(start, 1), (end, -1)])
active = peak = 0
for _, delta in points:
    active += delta
    peak = max(peak, active)
assert active == 0 and peak <= jobs, (active, peak, jobs)
def overlap(a, b):
    return max(a[1], b[1]) < min(a[2], b[2]) and a[3] != b[3]
witnesses = [(a, b) for i, a in enumerate(intervals) for b in intervals[i+1:] if overlap(a, b)]
if cross:
    assert any({a[0][0], b[0][0]} == {'schedule_a', 'schedule_b'} for a, b in witnesses), intervals
if same:
    assert any(a[0][0] == b[0][0] == 'schedule_a' for a, b in witnesses), intervals
# The dependent member follows a within each phase. All generated-library
# consumers wait for every seed action, even on an otherwise independent member.
for a in intervals:
    for b in intervals:
        if a[0][1] == b[0][1] and a[0][0] == 'schedule_a' and b[0][0] == 'schedule_c':
            assert a[2] <= b[1], (a, b)
        if a[0][1] == 'seed' and b[0][1] == 'summary':
            assert a[2] <= b[1], (a, b)
if ready:
    a = [row for row in intervals if row[0][0] == 'schedule_a' and row[0][1] == 'seed']
    b = next(row for row in intervals if row[0][0] == 'schedule_b' and row[0][1] == 'seed')
    c = next(row for row in intervals if row[0][0] == 'schedule_c' and row[0][1] == 'seed')
    assert max(row[2] for row in a) <= c[1] < b[2], (a, b, c)
print(f'{Path(history).name}: actions={len(intervals)} peak={peak} jobs={jobs} witnesses={len(witnesses)}')
