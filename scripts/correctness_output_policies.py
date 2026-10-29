#!/usr/bin/env python3
"""Differential output-policy lifecycle checks using the tracked multi-output fixture."""
from pathlib import Path
import json
import os
import re
import signal
import shutil
import subprocess
import tempfile
import time
from correctness_build_filter import (prepare, outputs, execute, fixture_env, activity_path)
from correctness_cli import DART, ENV, NATIVE, launcher

VERIFY = '--only-check'
KEEP = '--keep-modified-outputs'


def lifecycle_matrix(coverage):
    """Cover every pair of policy/layout/filter settings on PRs.

    Full local/main validation retains the complete three-axis cross product.
    Each selected row still executes the entire lifecycle and its assertions.
    """
    if coverage not in ('full', 'pairwise'):
        raise ValueError(f'unknown output-policy coverage: {coverage}')
    return [(cache, filtered, policy)
            for cache in (False, True)
            for filtered in (False, True)
            for policy in ('verify', 'keep')
            if coverage == 'full' or filtered == (cache == (policy == 'verify'))]


def snapshot(root):
    """Source outputs, intermediate bytes and incremental graph, excluding setup caches."""
    result = {}
    for file in root.rglob('*'):
        if (file.suffix in ('.mid', '.side', '.final', '.ignored', '.post')
                or file.name in ('one.dart', 'two.dart', 'shared.dart',
                                 'asset_graph.json', 'graph-v3.bin')) and file.is_file():
            metadata = file.stat()
            # Detect equal-content rewrites as well as byte/existence changes.
            result[str(file.relative_to(root))] = (
                file.read_bytes(), metadata.st_ino, metadata.st_mtime_ns)
    return result


def diagnostics(log):
    return sorted(re.findall(r'\b([IMU] lib/[^\s]+)', log))


class Pair:
    def __init__(self, tmp, name, cache=False):
        self.stock, self.native = tmp / (name + '-stock'), tmp / (name + '-native')
        for root in self.roots:
            prepare(root)
            if cache:
                config = root / 'build.yaml'
                config.write_text(config.read_text().replace('build_to: source', 'build_to: cache', 1))

    @property
    def roots(self):
        return self.stock, self.native

    def write(self, name, value):
        for root in self.roots:
            (root / ('lib/' + name)).write_text(value)

    def delete(self, name):
        for root in self.roots:
            (root / ('lib/' + name)).unlink(missing_ok=True)

    def check(self, *flags, expected=0, compile_flag='--force-jit', jobs=1):
        before = [snapshot(root) for root in self.roots] if VERIFY in flags else None
        reference = execute([DART, 'run', 'build_runner', 'build', compile_flag, *flags], self.stock)
        args = launcher(self.native, flags=[compile_flag, *flags])
        args[args.index('--jobs=1')] = f'--jobs={jobs}'
        actual = execute(args, self.native)
        assert reference[0] == actual[0] == expected, (flags, reference, actual)
        assert outputs(self.stock) == outputs(self.native), (flags, outputs(self.stock), outputs(self.native), actual)
        if VERIFY in flags:
            assert before == [snapshot(root) for root in self.roots], (flags, 'verification wrote outputs/state')
            assert diagnostics(reference[1]) == diagnostics(actual[1]), (reference, actual)
        if expected == 0:
            assert '(Rust frontend)' in actual[1], actual
        print(f'output-policies: PASS {self.native.name} {flags} status={expected}', flush=True)
        return reference, actual


