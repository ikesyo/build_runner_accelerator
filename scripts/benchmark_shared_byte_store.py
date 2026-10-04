#!/usr/bin/env python3
"""Compare prepared baseline/candidate AOT workers in identical fixture/cache paths.

Compile the workers with the same SDK/package config before running. The worker
catalog must match the JSON fixtures. This excludes AOT compilation and artifact
validation, warms the SDK summary, and measures the release frontend directly.
Historical entries are synthetic, valid, unused keys in the actual analyzer pack.
The supplied cache directory is disposable and WILL be cleared by this script.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import threading
import time


def wait_for_process(process, timeout):
    """Reap the isolated frontend with wait4; kill its group on a deadline."""
    expired = threading.Event()

    def kill_group():
        expired.set()
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    watchdog = threading.Timer(timeout, kill_group)
    watchdog.daemon = True
    watchdog.start()
    try:
        try:
            _, status, usage = os.wait4(process.pid, 0)
        except BaseException:
            kill_group()
            _, status, _ = os.wait4(process.pid, 0)
            process.returncode = os.waitstatus_to_exitcode(status)
            raise
    finally:
        watchdog.cancel()
        watchdog.join()
    process.returncode = os.waitstatus_to_exitcode(status)
    if expired.is_set():
        raise subprocess.TimeoutExpired(process.args, timeout)
    return usage


def clear_graph(root):
    """Remove the graph and both source/native outputs before a clean build."""
    (root / '.dart_tool/build_runner_accelerator/graph-v3.bin').unlink(missing_ok=True)
    for f in (root / 'lib').glob('*.g.dart'):
        f.unlink()
    for f in (root / '.dart_tool/build_runner_accelerator/cache').rglob('*.g.part'):
        f.unlink()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline-worker', 'candidate-worker', 'baseline-probe',
                 'candidate-probe', 'cache', 'results', 'dart', 'frontend'):
        p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--repeats', type=int, default=5)
    p.add_argument('--jobs', type=int, default=4)
    p.add_argument('--timeout', type=float, default=300,
                   help='Maximum seconds per frontend run (default: 300).')
    p.add_argument('--counts', type=int, nargs='+', default=[10, 500])
    args = p.parse_args()
    if args.repeats < 1 or args.jobs < 1:
        p.error('--repeats and --jobs must be positive')
    if not 0 < args.timeout < float('inf'):
        p.error('--timeout must be positive and finite')
    for name in ('baseline_worker', 'candidate_worker', 'baseline_probe',
                 'candidate_probe', 'cache', 'results', 'dart', 'frontend'):
        setattr(args, name, getattr(args, name).resolve())
    repo = Path(__file__).resolve().parent.parent
    args.results.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PUB_CACHE=str(repo / '.pub-cache'),
               BUILD_RUNNER_ACCELERATOR_CACHE=str(args.cache),
               BUILD_RUNNER_ACCELERATOR_METRICS='0')
    rows = []
    expected = {}

    def measure(command, label, cwd, extra=None):
        log = args.results / label
        command = list(map(str, command))
        start = time.perf_counter()
        with log.with_suffix('.stdout').open('w') as out, log.with_suffix('.stderr').open('w') as err:
            process = subprocess.Popen(command, cwd=cwd, env=dict(env, **(extra or {})),
                                       stdout=out, stderr=err, start_new_session=True)
            usage = wait_for_process(process, args.timeout)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, command)
        elapsed = time.perf_counter() - start
        return dict(elapsed_s=elapsed, user_s=usage.ru_utime, system_s=usage.ru_stime,
                    peak_process_rss_kib=usage.ru_maxrss, command=command, cwd=str(cwd))

    def outputs(root):
        files = list((root / 'lib').glob('*.g.dart'))
        files += list((root / '.dart_tool/build_runner_accelerator/cache').rglob('*.g.part'))
        return {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest() for f in files}

    def restore_cache(template):
        for name in ('byte_store', 'dep_parse'):
            target = args.cache / name
            if target.exists(): shutil.rmtree(target)
            source = template / name
            if source.exists():
                subprocess.run(['cp', '-a', '--reflink=auto', str(source), str(target)], check=True)

    for count in args.counts:
        root = repo / f'fixtures/json_serializable_{count}_app'
        sources = {f: f.read_bytes() for f in (root / 'lib').glob('model_*.dart') if not f.name.endswith('.g.dart')}
        def reset_sources():
            for f, content in sources.items(): f.write_bytes(content)
        worker_dir = root / '.dart_tool/build_runner_accelerator/aot-sdk/bin'
        worker_dir.mkdir(parents=True, exist_ok=True)
        for name in ('lib', 'version'):
            target = worker_dir.parent / name
            if not target.exists(): target.symlink_to(args.dart.resolve().parent.parent / name)
        workers = {}
        for lane in ('baseline', 'candidate'):
            worker = worker_dir / ('bench-' + lane)
            shutil.copy2(getattr(args, lane + '_worker'), worker)
            workers[lane] = worker
        command = [args.frontend, 'build', '--root', root, '--dart', args.dart,
                   '--mode', 'rust', '--jobs', str(args.jobs)]
        def run(lane, label):
            row = measure(command, label, root,
                          {'BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH': str(workers[lane])})
            if label.endswith('-no-op'):
                text = (args.results / (label + '.stdout')).read_text()
                text += (args.results / (label + '.stderr')).read_text()
                assert 'No work to do (Rust frontend)' in text, label
            return row
        templates = {}
        try:
            # Warm equivalent caches for each format, in the real cache path.
            for lane in ('baseline', 'candidate'):
                for name in ('byte_store', 'dep_parse'):
                    if (args.cache / name).exists(): shutil.rmtree(args.cache / name)
                clear_graph(root)
                run(lane, f'prepare-{count}-{lane}')
                for size in ('small', 'large'):
                    if size == 'large':
                        packs = list((args.cache / 'byte_store').rglob('store.*.bin'))
                        assert len(packs) == 1, packs
                        subprocess.run([str(getattr(args, lane + '_probe')), 'seed', str(packs[0]),
                                        '32000', '16384'], check=True, stdout=subprocess.DEVNULL)
                    template = args.results / f'template-{count}-{lane}-{size}'
                    if template.exists(): shutil.rmtree(template)
                    template.mkdir()
                    for name in ('byte_store', 'dep_parse'):
                        if (args.cache / name).exists():
                            subprocess.run(['cp', '-a', '--reflink=auto', str(args.cache / name), str(template / name)], check=True)
                    templates[lane, size] = template
            for repeat in range(args.repeats):
                lanes = ('baseline', 'candidate') if repeat % 2 == 0 else ('candidate', 'baseline')
                for size in ('small', 'large'):
                    for lane in lanes:
                        reset_sources()
                        restore_cache(templates[lane, size])
                        clear_graph(root)
                        if size == 'small':
                            for name in ('byte_store', 'dep_parse'): shutil.rmtree(args.cache / name)
                            row = run(lane, f'{count}-{repeat}-{size}-{lane}-empty-clean')
                            row.update(count=count, repeat=repeat, size='empty', lane=lane, case='clean')
                            hashes = outputs(root)
                            key = count, 'clean'
                            if key in expected: assert hashes == expected[key]
                            expected[key] = hashes
                            row['output_sha256'] = hashes
                            rows.append(row)
                            restore_cache(templates[lane, size])
                        for case in ('clean', 'no-op', 'one-file', 'broad'):
                            if case == 'clean': clear_graph(root)
                            if case == 'one-file':
                                f = sorted(sources)[0]
                                f.write_text(re.sub(r'\bvalue\b', 'valueEdited', f.read_text()))
                            if case == 'broad':
                                for f in sources:
                                    f.write_text(re.sub(r'\bvalue\b', 'valueBroad', sources[f].decode()))
                            row = run(lane, f'{count}-{repeat}-{size}-{lane}-{case}')
                            row.update(count=count, repeat=repeat, size=size, lane=lane, case=case)
                            hashes = outputs(root)
                            assert len(hashes) == count * 2, len(hashes)
                            key = count, case
                            if case in ('one-file', 'broad'):
                                assert hashes != expected[count, 'clean'], (count, case)
                            if key in expected: assert hashes == expected[key], (count, case, lane)
                            expected[key] = hashes
                            row['output_sha256'] = hashes
                            rows.append(row)
                            (args.results / 'builds.json').write_text(json.dumps(rows, indent=2) + '\n')
                            print(count, size, lane, case, round(row['elapsed_s'], 4), flush=True)
        finally:
            reset_sources()
    summary = []
    for count in args.counts:
        for size in ('empty', 'small', 'large'):
            for case in ('clean', 'no-op', 'one-file', 'broad'):
                for lane in ('baseline', 'candidate'):
                    samples = [r for r in rows if (r['count'], r['size'], r['case'], r['lane']) == (count, size, case, lane)]
                    if samples:
                        summary.append(dict(count=count, size=size, case=case, lane=lane,
                          samples=len(samples), **{k: statistics.median(r[k] for r in samples)
                          for k in ('elapsed_s', 'user_s', 'system_s', 'peak_process_rss_kib')}))
    (args.results / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    main()
