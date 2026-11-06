#!/usr/bin/env python3
"""Validate local OTLP JSON build batches without installing a backend."""
import argparse
import json
import re
from pathlib import Path


def identifier(value, length, label):
    """Normalize nonzero OTLP hex IDs before comparisons and parent lookup."""
    if (not isinstance(value, str)
            or re.fullmatch(r'[0-9a-fA-F]{' + str(length) + '}', value) is None
            or int(value, 16) == 0):
        raise ValueError(f'invalid {label}')
    return value.lower()


def check(path):
    """Check independent build roots, valid IDs and contained causal intervals."""
    builds = 0
    trace_ids = set()
    names = {}
    for line in Path(path).read_text().splitlines():
        request = json.loads(line)
        spans = [span for resource in request['resourceSpans']
                 for scope in resource['scopeSpans'] for span in scope['spans']]
        roots = [span for span in spans if span['name'] == 'native_build']
        if len(roots) != 1:
            raise ValueError('expected one native_build root per line')
        for span in spans:
            span['traceId'] = identifier(span.get('traceId'), 32, 'trace ID')
            span['spanId'] = identifier(span.get('spanId'), 16, 'span ID')
            parent = span.get('parentSpanId', '')
            span['parentSpanId'] = identifier(parent, 16, 'parent span ID') if parent != '' else ''
        root = roots[0]
        if root['parentSpanId']:
            raise ValueError('native_build must not have a parent')
        if root['traceId'] in trace_ids:
            raise ValueError('trace ID reused across builds')
        trace_ids.add(root['traceId'])
        ids = {span['spanId']: span for span in spans}
        if len(ids) != len(spans) or len(spans) > 10001:
            raise ValueError('duplicate IDs or span budget exceeded')
        for span in spans:
            names[span['name']] = names.get(span['name'], 0) + 1
            if span['traceId'] != root['traceId']:
                raise ValueError('mixed trace IDs')
            start, end = int(span['startTimeUnixNano']), int(span['endTimeUnixNano'])
            if end < start:
                raise ValueError('negative duration')
            if span is not root:
                parent = ids.get(span.get('parentSpanId'))
                if parent is None:
                    raise ValueError(f"missing parent: {span['name']}")
                if not (int(parent['startTimeUnixNano']) <= start <= end
                        <= int(parent['endTimeUnixNano'])):
                    raise ValueError(f"outside parent (or host clock changed): {span['name']}")
            # Walking parents also detects cycles without adding durations.
            cursor, seen = span, set()
            while cursor is not root:
                if cursor['spanId'] in seen:
                    raise ValueError('parent cycle')
                seen.add(cursor['spanId'])
                cursor = ids[cursor['parentSpanId']]
        builds += 1
    if not builds:
        raise ValueError('empty trace')
    return {'builds': builds, 'spans': sum(names.values()), 'names': names}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace')
    args = parser.parse_args()
    print(json.dumps(check(args.trace), sort_keys=True))
