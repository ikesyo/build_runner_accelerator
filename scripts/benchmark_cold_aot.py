#!/usr/bin/env python3
"""Compare launcher-inclusive, fully cold AOT builds, then warm rebuilds.

The SDK, resolved pub packages and OS page cache are warm. Each sample gets
empty workspace, accelerator and analyzer caches. No manual prewarm runs are used.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time
try:
    import resource
except ImportError:
    resource = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument('--native', type=Path, required=True,
                        help='Release frontend; this experiment changes Dart only')
    parser.add_argument('--dart', type=Path, required=True)
    parser.add_argument('--pub-cache', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--fixture', default='json_serializable_10_app')
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--repeats', type=int, default=3)
    args = parser.parse_args()
    if args.jobs < 1 or args.repeats < 1:
        parser.error('jobs and repeats must be positive')
    repo = args.candidate_root.resolve()
    baseline = args.baseline_root.resolve()
    dart, native = str(args.dart.resolve()), str(args.native.resolve())
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=False)
    source = repo / 'fixtures' / args.fixture
    clean_env = {k: v for k, v in os.environ.items()
                 if not k.startswith('BUILD_RUNNER_ACCELERATOR_')}
    clean_env.update(PUB_CACHE=str(args.pub_cache.resolve()))
    def source_digest(package):
        digest = hashlib.sha256()
        for directory in ['lib', 'bin', 'tool']:
            for path in sorted((package / directory).rglob('*.dart')):
                digest.update(str(path.relative_to(package)).encode())
                digest.update(b'\0')
                digest.update(path.read_bytes())
        return digest.hexdigest()

    metadata = dict(
        sdk=subprocess.check_output([dart, '--version'], text=True).strip(),
        native=native, native_sha256=hashlib.sha256(Path(native).read_bytes()).hexdigest(),
        baseline=str(baseline), candidate=str(repo), fixture=args.fixture,
        baseline_sources_sha256=source_digest(baseline),
        candidate_sources_sha256=source_digest(repo),
        jobs=args.jobs, repeats=args.repeats,
        scope=__doc__, worker_policy='synchronous AOT',
    )
    (results / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    records, expected, expected_manifest, expected_worker = [], None, None, None

    def run(command, root, env, log):
        start = time.perf_counter()
        before = resource.getrusage(resource.RUSAGE_CHILDREN) if resource else None
        with log.open('w') as output:
            subprocess.run(command, cwd=root, env=env, stdout=output,
                           stderr=output, timeout=300, check=True)
        measured = dict(seconds=time.perf_counter() - start)
        if resource:
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            measured.update(child_user_seconds=after.ru_utime - before.ru_utime,
                            child_system_seconds=after.ru_stime - before.ru_stime)
        return measured

    for index in range(args.repeats):
        lanes = ['stock', 'baseline', 'candidate']
        if index % 2:
            lanes.reverse()
        for lane in lanes:
            sample = results / f'{index}-{lane}'
            root = sample / 'fixture'
            root.mkdir(parents=True)
            package_root = baseline if lane == 'baseline' else repo
            # These tracked JSON fixtures use a ../../ path dependency. Rebase
            # both manifests before unmeasured pub get, so /tmp also works.
            for name in ['pubspec.yaml', 'pubspec.lock']:
                text = (source / name).read_text()
                (root / name).write_text(text.replace('../..', str(package_root)))
            if (source / 'build.yaml').exists():
                shutil.copy2(source / 'build.yaml', root / 'build.yaml')
            shutil.copytree(source / 'lib', root / 'lib')
            def generated(path):
                return path.name.endswith(('.g.dart', '.freezed.dart'))
            for path in (root / 'lib').rglob('*.dart'):
                if generated(path):
                    path.unlink()
            env = dict(clean_env,
                       BUILD_RUNNER_ACCELERATOR_CACHE=str(sample / 'cache'),
                       ANALYZER_STATE_LOCATION_OVERRIDE=str(sample / 'analyzer'),
                       BUILD_RUNNER_ACCELERATOR_BIN=native,
                       BUILD_RUNNER_ACCELERATOR_WORKER_AOT='1')
            run([dart, '--suppress-analytics', 'pub', 'get', '--offline'],
                root, env, sample / 'pub-get.log')
            command = [dart, '--suppress-analytics', 'run']
            if lane == 'stock':
                command += ['build_runner', 'build']
            else:
                command += ['build_runner_accelerator', 'build', '--mode', 'rust',
                            '--dart', dart, '--jobs', str(args.jobs)]
            inputs = sorted((root / 'lib').rglob('*.dart'))
            for case in ['cold', 'noop', 'one-file', 'broad']:
                if case in ['one-file', 'broad']:
                    for path in inputs[:1] if case == 'one-file' else inputs:
                        path.write_bytes(path.read_bytes() + b'\n// benchmark change\n')
                measured = run(command, root, env, sample / f'{case}.log')
                outputs = {str(p.relative_to(root)): p.read_bytes()
                           for p in (root / 'lib').rglob('*.dart') if generated(p)}
                if expected is None:
                    assert lane == 'stock'
                    expected = outputs
                assert outputs and outputs == expected, f'{sample}/{case}: output mismatch'
                if lane != 'stock':
                    artifacts = root / '.dart_tool/build_runner_accelerator/aot-sdk/bin'
                    assert any(p.is_file() and '.tmp.' not in p.name
                               for p in artifacts.glob('*')), 'AOT artifact missing'
                    log = (sample / f'{case}.log').read_text()
                    assert 'using kernel/script' not in log, 'Unexpected JIT fallback'
                    assert ('Build completed (Rust frontend)' in log or
                            'No work to do (Rust frontend)' in log)
                    state = root / '.dart_tool/build_runner_accelerator'
                    manifest = json.loads((state / 'builder-manifest.json').read_text())
                    for field in ['fingerprint', 'worker_entrypoint']:
                        manifest.pop(field)
                    worker = (state / 'dynamic_worker.dart').read_bytes()
                    if expected_manifest is None:
                        expected_manifest, expected_worker = manifest, worker
                    assert manifest == expected_manifest, 'Normalized manifest differs'
                    assert worker == expected_worker, 'Generated worker catalog differs'
                record = dict(lane=lane, case=case, repeat=index, **measured,
                              outputs_equal=True, command=command)
                records.append(record)
                with (results / 'measurements.jsonl').open('a') as output:
                    output.write(json.dumps(record) + '\n')
                print(json.dumps(record), flush=True)
    for lane in ['stock', 'baseline', 'candidate']:
        for case in ['cold', 'noop', 'one-file', 'broad']:
            samples = [r['seconds'] for r in records
                       if r['lane'] == lane and r['case'] == case]
            print(f'{lane} {case}: median={statistics.median(samples):.3f}s '
                  f'range={min(samples):.3f}–{max(samples):.3f}s')


if __name__ == '__main__':
    main()
