#!/usr/bin/env python3
"""Summarize BUILD_RUNNER_ACCELERATOR_WALL_TRACE=1 logs as JSON.

Usage: python3 scripts/summarize_frontend_wall.py [LOG ...] (default: stdin).
Intervals are half-open, in microseconds on each session's Rust clock. Root
categories are exclusive: the first active category in CATEGORY_PRIORITY wins.
Unknown stages and parent spans do not fill gaps. Dropped/truncated traces are
rejected rather than producing apparently complete attribution.
"""

import argparse
from bisect import bisect_left, bisect_right
from collections import defaultdict
import heapq
import json
import sys


PREFIX = 'Rust wall trace: '
CATEGORY_PRIORITY = (
    'workspace_load', 'manifest_select', 'dart_fallback', 'graph_load', 'config_digest',
    'initial_snapshot', 'planning', 'dirty_check', 'transaction_setup',
    'worker_prepare', 'phase_select', 'phase_requests', 'phase_reset',
    'phase_dispatch', 'dep_graph_merge', 'results_record', 'output_commit',
    'commit_metadata', 'post_snapshot', 'graph_update_assets', 'graph_save',
    'no_work_metadata',
)
CHILD_PRIORITY = (
    'diagnostic_json_size', 'receive_frame', 'request_encode_send',
    'result_decode_validate', 'asset_rpc',
)
BATCH_STAGES = ('worker_batch', 'worker_batch_lazy')
NOTES = [
    'All timestamps are frontend Rust wall time, relative to each native_build.',
    'receive_frame includes blocking, frame reading and JSON parsing; it is '
    'not a measurement of worker CPU.',
    'No direct Dart timestamps or worker CPU attribution are available.',
    'Child category unions may overlap (including recursive lazy work); '
    'exclusive_us uses child_priority to partition the batch.',
    'Critical batch means latest frontend finish, not a measured CPU critical path.',
    'diagnostic_json_size is metrics-only hypothetical JSON sizing nested in '
    'result_decode_validate; its exclusive time is removed from decode attribution. '
    'Zero means no recorded interval, not necessarily no sizing work.',
]


def union_intervals(intervals):
    """Merge touching or overlapping intervals without summing parallel time."""
    merged = []
    for start, end in sorted(intervals):
        if start >= end:
            continue
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(end, merged[-1][1])
        else:
            merged.append([start, end])
    return merged


def duration(intervals):
    return sum(end - start for start, end in intervals)


def coverage(intervals):
    merged = union_intervals(intervals)
    return {
        'intervals': merged,
        'union_us': duration(merged),
        'envelope': ([merged[0][0], merged[-1][1]] if merged else None),
        'envelope_us': merged[-1][1] - merged[0][0] if merged else 0,
    }


def partition(start, end, categorized, priority, gap='unattributed'):
    """Sweep endpoints in O(n log n); return an exclusive, complete partition."""
    ranks = {name: index for index, name in enumerate(priority)}
    endpoints = defaultdict(list)
    endpoints[start]
    endpoints[end]
    for name, left, right in categorized:
        left, right = max(start, left), min(end, right)
        if name in ranks and left < right:
            endpoints[left].append((ranks[name], 1))
            endpoints[right].append((ranks[name], -1))
    counts = [0] * len(priority)
    active = []
    result = {name: [] for name in (*priority, gap)}
    previous = start
    for point in sorted(endpoints):
        while active and counts[active[0]] == 0:
            heapq.heappop(active)
        name = priority[active[0]] if active else gap
        if point > previous:
            spans = result[name]
            if spans and spans[-1][1] == previous:
                spans[-1][1] = point
            else:
                spans.append([previous, point])
        for rank, delta in endpoints[point]:
            counts[rank] += delta
            if delta > 0:
                heapq.heappush(active, rank)
        previous = point
    return {name: {'intervals': spans, 'exclusive_us': duration(spans)}
            for name, spans in result.items()}


