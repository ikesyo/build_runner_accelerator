#!/usr/bin/env python3
"""Linux-only large-output comparison in a new disposable directory.

Uses the tracked arbitrary echo builder with 48 x 2 MiB text inputs. Stock
references cover clean/no-op, one-file and broad real edits. Native lane order
alternates; both binaries use the same prepared worker, paths, SDK and caches.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def output_hashes(root):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for pattern in ('*.gen.txt', '*.meta.txt')
            for p in sorted((root / 'lib').glob(pattern))}


def tree_memory(pid):
    # This environment does not expose task/*/children. Build the tree from
    # PPid instead, including children created by any thread.
    children = {}
    for status in Path('/proc').glob('[0-9]*/status'):
        try:
            fields = dict(line.split(':', 1) for line in status.read_text().splitlines() if ':' in line)
            children.setdefault(int(fields['PPid']), []).append(int(fields['Pid']))
        except (FileNotFoundError, ProcessLookupError):
            pass
    rss = pss = 0
    pending = [pid]
    seen = set()
    while pending:
        child = pending.pop()
        if child in seen:
            continue
        seen.add(child)
        pending.extend(children.get(child, []))
        try:
            for line in Path(f'/proc/{child}/smaps_rollup').read_text().splitlines():
                if line.startswith('Rss:'):
                    rss += int(line.split()[1])
                elif line.startswith('Pss:'):
                    pss += int(line.split()[1])
        except (FileNotFoundError, ProcessLookupError):
            pass
    return rss, pss


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'baseline', 'candidate', 'work'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error('repeats must be positive')
    repo, work = args.repo.resolve(), args.work.resolve()
    work.mkdir()  # refuse existing directories
    dart = repo / '.toolchains/dart/dart-sdk/bin/dart'
    env = dict(os.environ, PUB_CACHE=str(repo / '.pub-cache'),
               BUILD_RUNNER_ACCELERATOR_CACHE=str(work / 'shared-cache'))
    for key in ('BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH', 'BUILD_RUNNER_ACCELERATOR_WORKER_KERNEL',
                'BUILD_RUNNER_ACCELERATOR_METRICS', 'BUILD_RUNNER_ACCELERATOR_WALL_TRACE',
                'BUILD_RUNNER_ACCELERATOR_ANALYSIS_TRACE'):
        env.pop(key, None)
    fixture = repo / 'fixtures/arbitrary_builder_app'
    base = b'a' * (2 * 1024 * 1024 - 1) + b'\n'
    roots = {}
    for lane in ('stock', 'native'):
        root = work / lane
        (root / 'lib').mkdir(parents=True)
        for name in ('pubspec.yaml', 'pubspec.lock'):
            shutil.copy2(fixture / name, root / name)
        pubspec = root / 'pubspec.yaml'
        pubspec.write_text(pubspec.read_text().replace('path: ../..', f'path: {repo}'))
        shutil.copy2(fixture / 'lib/arbitrary_builder.dart', root / 'lib/arbitrary_builder.dart')
        (root / 'build.yaml').write_text('''builders:
  echo_builder:
    import: "package:arbitrary_builder_app/arbitrary_builder.dart"
    builder_factories: [echoBuilder]
    build_extensions: {".txt": [".gen.txt", ".meta.txt"]}
    auto_apply: none
    build_to: source
targets:
  $default:
    builders:
      arbitrary_builder_app:echo_builder:
        generate_for: ["lib/input*.txt"]
        options: {suffix: " generated"}
''')
        for i in range(48):
            (root / f'lib/input{i:02}.txt').write_bytes(base)
        with (work / f'{lane}-pub.log').open('wb') as log:
            subprocess.run([str(dart), 'pub', 'get', '--offline'], cwd=root, env=env,
                           stdout=log, stderr=log, check=True)
        roots[lane] = root

    def edit(root, case):
        for i in range(48):
            changed = case == 'broad' or (case == 'one-file' and i == 0)
            (root / f'lib/input{i:02}.txt').write_bytes((b'b' + base[1:]) if changed else base)

    stock = roots['stock']
    expected = {}
    for case in ('clean', 'no-op', 'one-file', 'broad'):
        edit(stock, 'clean' if case == 'no-op' else case)
        with (work / f'stock-{case}.log').open('wb') as log:
            subprocess.run([str(dart), 'run', 'build_runner', 'build', '--delete-conflicting-outputs'],
                           cwd=stock, env=env, stdout=log, stderr=log, check=True)
        expected[case] = output_hashes(stock)
        assert len(expected[case]) == 96
    root = roots['native']
    def command(binary, worker=None):
        cmd = [str(binary.resolve()), 'build', '--root', str(root), '--dart', str(dart),
               '--mode', 'rust', '--jobs', '2']
        if worker:
            cmd += ['--worker', str(worker)]
        return cmd
    with (work / 'prepare.log').open('wb') as log:
        subprocess.run(command(args.baseline), env=env, stdout=log, stderr=log, check=True)
    worker = root / '.dart_tool/build_runner_accelerator/aot-sdk/bin/dynamic_worker'
    if not worker.is_file() or not os.access(worker, os.X_OK):
        raise RuntimeError(f'prepared AOT worker missing: {worker}')
    metadata = dict(baseline=str(args.baseline.resolve()), candidate=str(args.candidate.resolve()),
                    sdk=subprocess.check_output([str(dart), '--version'], text=True).strip(),
                    worker=str(worker), worker_sha256=hashlib.sha256(worker.read_bytes()).hexdigest(),
                    count=48, input_bytes_each=len(base), jobs=2, repeats=args.repeats,
                    sampling_seconds=0.05, caches='prepared AOT; shared/OS caches retained',
                    binary_sha256={lane: hashlib.sha256(binary.read_bytes()).hexdigest()
                                   for lane, binary in [('baseline', args.baseline), ('candidate', args.candidate)]})
    (work / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    env['BUILD_RUNNER_ACCELERATOR_WORKER_AOT_PATH'] = str(worker)
    with (work / 'results.jsonl').open('w') as results:
        for repeat in range(args.repeats):
            lanes = [('baseline', args.baseline), ('candidate', args.candidate)]
            if repeat % 2:
                lanes.reverse()
            for lane, binary in lanes:
                for p in (root / 'lib').glob('*.gen.txt'):
                    p.unlink()
                for p in (root / 'lib').glob('*.meta.txt'):
                    p.unlink()
                (root / '.dart_tool/build_runner_accelerator/graph-v3.bin').unlink(missing_ok=True)
                for case in ('clean', 'no-op', 'one-file', 'broad'):
                    edit(root, 'clean' if case == 'no-op' else case)
                    cmd = command(binary, worker)
                    with (work / f'{repeat}-{lane}-{case}.log').open('wb') as log:
                        start = time.monotonic()
                        process = subprocess.Popen(cmd, env=env, stdout=log, stderr=log)
                        peak_rss = peak_pss = 0
                        while True:
                            rss, pss = tree_memory(process.pid)
                            peak_rss, peak_pss = max(peak_rss, rss), max(peak_pss, pss)
                            done, status, usage = os.wait4(process.pid, os.WNOHANG)
                            if done:
                                process.returncode = os.waitstatus_to_exitcode(status)
                                break
                            time.sleep(0.05)
                        elapsed = time.monotonic() - start
                    if process.returncode:
                        raise RuntimeError(f'{lane}/{case} failed: see log')
                    assert output_hashes(root) == expected[case], (lane, case)
                    record = dict(repeat=repeat, lane=lane, case=case, wall_s=elapsed,
                                  cpu_s=usage.ru_utime + usage.ru_stime,
                                  max_single_process_rss_kib=usage.ru_maxrss,
                                  sampled_tree_rss_kib=peak_rss, sampled_tree_pss_kib=peak_pss,
                                  stock_byte_identical=True, command=cmd)
                    results.write(json.dumps(record) + '\n')
                    results.flush()
                    print(json.dumps(record), flush=True)


if __name__ == '__main__':
    main()
