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
from correctness_cli import DART, ENV, launcher

VERIFY = '--only-check'
KEEP = '--keep-modified-outputs'


def snapshot(root):
    """Source outputs, intermediate bytes and incremental graph, excluding setup caches."""
    result = outputs(root)
    for relative in ('.dart_tool/build/asset_graph.json',
                     '.dart_tool/build_runner_accelerator/graph-v3.bin'):
        file = root / relative
        if file.exists():
            result[relative] = file.read_bytes()
    # Equal bytes alone would miss a forbidden rewrite of a matching output
    # or graph. Track inode/mtime as well; reads may update atime legitimately.
    result['__metadata__'] = {
        str(file.relative_to(root)): (file.stat().st_ino, file.stat().st_mtime_ns)
        for file in root.rglob('*')
        if file.is_file() and (file.suffix in ('.mid', '.side', '.final', '.ignored', '.post')
                               or file.name in ('asset_graph.json', 'graph-v3.bin'))
    }
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

    def check(self, *flags, expected=0, mode='rust', compile_flag='--force-jit', jobs=1):
        before = [snapshot(root) for root in self.roots]
        reference = execute([DART, 'run', 'build_runner', 'build', compile_flag, *flags], self.stock)
        args = launcher(self.native, mode, flags=[compile_flag, *flags])
        args[args.index('--jobs=1')] = f'--jobs={jobs}'
        actual = execute(args, self.native)
        assert reference[0] == actual[0] == expected, (flags, reference, actual)
        assert outputs(self.stock) == outputs(self.native), (flags, outputs(self.stock), outputs(self.native), actual)
        if VERIFY in flags:
            assert before == [snapshot(root) for root in self.roots], (flags, 'verification wrote outputs/state')
            assert diagnostics(reference[1]) == diagnostics(actual[1]), (reference, actual)
        if expected == 0 and mode == 'rust':
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
        actual = execute(launcher(pair.native, 'rust', flags=['--force-jit', *filters]), pair.native)
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
    result = execute(launcher(pair.native, 'rust', flags=['--force-jit', policy]), pair.native)
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
        proc = subprocess.Popen(launcher(pair.native, 'rust', flags=['--force-jit', policy]),
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
    # Capturing the actual process argv checks both fallback boundaries without
    # depending on diagnostic wording or a downloadable native artifact.
    root = tmp / 'routing'
    prepare(root)
    capture = tmp / 'stock-argv.json'
    fake_dart = tmp / 'fake-dart'
    fake_dart.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                         f'open({str(capture)!r}, "w").write(json.dumps(sys.argv[1:]))\n'
                         'sys.exit(23)\n')
    fake_dart.chmod(0o755)
    for policy in (VERIFY, KEEP):
        for compile_flag in ('--force-jit', '--force-aot'):
            flags = [compile_flag, '-d', policy, policy, '--release',
                     '--define=:seed=text=--only-check', '--build-filter=lib/*.final']
            for command, mode, early in [('build', 'auto', False), ('watch', 'auto', True),
                                         ('build', 'dart', True)]:
                args = launcher(root, mode, command, flags)
                args[args.index('--dart') + 1] = str(fake_dart)
                env = fixture_env(root)
                if early:
                    env['BUILD_RUNNER_ACCELERATOR_BIN'] = '/bin/false'
                result = subprocess.run(args, cwd=root, env=env, capture_output=True, timeout=180)
                assert result.returncode == 23, result
                forwarded = json.loads(capture.read_text())
                assert forwarded[-(3 + len(flags)):] == ['run', 'build_runner', command, *flags], forwarded
                manifest = root / '.dart_tool/build_runner_accelerator/builder-manifest.json'
                assert not manifest.exists()
                # The fake stock process publishes no real history.
                (root / '.dart_tool/build_runner_accelerator/stock-output-policy-state').unlink(missing_ok=True)
            result = execute(launcher(root, 'rust', 'watch', [policy]), root)
            assert result[0] == 1 and not manifest.exists(), result
            result = execute(launcher(root, 'rust', 'prewarm', [policy]), root)
            assert result[0] == 1 and not manifest.exists(), result
    for flags in ([VERIFY, KEEP], ['--no-only-check'], ['--no-keep-modified-outputs'],
                  [VERIFY + '=true'], [KEEP + '=false'], [VERIFY, 'false']):
        reference = execute([DART, 'run', 'build_runner', 'build', *flags], root)
        if flags != [VERIFY, 'false']:
            assert reference[0] != 0, reference
        for mode in ('auto', 'dart'):
            actual = execute(launcher(root, mode, flags=flags), root)
            assert actual[0] == reference[0], (flags, reference, actual)
        assert execute(launcher(root, 'rust', flags=flags), root)[0] == 1
    # A supported CLI can still require fallback after manifest generation.
    for policy in (VERIFY, KEEP):
        pair = Pair(tmp, 'late-' + policy[2:])
        for workspace in pair.roots:
            config = workspace / 'build.yaml'
            config.write_text(config.read_text().replace('  seed:\n', '  seed:\n    is_optional: true\n'))
        reference, actual = pair.check(policy, expected=1 if policy == VERIFY else 0, mode='auto')
        assert 'outside the supported subset' in actual[1], actual
        assert (pair.native / '.dart_tool/build_runner_accelerator/builder-manifest.json').exists()
        before = snapshot(pair.native)
        result = execute(launcher(pair.native, 'rust', flags=[policy]), pair.native)
        assert result[0] == 1 and snapshot(pair.native) == before, result
    pair = Pair(tmp, 'policy-config-transition')
    pair.check(KEEP)
    before = snapshot(pair.native)
    _, result = pair.check(VERIFY, '--define=:seed=text=changed configuration', mode='auto')
    assert 'configuration transitions' in result[1], result
    assert not (pair.native / '.dart_tool/build_runner_accelerator/stock-output-policy-state').exists()
    pair.check(KEEP)  # read-only stock fallback must not pin subsequent native work
    before = snapshot(pair.native)
    changed = [KEEP, '--define=:seed=text=changed configuration']
    result = execute(launcher(pair.native, 'rust', flags=changed), pair.native)
    assert result[0] == 1 and 'configuration transitions' in result[1], result
    assert snapshot(pair.native) == before
    _, result = pair.check(*changed, mode='auto')
    assert 'configuration transitions' in result[1], result
    assert (pair.native / '.dart_tool/build_runner_accelerator/stock-output-policy-state').exists()
    print('output-policies: PASS early/late fallback, dart, strict errors, invalid/conflicting flags', flush=True)