def _integer(event, key, minimum=0):
    value = event.get(key)
    if type(value) is not int or value < minimum:
        raise ValueError(f'{key} must be an integer >= {minimum}')
    return value


def _validate(event):
    if not isinstance(event, dict):
        raise ValueError('trace event must be an object')
    if not isinstance(event.get('stage'), str) or not event['stage']:
        raise ValueError('stage must be a nonempty string')
    start, end = _integer(event, 'start_us'), _integer(event, 'end_us')
    if end < start:
        raise ValueError('end_us precedes start_us')
    if event['stage'] == 'native_build':
        if start != 0:
            raise ValueError('native_build start_us must be 0')
        _integer(event, 'pid', 1)
        if _integer(event, 'dropped_events') != 0:
            raise ValueError('dropped_events is nonzero; trace is incomplete')
    else:
        if not isinstance(event.get('thread'), str) or not event['thread']:
            raise ValueError('thread must be a nonempty string')
        for key in ('phase', 'worker_pid', 'batch_id'):
            if key in event:
                _integer(event, key, 1 if key == 'worker_pid' else 0)
        if 'builder' in event and not isinstance(event['builder'], str):
            raise ValueError('builder must be a string')
        if event['stage'] in BATCH_STAGES:
            _integer(event, 'worker_pid', 1)
            _integer(event, 'batch_id')


class IntervalIndex:
    """Bound overlap scans using sorted starts and monotonic prefix-max ends.

    Typical sequential worker spans query in O(log n + matches). Long nesting
    may require additional candidates, but no full-session scan per batch.
    """

    def __init__(self, events):
        self.events = sorted(events, key=lambda e: (e['start_us'], e['end_us']))
        self.starts = [e['start_us'] for e in self.events]
        self.max_ends = []
        maximum = -1
        for event in self.events:
            maximum = max(maximum, event['end_us'])
            self.max_ends.append(maximum)

    def overlapping(self, start, end):
        left = bisect_right(self.max_ends, start)
        right = bisect_left(self.starts, end)
        return (self.events[i] for i in range(left, right)
                if self.events[i]['end_us'] > start)

    def contained(self, start, end):
        left, right = bisect_left(self.starts, start), bisect_right(self.starts, end)
        return (self.events[i] for i in range(left, right)
                if self.events[i]['end_us'] <= end)


def _batch_report(batch, child_index):
    start, end = batch['start_us'], batch['end_us']
    children = defaultdict(list)
    for event in child_index.overlapping(start, end):
        stage = event['stage']
        if stage == 'asset_rpc_lazy':
            stage = 'asset_rpc'
        if stage not in CHILD_PRIORITY:
            continue
        # receive/asset spans have no batch id; thread and worker disambiguate
        # them. Tagged children must match the IPC id. Clip at batch bounds.
        if (event.get('worker_pid') != batch['worker_pid']
                or event['thread'] != batch['thread']
                or ('batch_id' in event and event['batch_id'] != batch['batch_id'])):
            continue
        left, right = max(start, event['start_us']), min(end, event['end_us'])
        if left < right:
            children[stage].append((left, right))
    categorized = [(name, left, right) for name, spans in children.items()
                   for left, right in spans]
    exclusive = partition(start, end, categorized, CHILD_PRIORITY, 'unclassified')
    unions = {name: coverage(children[name]) for name in CHILD_PRIORITY}
    classified = coverage([(left, right) for _, left, right in categorized])
    return {
        **{key: batch[key] for key in
           ('stage', 'start_us', 'end_us', 'thread', 'worker_pid', 'batch_id')},
        'wall_us': end - start,
        'children': {name: {**unions[name],
                            'union_intervals': unions[name]['intervals'],
                            **exclusive[name]}
                     for name in CHILD_PRIORITY},
        'classified_union_us': classified['union_us'],
        'child_overlap_us': sum(item['union_us'] for item in unions.values())
                            - classified['union_us'],
        'unclassified': exclusive['unclassified'],
    }


