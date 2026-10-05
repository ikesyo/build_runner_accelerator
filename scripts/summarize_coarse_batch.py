#!/usr/bin/env python3
"""Export paired benchmark samples and separate coarse-batch diagnostics.

Input directories come from benchmark_cold_build.py/benchmark_frontend_regen.py.
No inherited environment or raw asset paths are copied into the public summary.
"""
import argparse
from collections import defaultdict
import csv
import hashlib
import json
from pathlib import Path
import re
import statistics

from summarize_frontend_wall import summarize


def diagnostic(log):
    lines = log.read_text().splitlines()
    actions = [json.loads(line[len('Dart action metrics: '):]) for line in lines
               if line.startswith('Dart action metrics: ')]
    pids = {row['worker_pid'] for row in actions}
    sums = {field: sum(row.get(field, 0) for row in actions) for field in (
        'cycle_graph_file_loads', 'cycle_graph_walk_us', 'byte_store_gets',
        'byte_store_hits', 'dep_read_phased_us', 'resolver_reads_digest_computations',
        'resolver_reads_digest_reuses')}
    maxima = {field: sum(max(row.get(field, 0) for row in actions if row['worker_pid'] == pid)
                        for pid in pids) for field in (
                            'driver_creations', 'resolver_replacements', 'worker_rss_bytes')}
    rust = {}
    for line in lines:
        if line.startswith('Rust metrics: '):
            rust.update({key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)})
    result = dict(actions=len(actions), active_action_workers=len(pids), **sums, **maxima, rust=rust)
    result['byte_store_hit_rate'] = sums['byte_store_hits'] / sums['byte_store_gets'] if sums['byte_store_gets'] else None
    if any(isinstance(row.get('dep_loads'), list) for row in actions):
        loads = [(row['worker_pid'], item) for row in actions for item in row.get('dep_loads', [])]
        assert len(loads) == sums['cycle_graph_file_loads']
        positive = [(pid, item) for pid, item in loads if item.get('content_hash')]
        versions = {(pid, item['asset'], item['content_hash']) for pid, item in positive}
        shared = defaultdict(set)
        for pid, item in positive:
            shared[(item['asset'], item['content_hash'])].add(pid)
        result.update(positive_loads=len(positive), unavailable_loads=len(loads) - len(positive),
                      repeated_same_worker_positive_versions=len(positive) - len(versions),
                      positive_versions_loaded_by_multiple_workers=sum(len(workers) > 1 for workers in shared.values()))
    if any(line.startswith('Rust wall trace: ') for line in lines):
        sessions = summarize(lines)['sessions']
        assert len(sessions) == 1
        session = sessions[0]
        phases = []
        for phase in session['phase_dispatches']:
            finishes = defaultdict(int)
            starts = {}
            for batch in phase['batches']:
                pid = batch['worker_pid']
                finishes[pid] = max(finishes[pid], batch['end_us'])
                starts[pid] = min(starts.get(pid, batch['start_us']), batch['start_us'])
            phases.append(dict(builder=phase['builder'], phase=phase['phase'],
                               dispatch_us=phase['wall_us'], batches=len(phase['batches']),
                               workers=len(finishes),
                               finish_gap_us=max(finishes.values()) - min(finishes.values()) if finishes else 0,
                               start_gap_us=max(starts.values()) - min(starts.values()) if starts else 0))
        result.update(native_wall_us=session['wall_us'],
                      phase_dispatch_us=session['categories']['phase_dispatch']['exclusive_us'], phases=phases)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, nargs='+', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    samples, diagnostics, metadata, outputs = [], [], {}, []
    inputs, expected_outputs = {}, {}
    grouped = defaultdict(list)
    for directory in args.results:
        dataset = directory.name.removeprefix('bra-')
        meta = json.loads((directory / 'metadata.json').read_text())
        sources = meta.pop('source_sha256')
        source_digest = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
        inputs[source_digest] = sources
        meta['source_manifest_sha256'] = source_digest
        metadata[dataset] = meta
        for row in json.loads((directory / 'builds.json').read_text()):
            assert row.get('validated', True) and row.get('returncode', 0) == 0, row['log']
            sample = dict(dataset=dataset, **{k: row[k] for k in (
                'jobs', 'repeat', 'lane', 'case', 'wall_s', 'cpu_s', 'max_process_rss_kib')})
            samples.append(sample)
            grouped[(dataset, row['jobs'], row['case'], row['lane'])].append(sample)
            digest = hashlib.sha256(json.dumps(row['output_sha256'], sort_keys=True).encode()).hexdigest()
            key = (source_digest, 'cold' if row['case'] == 'regen' else row['case'])
            assert expected_outputs.setdefault(key, digest) == digest, (dataset, key)
            outputs.append(dict(dataset=dataset, jobs=row['jobs'], repeat=row['repeat'],
                                lane=row['lane'], case=row['case'], count=len(row['output_sha256']), sha256=digest))
            log = Path(row['log'])
            info = diagnostic(log)
            if info.get('native_wall_us') or info['actions']:
                diagnostics.append(dict(dataset=dataset, jobs=row['jobs'], repeat=row['repeat'],
                                        lane=row['lane'], case=row['case'], **info))
    with (args.output / 'samples.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(samples[0]))
        writer.writeheader()
        writer.writerows(samples)
    summaries = []
    for (dataset, jobs, case, lane), rows in grouped.items():
        entry = dict(dataset=dataset, jobs=jobs, case=case, lane=lane, count=len(rows))
        for key in ('wall_s', 'cpu_s', 'max_process_rss_kib'):
            values = [r[key] for r in rows]
            entry[key] = dict(median=statistics.median(values), min=min(values), max=max(values))
        summaries.append(entry)
    for name, data in (('summary', summaries), ('diagnostics', diagnostics),
                       ('metadata', metadata), ('inputs', inputs), ('outputs', outputs)):
        (args.output / f'{name}.json').write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
