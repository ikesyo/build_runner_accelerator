#!/usr/bin/env python3
"""Separate alternating WALL_TRACE regen captures, with stock-byte checks."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts'))
from benchmark_frontend_regen import fixture_sources, output_hashes, overlaps, regen_cleanup
from benchmark_shared_byte_store import wait_for_process
from summarize_frontend_wall import summarize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'candidate', 'dart', 'root', 'cache', 'results', 'stock_reference'):
        parser.add_argument('--' + name.replace('_', '-'), type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--metrics', action='store_true')
    args = parser.parse_args()
    for name in ('baseline', 'candidate', 'dart', 'root', 'cache', 'results', 'stock_reference'):
        setattr(args, name, getattr(args, name).resolve())
    if args.repeats < 1:
        parser.error('positive repeats required')
    for left, right in ((args.root, args.cache), (args.root, args.results),
                        (args.cache, args.results)):
        if overlaps(left, right):
            parser.error('fixture, cache and results must be disjoint')
    fixture_sources(args.root)
    expected = json.loads(args.stock_reference.read_text())['cold']
    args.results.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ,
                       BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache),
                       BUILD_RUNNER_ACCELERATOR_WALL_TRACE='1',
                       BUILD_RUNNER_ACCELERATOR_METRICS=str(int(args.metrics)),
                       BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE=str(int(args.metrics)))
    for name in ('BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH',
                 'BUILD_RUNNER_ACCELERATOR_WORKER_AOT', 'BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL'):
        environment.pop(name, None)
    rows = []
    for jobs in (2, 4):
        for repeat in range(args.repeats):
            lanes = ('baseline', 'candidate') if repeat % 2 == 0 else ('candidate', 'baseline')
            for lane in lanes:
                regen_cleanup(args.root)
                command = [str(getattr(args, lane)), 'build', '--root', str(args.root),
                           '--dart', str(args.dart), '--mode', 'rust', '--jobs', str(jobs)]
                path = args.results / f'{jobs}-{repeat}-{lane}.log'
                with path.open('w') as log:
                    process = subprocess.Popen(command, cwd=args.root, env=environment,
                                               stdout=log, stderr=log, start_new_session=True)
                    wait_for_process(process, 300)
                    if process.returncode:
                        raise RuntimeError(f'failed build: {path}')
                if output_hashes(args.root) != expected:
                    raise RuntimeError(f'output mismatch: {path}')
                with path.open() as log:
                    summary = summarize(log)
                path.with_suffix('.json').write_text(json.dumps(summary, indent=2) + '\n')
                rows.append(dict(jobs=jobs, repeat=repeat, lane=lane,
                                 command=command, output_bytes_match=True,
                                 session=summary['sessions'][0]))
                (args.results / 'samples.json').write_text(json.dumps(rows, indent=2) + '\n')
                print(jobs, repeat, lane, rows[-1]['session']['wall_us'], flush=True)


if __name__ == '__main__':
    main()