def _session_report(root, events):
    for event in events:
        if event['end_us'] > root['end_us']:
            raise ValueError(f"{event['stage']} lies outside native_build bounds")
    dispatches = sorted((e for e in events if e['stage'] == 'phase_dispatch'),
                        key=lambda e: (e['start_us'], e['end_us'],
                                       e.get('phase', -1), e.get('builder', '')))
    child_groups = defaultdict(list)
    for event in events:
        if event['stage'] in (*CHILD_PRIORITY, 'asset_rpc_lazy'):
            child_groups[(event.get('worker_pid'), event['thread'])].append(event)
    child_indexes = {key: IntervalIndex(group) for key, group in child_groups.items()}
    empty_index = IntervalIndex([])
    batch_index = IntervalIndex([e for e in events if e['stage'] in BATCH_STAGES])
    phases = []
    for dispatch in dispatches:
        batches = sorted(batch_index.contained(dispatch['start_us'], dispatch['end_us']),
                         key=lambda e: (e['start_us'], e['end_us'],
                                        e['worker_pid'], e['batch_id'], e['stage']))
        reports = [_batch_report(batch, child_indexes.get(
            (batch['worker_pid'], batch['thread']), empty_index)) for batch in batches]
        critical = max(range(len(batches)),
                       key=lambda i: (batches[i]['end_us'], -i), default=None)
        workers = []
        worker_spans = defaultdict(list)
        for batch in batches:
            worker_spans[batch['worker_pid']].append((batch['start_us'], batch['end_us']))
        for pid, intervals in sorted(worker_spans.items()):
            workers.append({'worker_pid': pid, **coverage(intervals)})
        spans = [(b['start_us'], b['end_us']) for b in batches]
        phases.append({
            **dispatch, 'wall_us': dispatch['end_us'] - dispatch['start_us'],
            'batches': reports, 'workers': workers,
            'worker_batches': coverage(spans),
            'outside_worker_batches': partition(
                dispatch['start_us'], dispatch['end_us'],
                [('batch', left, right) for left, right in spans], ('batch',)
            )['unattributed'],
            'critical_batch_index': critical,
            'critical_batch': reports[critical] if critical is not None else None,
        })
    return {
        **root, 'wall_us': root['end_us'], 'event_count': len(events),
        'categories': partition(0, root['end_us'],
                                [(e['stage'], e['start_us'], e['end_us'])
                                 for e in events], CATEGORY_PRIORITY),
        'phase_dispatches': phases,
    }


def summarize(lines):
    """Parse a log stream; a terminal native_build closes each watch session."""
    sessions, pending = [], []
    for number, line in enumerate(lines, 1):
        if not line.startswith(PREFIX):
            continue
        try:
            event = json.loads(line[len(PREFIX):])
            _validate(event)
            if event['stage'] == 'native_build':
                sessions.append(_session_report(event, pending))
                pending = []
            else:
                pending.append(event)
        except (ValueError, TypeError) as error:
            raise ValueError(f'line {number}: {error}') from error
    if pending:
        raise ValueError('unfinished trace session: missing terminal native_build')
    if not sessions:
        raise ValueError('no Rust wall trace native_build records found')
    return {'schema_version': 1, 'unit': 'us',
            'category_priority': list(CATEGORY_PRIORITY),
            'child_priority': list(CHILD_PRIORITY), 'notes': NOTES,
            'sessions': sessions}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('logs', nargs='*', help='log paths, or - for stdin')
    args = parser.parse_args(argv)
    result = None
    try:
        for path in args.logs or ['-']:
            if path == '-':
                current = summarize(sys.stdin)
            else:
                with open(path, encoding='utf-8') as stream:
                    current = summarize(stream)
            for session in current['sessions']:
                session['source'] = path
            if result is None:
                result = current
            else:
                result['sessions'].extend(current['sessions'])
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(2, f'{parser.prog}: {error}\n')
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