def verify_cases(tmp, cache, filters):
    pair = Pair(tmp, f'verify-{cache}-{bool(filters)}', cache)
    if cache:
        pair.write('a.mid', 'initial conflict at a cache output source path\n')
    pair.check(VERIFY, *filters, expected=1)  # clean missing/new outputs
    pair.check(*filters)
    if cache:
        assert not (pair.native / 'lib/a.mid').exists()
        # Also cover an otherwise reusable graph. Failure must leave the
        # conflict and every committed output intact; recovery removes it.
        pair.write('a.mid', 'warm conflict at a cache output source path\n')
        pair.check(VERIFY, *filters, expected=1)
        baseline = snapshot(pair.native)
        pair.write('common.txt', 'fail\n')
        actual = execute(launcher(pair.native, flags=['--force-jit', *filters]), pair.native)
        reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *filters], pair.stock)
        assert actual[0] == reference[0] == 1, (reference, actual)
        assert snapshot(pair.native) == baseline, actual
        pair.write('common.txt', 'common\n')
        pair.check(*filters)
        assert not (pair.native / 'lib/a.mid').exists()
        pair.check(*filters)
    pair.check(VERIFY, *filters)
    # Presubmit checkout: generated package files exist, but no incremental
    # graph or artifact tree is available. Matching bytes must still pass.
    for root in pair.roots:
        for relative in ('.dart_tool/build/asset_graph.json',
                         '.dart_tool/build_runner_accelerator/graph-v3.bin'):
            (root / relative).unlink(missing_ok=True)
        for relative in ('.dart_tool/build/generated',
                         '.dart_tool/build_runner_accelerator/cache'):
            shutil.rmtree(root / relative, ignore_errors=True)
    pair.check(VERIFY, *filters)
    pair.check(*filters)
    pair.write('a.txt', 'changed\n')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(VERIFY, *filters, expected=1)  # failed verification cannot poison reuse
    pair.check(*filters)
    pair.delete('a.final')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(*filters)
    pair.write('a.txt', 'empty\n')  # previous multi-outputs and their consumer disappear
    pair.check(VERIFY, *filters, expected=1)
    pair.check(*filters)
    pair.write('a.txt', 'restored\n')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(*filters)
    pair.delete('a.txt')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(*filters)
    pair.check(VERIFY, *filters)
    # A conflicting unrecorded declared-but-unemitted output is unexpected.
    pair.write('empty.final', 'conflict\n')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(*filters)
    pair.write('new.txt', 'new incremental output\n')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(*filters)
    pair.check(VERIFY, *filters)
    if cache:
        # Artifact-only differences do not fail verify or get written.
        for root in pair.roots:
            base = (root / '.dart_tool/build/generated/build_filter_app' if root == pair.stock
                    else root / '.dart_tool/build_runner_accelerator/cache/build_filter_app')
            for file in base.glob('lib/b.*'):
                file.unlink()
        pair.check(VERIFY, *filters)
        pair.check(*filters)


def keep_cases(tmp, cache, filters):
    pair = Pair(tmp, f'keep-{cache}-{bool(filters)}', cache)
    pair.write('a.final', 'initial conflicting output\n')
    if cache:
        pair.write('a.mid', 'initial conflict at a cache output source path\n')
    pair.check(KEEP, *filters)  # initial conflicts are overwritten
    pair.write('a.final', 'manual final\n')
    for root in pair.roots:
        base = (root / '.dart_tool/build/generated/build_filter_app' if root == pair.stock
                else root / '.dart_tool/build_runner_accelerator/cache/build_filter_app') if cache else root
        (base / 'lib/common.side').write_text('manual shared\n')
        (base / 'lib/a.mid').write_text('manual primary\n')
    pair.check(KEEP, *filters)
    pair.check(KEEP, *filters)  # process restart must retain old logical digests
    assert (pair.native / 'lib/a.final').read_text() == 'manual final\n'
    pair.write('b.txt', 'changed dependent\n')
    pair.check(KEEP, *filters)  # consumers can read retained modified bytes
    pair.delete('a.final')
    pair.check(KEEP, *filters)  # missing output forces regeneration
    # A deleted intermediate triggers its producer; equal regenerated bytes do
    # not invalidate retained downstream output solely because it was rebuilt.
    for root in pair.roots:
        base = (root / '.dart_tool/build/generated/build_filter_app' if root == pair.stock
                else root / '.dart_tool/build_runner_accelerator/cache/build_filter_app') if cache else root
        (base / 'lib/a.side').write_text('manual sibling before deletion\n')
        (base / 'lib/a.mid').unlink()
    pair.check(KEEP, *filters)
    pair.write('a.final', 'manual final again\n')
    pair.write('a.txt', 'input changed\n')
    pair.write('b.txt', 'parallel input changed\n')
    pair.check(KEEP, *filters, jobs=2)  # input change overwrites manually edited output
    assert (pair.native / 'lib/a.final').read_text() != 'manual final again\n'
    pair.write('a.final', 'retained equal upstream\n')
    pair.write('a.txt', 'input changed\n# same generated bytes\n')
    pair.check(KEEP, *filters)
    assert (pair.native / 'lib/a.final').read_text() == 'retained equal upstream\n'
    pair.write('a.final', 'manual switch\n')
    pair.check(VERIFY, *filters, expected=1)
    pair.check(KEEP, *filters)
    pair.check(*filters)  # ordinary overwrite restores output
    pair.check(VERIFY, *filters)
    # The real upstream file has now been repaired, but b.final legitimately
    # contains bytes read from the earlier retained common.side. Stock keeps
    # that consumer when a later source edit produces identical upstream bytes.
    # Clearing demand evidence after the first ordinary build would lose it.
    pair.write('common.txt', 'common\n# equal normal rebuild\n')
    pair.check(*filters)
    pair.check(*filters)
    pair.write('a.final', 'manual before omitted output\n')
    pair.write('a.txt', 'empty\n')
    pair.check(KEEP, *filters)
    assert not (pair.native / 'lib/a.final').exists()
    pair.write('a.txt', 'restored after omission\n')
    pair.check(KEEP, *filters)
    pair.write('a.final', 'manual deleted input\n')
    pair.delete('a.txt')
    pair.check(KEEP, *filters)
    assert not (pair.native / 'lib/a.final').exists()
    pair.check(KEEP, *filters)
    pair.check(*filters)
    pair.check(VERIFY, *filters)