def stock_owned_outputs(root):
    result = {str(file.relative_to(root)): file.read_bytes()
              for file in (root / 'lib').rglob('*')
              if file.is_file() and file.suffix in ('.mid', '.side', '.final', '.ignored')}
    cache = root / '.dart_tool/build/generated'
    if cache.exists():
        result.update({'stock-cache/' + str(file.relative_to(cache)): file.read_bytes()
                       for file in cache.rglob('*') if file.is_file()})
    return result


def private_cache(root):
    cache = root / '.dart_tool/build_runner_accelerator/cache'
    return {str(file.relative_to(cache)): (file.read_bytes(), file.stat().st_mtime_ns)
            for file in cache.rglob('*') if file.is_file()} if cache.exists() else {}


def retained_api_cases(tmp, cases=(('digest_common', False, True),
                                   ('digest_common', True, True),
                                   ('resolver_api', False, True),
                                   ('digest_common', False, False))):
    # Stock exposes the previous digest alongside retained manual bytes. The
    # native byte adapter cannot fabricate that MD5 or resolver state; reject
    # and retry the entire stock invocation before publishing native results.
    for api, cache, primed in cases:
        pair = Pair(tmp, f'api-{api}-{cache}-{primed}', cache)
        flags = [f'--define=:finish={api}=true', '--define=:finish=catch_retained_api=true']
        pair.check(KEEP, *flags)  # clean/unmodified APIs are native-compatible
        if primed:
            # Exercise stock's warm keep semantics with its independent graph.
            code, log = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *flags], pair.native)
            assert code == 0, log
        else:
            # Without a stock graph, fallback follows stock's cold-build rules;
            # it cannot import native logical digest history.
            shutil.rmtree(pair.stock / '.dart_tool/build')
        for root in pair.roots:
            bases = [root]
            if cache:
                bases = [root / '.dart_tool/build/generated/build_filter_app']
                if root == pair.native:
                    bases.append(root / '.dart_tool/build_runner_accelerator/cache/build_filter_app')
            for base in bases:
                (base / 'lib/common.side').write_text('manual retained side\n')
        pair.write('b.txt', 'retained-api changed input\n')
        before = snapshot(pair.native)
        result = execute(launcher(pair.native, 'rust', flags=['--force-jit', KEEP, *flags]), pair.native)
        assert result[0] == 1 and 'digest/resolver APIs' in result[1], result
        # The fixture catches the API exception and writes a different output;
        # the latched unsupported result must still discard that output.
        assert snapshot(pair.native) == before, result
        graph = pair.native / '.dart_tool/build_runner_accelerator/graph-v3.bin'
        native_graph = graph.read_bytes(), graph.stat().st_mtime_ns
        native_cache = private_cache(pair.native)
        reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', KEEP, *flags], pair.stock)
        actual = execute(launcher(pair.native, 'auto', flags=['--force-jit', KEEP, *flags]), pair.native)
        assert reference[0] == actual[0] == 0, (reference, actual)
        assert 'native output policy unsupported:' in actual[1], actual
        assert stock_owned_outputs(pair.stock) == stock_owned_outputs(pair.native), (reference, actual)
        assert (graph.read_bytes(), graph.stat().st_mtime_ns) == native_graph
        assert private_cache(pair.native) == native_cache
        marker = pair.native / '.dart_tool/build_runner_accelerator/stock-output-policy-state'
        assert marker.exists(), actual
        # Normal/verify after fallback must use the stock digest history,
        # rather than silently switching to the older private graph. An invalid
        # native binary proves that this routing happens before acquisition.
        for policy_flags in ([], [VERIFY], [KEEP]):
            reference = execute([DART, 'run', 'build_runner', 'build', '--force-jit', *policy_flags, *flags], pair.stock)
            args = launcher(pair.native, 'auto', flags=['--force-jit', *policy_flags, *flags])
            actual = execute(args, pair.native, {'BUILD_RUNNER_ACCELERATOR_BIN': '/bin/false'})
            assert reference[0] == actual[0] == 0, (reference, actual)
            assert 'stock output-policy state' in actual[1], actual
            assert stock_owned_outputs(pair.stock) == stock_owned_outputs(pair.native), (reference, actual)
            assert (graph.read_bytes(), graph.stat().st_mtime_ns) == native_graph
            assert private_cache(pair.native) == native_cache
        result = execute(launcher(pair.native, 'rust', flags=flags), pair.native,
                         {'BUILD_RUNNER_ACCELERATOR_BIN': '/bin/false'})
        assert result[0] == 1 and 'stock output-policy state' in result[1], result
        print(f'output-policies: PASS retained API fallback {api} cache={cache} primed={primed}', flush=True)


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
    # enter the resident watch evaluator. Route before any manifest refresh.
    before = snapshot(pair.native)
    manifest = pair.native / '.dart_tool/build_runner_accelerator/builder-manifest.json'
    manifest_stamp = manifest.read_bytes(), manifest.stat().st_mtime_ns
    result = execute(launcher(pair.native, 'rust', 'watch'), pair.native)
    assert result[0] == 1 and 'watch after retained output state' in result[1], result
    assert snapshot(pair.native) == before
    capture = tmp / 'retained-watch-argv.json'
    fake = tmp / 'retained-watch-dart'
    fake.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                    f'open({str(capture)!r}, "w").write(json.dumps(sys.argv[1:]))\n'
                    'sys.exit(23)\n')
    fake.chmod(0o755)
    args = launcher(pair.native, 'auto', 'watch', ['--force-jit', '--build-filter=lib/*.final'])
    args[args.index('--dart') + 1] = str(fake)
    result = execute(args, pair.native, {'BUILD_RUNNER_ACCELERATOR_BIN': '/bin/false'})
    assert result[0] == 23 and 'watch after retained output state' in result[1], result
    assert json.loads(capture.read_text())[-5:] == ['run', 'build_runner', 'watch', '--force-jit',
                                                  '--build-filter=lib/*.final']
    assert snapshot(pair.native) == before
    assert (manifest.read_bytes(), manifest.stat().st_mtime_ns) == manifest_stamp
    for mode in ('auto', 'dart'):
        pair = Pair(tmp, 'mode-' + mode)
        pair.check(VERIFY, expected=1, mode=mode)
        _, actual = pair.check(KEEP, mode=mode)
        if mode == 'auto':
            assert '(Rust frontend)' in actual[1], actual
        pair.write('a.final', 'manual mode edit\n')
        pair.check(KEEP, mode=mode)
        pair.check(VERIFY, expected=1, mode=mode)
        pair.check(mode=mode)
        pair.check(VERIFY, mode=mode)
        if mode == 'auto':
            # Stock overwrite after native keep must claim ownership too. It
            # cannot publish a stock graph then resume an older native graph.
            pair.check(mode='dart')
            result = execute(launcher(pair.native, 'auto', flags=[VERIFY]), pair.native,
                             {'BUILD_RUNNER_ACCELERATOR_BIN': '/bin/false'})
            assert result[0] == 0 and 'stock output-policy state' in result[1], result
        if mode == 'dart':
            assert not (pair.native / '.dart_tool/build_runner_accelerator/graph-v3.bin').exists()
            marker = pair.native / '.dart_tool/build_runner_accelerator/stock-output-policy-state'
            assert marker.exists()
            result = execute(launcher(pair.native, 'auto', flags=[VERIFY]), pair.native,
                             {'BUILD_RUNNER_ACCELERATOR_BIN': '/bin/false'})
            assert result[0] == 0 and 'stock output-policy state' in result[1], result
    root = tmp / 'invalid-keep-no-history'
    prepare(root)
    marker = root / '.dart_tool/build_runner_accelerator/stock-output-policy-state'
    for flags in ([KEEP, VERIFY], [KEEP, '--help']):
        result = execute(launcher(root, 'dart', flags=flags), root)
        assert result[0] in (0, 64) and not marker.exists(), result



def main():
    with tempfile.TemporaryDirectory(prefix='output-policies-') as directory:
        tmp = Path(directory)
        ENV.setdefault('BUILD_RUNNER_ACCELERATOR_CACHE', str(tmp / 'accelerator-cache'))
        groups = {
            'routing': lambda: routing(tmp),
            'modes': lambda: modes(tmp),
            'api': lambda: retained_api_cases(tmp),
            'source': lambda: [(verify_cases(tmp, False, filters), keep_cases(tmp, False, filters))
                               for filters in ((), ('--build-filter=lib/*.final',))],
            'cache': lambda: [(verify_cases(tmp, True, filters), keep_cases(tmp, True, filters))
                              for filters in ((), ('--build-filter=lib/*.final',))],
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


if __name__ == '__main__':
    main()
