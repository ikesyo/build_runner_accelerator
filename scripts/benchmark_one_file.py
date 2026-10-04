#!/usr/bin/env python3
"""Paired one-file follow-up with warm field-edit keys and actual dirty work.

Use a disposable prepared JSON fixture and explicit AOT workers. Both workers
must use that fixture's package config and SDK layout. The shared cache is kept
warm; every timed run toggles a field and must rebuild exactly two actions.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

from benchmark_shared_byte_store import clear_graph, wait_for_process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'candidate', 'baseline-worker', 'candidate-worker',
                 'dart', 'root', 'cache', 'results'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=30)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error('--repeats must be positive')
    for name in ('baseline', 'candidate', 'baseline_worker', 'candidate_worker',
                 'dart', 'root', 'cache', 'results'):
        setattr(args, name, getattr(args, name).resolve())
    args.results.mkdir(parents=True, exist_ok=True)
    source = sorted(p for p in (args.root / 'lib').glob('model_*.dart')
                    if not p.name.endswith('.g.dart'))[0]
    original = source.read_bytes()
    if not re.search(rb'\bvalue\b', original):
        parser.error('fixture must contain an editable value field')
    env = dict(os.environ, BUILD_RUNNER_ACCELERATOR_METRICS='0',
               BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache))
    env.pop('BUILD_RUNNER_ACCELERATOR_ANALYSIS_SINGLE_FLIGHT', None)
    records, expected = [], {}

    def run(lane, label):
        cmd = [str(getattr(args, lane)), 'build', '--root', str(args.root),
               '--dart', str(args.dart), '--mode', 'rust', '--jobs', '1']
        log = args.results / (label + '.log')
        start = time.perf_counter()
        with log.open('w') as stream:
            worker = getattr(args, lane + '_worker')
            process = subprocess.Popen(cmd, cwd=args.root,
                env=dict(env, BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH=str(worker)),
                stdout=stream, stderr=stream, start_new_session=True)
            usage = wait_for_process(process, 300)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, cmd)
        return time.perf_counter() - start, log, usage

    try:
        clear_graph(args.root)
        run('baseline', 'prime')
        serial = 0
        for iteration in range(-2, args.repeats):
            for lane in (('baseline', 'candidate') if iteration % 2 == 0 else ('candidate', 'baseline')):
                tag = serial % 2
                serial += 1
                source.write_bytes(re.sub(rb'\bvalue\b', ('valueCheck' + str(tag)).encode(), original))
                wall, log, usage = run(lane, str(iteration) + '-' + lane)
                assert 'Rust frontend: 2 build action(s)' in log.read_text(), log
                paths = list((args.root / 'lib').glob('*.g.dart'))
                paths += list((args.root / '.dart_tool/build_runner_accelerator/cache').rglob('*.g.part'))
                hashes = {str(p.relative_to(args.root)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in paths}
                if tag in expected:
                    assert hashes == expected[tag], log
                expected[tag] = hashes
                if iteration >= 0:
                    records.append(dict(iteration=iteration, lane=lane, tag=tag, wall_s=wall,
                                        cpu_s=usage.ru_utime + usage.ru_stime))
        (args.results / 'builds.json').write_text(json.dumps(records, indent=2) + '\n')
        summary = {}
        for lane in ('baseline', 'candidate'):
            values = [r['wall_s'] for r in records if r['lane'] == lane]
            summary[lane] = dict(median_s=statistics.median(values), min_s=min(values), max_s=max(values))
        (args.results / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary, indent=2))
    finally:
        source.write_bytes(original)


if __name__ == '__main__':
    main()