def failure_and_interrupt(tmp, policy):
    pair = Pair(tmp, 'failure-' + policy[2:])
    pair.check()
    pair.write('b.final', 'manual output before failure or interruption\n')
    baseline = snapshot(pair.native)
    pair.write('a.txt', 'pending successful output\n')
    pair.write('common.txt', 'fail\n')
    result = execute(launcher(pair.native, flags=['--force-jit', policy]), pair.native)
    assert result[0] == 1, result
    assert snapshot(pair.native) == baseline, result
    # Stock may publish successful actions on failure; native's existing stronger
    # all-success boundary is intentional. Compare after recovery.
    reference_failure = execute([DART, 'run', 'build_runner', 'build', '--force-jit', policy], pair.stock)
    assert reference_failure[0] == result[0] == 1, (reference_failure, result)
    pair.write('common.txt', 'recovered\n')
    pair.check(policy, expected=1 if policy == VERIFY else 0)
    pair.check()
    pair.write('b.final', 'manual output before failure or interruption\n')
    baseline = snapshot(pair.native)
    pair.write('a.txt', 'interrupt input\n')
    marker = activity_path(pair.native)
    marker.unlink(missing_ok=True)
    environment = fixture_env(pair.native, {'BUILD_FILTER_DELAY_MS': '10000',
                                          'BUILD_FILTER_ACTIVITY_LOG': str(marker)})
    log = tmp / (policy[2:] + '-interrupt.log')
    with log.open('w') as stream:
        proc = subprocess.Popen(launcher(pair.native, flags=['--force-jit', policy]),
                                cwd=pair.native, env=environment, stdout=stream, stderr=stream,
                                start_new_session=True)
        try:
            deadline = time.monotonic() + 120
            while not marker.exists():
                assert proc.poll() is None, log.read_text()
                assert time.monotonic() < deadline, log.read_text()
                time.sleep(.05)
            proc.send_signal(signal.SIGINT)
            assert proc.wait(timeout=15) == 130, log.read_text()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
    assert snapshot(pair.native) == baseline, log.read_text()
    pair.check(policy, expected=1 if policy == VERIFY else 0)
    pair.check()


def routing(tmp):
    pair = Pair(tmp, 'routing')
    for flags in ([VERIFY, KEEP], ['--no-only-check'], ['--no-keep-modified-outputs'],
                  [VERIFY + '=true'], [KEEP + '=false'], [VERIFY, 'false']):
        before = snapshot(pair.native)
        result = execute(launcher(pair.native, flags=flags), pair.native)
        assert result[0] == 1 and snapshot(pair.native) == before, result
    for policy in (VERIFY, KEEP):
        for command in ('watch', 'prewarm'):
            result = execute(launcher(pair.native, command, [policy]), pair.native)
            assert result[0] == 1, result
        unsupported = Pair(tmp, 'optional-' + policy[2:])
        cfg = unsupported.native / 'build.yaml'
        cfg.write_text(cfg.read_text().replace('  seed:\n', '  seed:\n    is_optional: true\n'))
        before = snapshot(unsupported.native)
        result = execute(launcher(unsupported.native, flags=[policy]), unsupported.native)
        assert result[0] == 1 and 'outside the supported subset' in result[1], result
        assert snapshot(unsupported.native) == before
    pair.check(KEEP)
    before = snapshot(pair.native)
    for policy in (VERIFY, KEEP):
        result = execute(launcher(pair.native, flags=[policy, '--define=:seed=text=changed configuration']), pair.native)
        assert result[0] == 1 and 'configuration transitions' in result[1], result
        assert snapshot(pair.native) == before
    marker = pair.native / '.dart_tool/build_runner_accelerator/stock-output-policy-state'
    marker.write_text('Legacy stock owns output-policy history.\n')
    manifest = marker.parent / 'builder-manifest.json'
    stamp = manifest.read_bytes(), manifest.stat().st_mtime_ns
    for entry in (launcher(pair.native), [str(NATIVE), 'build', '--root', str(pair.native)]):
        result = execute(entry, pair.native)
        assert result[0] == 1 and 'stock output-policy history' in result[1], result
        assert 'reset both build states' in result[1], result
        assert snapshot(pair.native) == before and marker.exists()
        assert (manifest.read_bytes(), manifest.stat().st_mtime_ns) == stamp
    print('output-policies: PASS unsupported policies/transitions and legacy history', flush=True)


