"""Reject malformed OTLP IDs and accidental merging of independent build traces."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from check_otel_trace import check


def batch(trace='abcdef0123456789' * 2):
    root = {'name': 'native_build', 'traceId': trace,
            'spanId': 'abcdef0123456789', 'parentSpanId': '',
            'startTimeUnixNano': '0', 'endTimeUnixNano': '100'}
    child = {**root, 'name': 'worker_batch', 'spanId': '2' * 16,
             'parentSpanId': root['spanId'],
             'startTimeUnixNano': '10', 'endTimeUnixNano': '90'}
    return {'resourceSpans': [{'scopeSpans': [{'spans': [root, child]}]}]}


def spans(item):
    return item['resourceSpans'][0]['scopeSpans'][0]['spans']


def inspect(*batches):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'trace.ndjson'
        path.write_text(''.join(json.dumps(item) + '\n' for item in batches))
        return check(path)


class TraceValidationTest(unittest.TestCase):
    def test_distinct_builds_and_case_insensitive_parent_ids(self):
        first = batch()
        spans(first)[1]['parentSpanId'] = spans(first)[0]['spanId'].upper()
        self.assertEqual(inspect(first, batch('3' * 32))['builds'], 2)

    def test_invalid_trace_and_span_ids(self):
        for key, length in [('traceId', 32), ('spanId', 16), ('parentSpanId', 16)]:
            for value in ['bad', '0' * length, 'g' * length, '1' * (length - 1), None, 42]:
                with self.subTest(key=key, value=value):
                    item = batch()
                    spans(item)[1][key] = value
                    with self.assertRaisesRegex(ValueError, 'invalid .*ID'):
                        inspect(item)

    def test_invalid_root_ids(self):
        for key in ['traceId', 'spanId']:
            item = batch()
            spans(item)[0][key] = 'bad'
            with self.assertRaisesRegex(ValueError, 'invalid .*ID'):
                inspect(item)

    def test_reused_root_trace_id_including_different_case(self):
        first = batch()
        for trace in [spans(first)[0]['traceId'], spans(first)[0]['traceId'].upper()]:
            with self.subTest(trace=trace):
                with self.assertRaisesRegex(ValueError, 'trace ID reused'):
                    inspect(first, batch(trace))

    def test_root_with_parent_is_rejected(self):
        item = batch()
        spans(item)[0]['parentSpanId'] = '2' * 16
        with self.assertRaisesRegex(ValueError, 'must not have a parent'):
            inspect(item)

    def test_duplicate_span_ids_after_normalization(self):
        item = batch()
        spans(item)[1]['spanId'] = spans(item)[0]['spanId'].upper()
        with self.assertRaisesRegex(ValueError, 'duplicate IDs'):
            inspect(item)

    def test_mixed_trace_and_missing_or_outside_parent_remain_rejected(self):
        for key, value, error in [('traceId', '4' * 32, 'mixed trace'),
                                  ('parentSpanId', '5' * 16, 'missing parent'),
                                  ('endTimeUnixNano', '101', 'outside parent')]:
            item = batch()
            spans(item)[1][key] = value
            with self.assertRaisesRegex(ValueError, error):
                inspect(item)

    def test_parent_cycles_remain_rejected(self):
        item = batch()
        left = spans(item)[1]
        right = copy.deepcopy(left)
        right['spanId'] = '3' * 16
        right['parentSpanId'] = left['spanId']
        left['parentSpanId'] = right['spanId']
        spans(item).append(right)
        with self.assertRaisesRegex(ValueError, 'parent cycle'):
            inspect(item)


if __name__ == '__main__':
    unittest.main()
