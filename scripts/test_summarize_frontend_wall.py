import itertools
import json
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

from summarize_frontend_wall import (
    CATEGORY_PRIORITY, PREFIX, IntervalIndex, partition, summarize, union_intervals,
)


def event(stage, start, end, **fields):
    return dict(stage=stage, start_us=start, end_us=end, thread='ThreadId(1)',
                **fields)


def root(end, **fields):
    return dict(stage='native_build', start_us=0, end_us=end, pid=42,
                dropped_events=0, **fields)


def log(*events):
    return [PREFIX + json.dumps(e) + '\n' for e in events]


def session(*events, end=100):
    return summarize(log(*events, root(end)))['sessions'][0]


class WallSummaryTest(unittest.TestCase):
    def test_dart_fallback_is_not_manifest_or_native_worker_time(self):
        result = session(event('manifest_select', 0, 10),
                         event('dart_fallback', 10, 90))
        self.assertEqual(result['categories']['manifest_select']['exclusive_us'], 10)
        self.assertEqual(result['categories']['dart_fallback']['exclusive_us'], 80)
        self.assertEqual(result['categories']['unattributed']['exclusive_us'], 10)
        self.assertEqual(result['phase_dispatches'], [])

    def test_diagnostic_json_size_partition_inside_decode(self):
        identity = {'worker_pid': 7, 'batch_id': 2}
        phase = session(event('phase_dispatch', 0, 100),
                        event('worker_batch', 10, 90, **identity),
                        event('result_decode_validate', 20, 80, **identity),
                        event('diagnostic_json_size', 30, 70, worker_pid=7),
                        event('diagnostic_json_size', 40, 75, worker_pid=7)
                        )['phase_dispatches'][0]
        children = phase['batches'][phase['critical_batch_index']]['children']
        self.assertEqual(children['diagnostic_json_size']['exclusive_us'], 45)
        self.assertEqual(children['result_decode_validate']['union_us'], 60)
        self.assertEqual(children['result_decode_validate']['exclusive_us'], 15)
        self.assertEqual(children['result_decode_validate']['intervals'], [[20, 30], [75, 80]])

    def test_index_matches_brute_force_for_nested_crossing_and_boundaries(self):
        rng = random.Random(91)
        events = [event('receive_frame', *sorted((rng.randrange(101), rng.randrange(101))))
                  for _ in range(300)]
        index = IntervalIndex(events)
        for start in range(100):
            end = start + 1
            self.assertEqual(list(index.overlapping(start, end)),
                             [e for e in index.events
                              if e['start_us'] < end and e['end_us'] > start])
            self.assertEqual(list(index.contained(start, end)),
                             [e for e in index.events
                              if start <= e['start_us'] <= end and e['end_us'] <= end])

    def test_union_nesting_crossing_touching_and_zero(self):
        self.assertEqual(union_intervals(
            [(20, 30), (0, 10), (2, 4), (8, 15), (15, 20), (40, 40)]),
            [[0, 30]])

    def test_parent_graph_save_overlap_and_explicit_gaps(self):
        result = session(event('build_with_config', 0, 100),
                         event('no_work_metadata', 10, 80),
                         event('graph_save', 30, 60), event('graph_save', 45, 70))
        categories = result['categories']
        self.assertEqual(categories['graph_save'],
                         {'intervals': [[30, 70]], 'exclusive_us': 40})
        self.assertEqual(categories['no_work_metadata']['intervals'],
                         [[10, 30], [70, 80]])
        self.assertEqual(categories['unattributed']['intervals'],
                         [[0, 10], [80, 100]])
        self.assertEqual(sum(c['exclusive_us'] for c in categories.values()), 100)
        self.assertEqual(set(categories), set(CATEGORY_PRIORITY) | {'unattributed'})

    def test_crossing_categories_are_deterministic(self):
        events = [event('workspace_load', 5, 40),
                  event('graph_load', 20, 60), event('planning', 50, 90)]
        expected = session(*events)
        for ordering in itertools.permutations(events):
            self.assertEqual(session(*ordering), expected)
        self.assertEqual(expected['categories']['graph_load']['intervals'], [[40, 60]])
        self.assertEqual(expected['categories']['planning']['intervals'], [[60, 90]])

    def test_sweep_matches_independent_discrete_oracle(self):
        rng = random.Random(37)
        for _ in range(100):
            spans = []
            for _ in range(30):
                left, right = sorted((rng.randrange(-5, 26), rng.randrange(-5, 26)))
                spans.append((rng.choice(('a', 'b', 'c')), left, right))
            actual = partition(0, 20, spans, ('a', 'b', 'c'))
            expected = dict.fromkeys(('a', 'b', 'c', 'unattributed'), 0)
            for point in range(20):
                winner = next((name for name in ('a', 'b', 'c')
                               if any(n == name and left <= point < right
                                      for n, left, right in spans)), 'unattributed')
                expected[winner] += 1
            self.assertEqual({n: v['exclusive_us'] for n, v in actual.items()}, expected)

    def test_parallel_batches_union_envelope_and_latest_finish(self):
        def worker(stage, start, end, pid=10, batch=1, thread='ThreadId(2)'):
            item = event(stage, start, end, worker_pid=pid, batch_id=batch)
            item['thread'] = thread
            return item
        events = [event('phase_dispatch', 10, 95, phase=3, builder='pkg:builder'),
                  worker('worker_batch', 20, 70),
                  worker('worker_batch', 30, 85, pid=11, thread='ThreadId(3)'),
                  worker('request_encode_send', 15, 25),
                  worker('receive_frame', 25, 50),
                  worker('receive_frame', 40, 60),
                  worker('asset_rpc', 45, 65),
                  worker('result_decode_validate', 65, 75),
                  worker('receive_frame', 20, 70, pid=99),
                  worker('request_encode_send', 20, 70, batch=999),
                  worker('receive_frame', 20, 70, thread='wrong'),
                  worker('worker_batch', 0, 15, pid=12)]
        phase = session(*events)['phase_dispatches'][0]
        self.assertEqual(phase['worker_batches']['union_us'], 65)
        self.assertEqual(phase['worker_batches']['envelope_us'], 65)
        self.assertEqual(phase['outside_worker_batches']['intervals'], [[10, 20], [85, 95]])
        self.assertEqual(phase['batches'][phase['critical_batch_index']]['worker_pid'], 11)
        self.assertEqual(phase['critical_batch_index'], 1)
        batch = phase['batches'][0]
        self.assertEqual(batch['children']['receive_frame']['union_us'], 35)
        self.assertEqual(batch['children']['asset_rpc']['union_us'], 20)
        self.assertEqual(batch['children']['asset_rpc']['exclusive_us'], 5)
        self.assertEqual(batch['children']['asset_rpc']['union_intervals'], [[45, 65]])
        self.assertEqual(batch['children']['asset_rpc']['intervals'], [[60, 65]])
        self.assertEqual(batch['child_overlap_us'], 15)
        self.assertEqual(batch['classified_union_us'], 50)
        self.assertEqual(batch['unclassified']['exclusive_us'], 0)
        self.assertEqual(len(phase['batches']), 2)
        for ordering in (events[::-1], sorted(events, key=lambda e: e['stage'])):
            self.assertEqual(session(*ordering)['phase_dispatches'][0], phase)

    def test_lazy_recursive_receive_without_batch_id_and_unclassified(self):
        identity = {'worker_pid': 7}
        phase = session(
            event('phase_dispatch', 0, 100, phase=1, builder='lazy'),
            event('worker_batch_lazy', 10, 90, batch_id=2, **identity),
            event('asset_rpc_lazy', 20, 70, **identity),
            event('receive_frame', 30, 50, **identity),
            event('receive_frame', 80, 95, **identity),
            event('result_decode_validate', 50, 60, batch_id=3, **identity),
        )['phase_dispatches'][0]
        batch = phase['batches'][phase['critical_batch_index']]
        self.assertEqual(batch['children']['asset_rpc']['union_us'], 50)
        self.assertEqual(batch['children']['receive_frame']['union_us'], 30)
        self.assertEqual(batch['children']['result_decode_validate']['union_us'], 0)
        self.assertEqual(batch['unclassified']['intervals'], [[10, 20], [70, 80]])

    def test_disjoint_batches_expose_envelope_gaps_and_finish_tie(self):
        phase = session(event('phase_dispatch', 0, 100),
                        event('worker_batch', 10, 20, worker_pid=1, batch_id=1),
                        event('worker_batch', 40, 60, worker_pid=1, batch_id=2),
                        event('worker_batch', 50, 60, worker_pid=2, batch_id=1)
                        )['phase_dispatches'][0]
        self.assertEqual(phase['worker_batches']['union_us'], 30)
        self.assertEqual(phase['worker_batches']['envelope_us'], 50)
        self.assertEqual(phase['workers'][0]['intervals'], [[10, 20], [40, 60]])
        self.assertEqual(phase['batches'][phase['critical_batch_index']]['batch_id'], 2)

    def test_multiple_sessions_have_independent_origins(self):
        result = summarize(['unrelated worker metrics\n'] + log(
            event('planning', 10, 20), root(30),
            event('graph_load', 0, 5), root(8)))
        self.assertEqual([s['wall_us'] for s in result['sessions']], [30, 8])
        self.assertEqual(result['sessions'][1]['categories']['unattributed']['intervals'],
                         [[5, 8]])
        self.assertEqual(result['sessions'][1]['event_count'], 1)

    def test_reset_workers_overlap_without_becoming_frontend_wall(self):
        events = [event('phase_reset', 0, 100, phase=2, builder='pkg:builder'),
                  event('reset_overlay_spool', 0, 10),
                  event('reset_delta_encode', 10, 15)]
        for pid, start, finish in ((10, 20, 90), (11, 25, 95)):
            events.extend([event('worker_resolver_reset', start, finish, worker_pid=pid),
                           event('reset_encode_send', start, start + 5, worker_pid=pid),
                           event('reset_receive', start + 5, finish, worker_pid=pid)])
        result = session(*events)['phase_resets'][0]
        self.assertEqual(result['wall_us'], 100)
        self.assertEqual(result['children']['worker_resolver_reset']['exclusive_us'], 75)
        self.assertEqual(result['children']['unattributed']['exclusive_us'], 10)
        self.assertEqual(sum(w['wall_us'] for w in result['workers']), 140)
        self.assertEqual([w['children']['reset_encode_send']['exclusive_us']
                          for w in result['workers']], [5, 5])
        self.assertEqual(sum(c['exclusive_us'] for c in result['children'].values()), 100)

    def test_reset_legacy_and_watch_gaps_are_preserved(self):
        result = summarize(log(event('phase_reset', 0, 20), root(30),
                               event('phase_reset', 0, 5), root(10)))
        self.assertEqual([s['phase_resets'][0]['children']['unattributed']['exclusive_us']
                          for s in result['sessions']], [20, 5])
        self.assertEqual([s['phase_resets'][0]['workers'] for s in result['sessions']], [[], []])

    def test_empty_dispatch_zero_session_and_unknown_stage(self):
        result = session(event('phase_dispatch', 0, 0), end=0)
        self.assertIsNone(result['phase_dispatches'][0]['critical_batch_index'])
        self.assertEqual(result['categories']['unattributed']['exclusive_us'], 0)
        self.assertEqual(session(event('future_stage', 0, 100))['categories']
                         ['unattributed']['exclusive_us'], 100)

    def test_validation_rejects_invalid_and_incomplete_traces(self):
        invalid = [dict(root(100), start_us=1), dict(root(100), dropped_events=1),
                   dict(root(100), dropped_events=-1), dict(root(100), dropped_events=True),
                   dict(root(100), pid=0), dict(root(100), end_us=-1),
                   dict(root(100), end_us=1.0), dict(root(100), dropped_events=None),
                   event('planning', 5, 4), event('planning', -1, 2),
                   dict(event('planning', 0, 2), thread=None),
                   dict(event('planning', 0, 2), phase=True),
                   event('worker_batch', 0, 5), event('worker_resolver_reset', 0, 5), [],
                   dict(event('planning', 0, 2), stage='')]
        for bad in invalid:
            with self.subTest(event=bad), self.assertRaises(ValueError):
                summarize(log(bad, root(100)))
        for lines in ([], ['ordinary log\n'], [PREFIX + '{broken'],
                      log(event('planning', 0, 10)),
                      log(event('planning', 0, 101), root(100)),
                      log(root(100), event('planning', 0, 10))):
            with self.subTest(lines=lines), self.assertRaises(ValueError):
                summarize(lines)

    def test_cli_stdin_files_and_failure_has_no_json(self):
        command = [sys.executable, '-B', str(Path(__file__).with_name(
            'summarize_frontend_wall.py'))]
        text = ''.join(log(event('planning', 0, 5), root(10)))
        result = subprocess.run(command, input=text, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['sessions'][0]['wall_us'], 10)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.log'
            path.write_text(text)
            result = subprocess.run(command + [str(path), str(path)], text=True,
                                    capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(json.loads(result.stdout)['sessions']), 2)
        result = subprocess.run(command, input=''.join(log(dict(root(10), dropped_events=2))),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertIn('dropped_events', result.stderr)


if __name__ == '__main__':
    unittest.main()