def retained_api_cases(tmp):
    # Native cannot fabricate stock's logical MD5 or resolver cache equivalence
    # for retained manual bytes. Even a caught exception must abort publication.
    for api, cache in (('digest_common', False), ('digest_common', True), ('resolver_api', False)):
        pair = Pair(tmp, f'api-{api}-{cache}', cache)
        flags = [f'--define=:finish={api}=true', '--define=:finish=catch_retained_api=true']
        pair.check(KEEP, *flags)
        for root in pair.roots:
            bases = [root]
            if cache:
                tree = 'build/generated' if root == pair.stock else 'build_runner_accelerator/cache'
                bases = [root / f'.dart_tool/{tree}/build_filter_app']
            for base in bases:
                (base / 'lib/common.side').write_text('manual retained side\n')
        pair.write('b.txt', 'retained-api changed input\n')
        before = snapshot(pair.native)
        result = execute(launcher(pair.native, flags=['--force-jit', KEEP, *flags]), pair.native)
        assert result[0] == 1 and 'digest/resolver APIs' in result[1], result
        # The fixture catches the API exception and writes a different output;
        # the latched unsupported result must still discard that output.
        assert snapshot(pair.native) == before, result
        assert not (pair.native / '.dart_tool/build_runner_accelerator/stock-output-policy-state').exists()
        assert not (pair.native / '.dart_tool/build/asset_graph.json').exists()
        print(f'output-policies: PASS retained API rejection {api} cache={cache}', flush=True)


def modes(tmp):
    pair = Pair(tmp, 'native-aot')
    pair.check(VERIFY, expected=1, compile_flag='--force-aot')
    pair.check(KEEP, compile_flag='--force-aot')
    pair.check(VERIFY, VERIFY, compile_flag='--force-aot')
    pair.write('a.txt', 'jit policy input\n')
    pair.check(KEEP, compile_flag='--force-jit')
    pair.write('b.txt', 'aot policy input\n')
    pair.check(VERIFY, expected=1, compile_flag='--force-aot')
    pair.check(compile_flag='--force-jit')
    # Even after overwrite repairs files, retained native graph history cannot
    # enter the resident watch evaluator. Reject before any manifest refresh.
    before = snapshot(pair.native)
    manifest = pair.native / '.dart_tool/build_runner_accelerator/builder-manifest.json'
    manifest_stamp = manifest.read_bytes(), manifest.stat().st_mtime_ns
    for entry in (launcher(pair.native, 'watch'),
                  [str(NATIVE), 'watch', '--root', str(pair.native)]):
        result = execute(entry, pair.native)
        assert result[0] == 1 and 'watch after retained output state' in result[1], result
        assert snapshot(pair.native) == before
        assert (manifest.read_bytes(), manifest.stat().st_mtime_ns) == manifest_stamp


def main():
    matrix = lifecycle_matrix(os.environ.get('OUTPUT_POLICY_COVERAGE', 'full'))
    with tempfile.TemporaryDirectory(prefix='output-policies-') as directory:
        tmp = Path(directory)
        ENV.setdefault('BUILD_RUNNER_ACCELERATOR_CACHE', str(tmp / 'accelerator-cache'))
        groups = {
            'routing': lambda: routing(tmp),
            'modes': lambda: modes(tmp),
            'api': lambda: retained_api_cases(tmp),
            'source': lambda: run_lifecycle_matrix(tmp, matrix, False),
            'cache': lambda: run_lifecycle_matrix(tmp, matrix, True),
            'failure': lambda: [failure_and_interrupt(tmp, policy) for policy in (VERIFY, KEEP)],
        }
        selected = os.environ.get('OUTPUT_POLICY_CASE_GROUP', 'all')
        if selected != 'all' and selected not in groups:
            raise ValueError(f'unknown output-policy group: {selected}')
        for name, run_group in groups.items():
            if selected in ('all', name):
                print(f'output-policies: start group={name}', flush=True)
                run_group()
                print(f'output-policies: PASS group={name}', flush=True)
    print('output-policies stock/native comparisons passed', flush=True)


def run_lifecycle_matrix(tmp, matrix, cache):
    for selected_cache, filtered, policy in matrix:
        if selected_cache == cache:
            print(f'output-policies: lifecycle cache={cache} filtered={filtered} policy={policy}', flush=True)
            run = verify_cases if policy == 'verify' else keep_cases
            run(tmp, cache, ('--build-filter=lib/*.final',) if filtered else ())


if __name__ == '__main__':
    main()
