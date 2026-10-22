#!/usr/bin/env python3
"""Run the pinned FVM build/no-op/model-edit/paired-watch comparison.

Prepare two separate worktrees using docs/probes/fvm/README.md first. Logs and
hash evidence stay outside both watched trees. No output bytes are normalized.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from compare_web_compilers import stock_outputs
from web_compilers_graph import native_graph

COMMIT = '6f4c0a2528ef2a293e5f84d216a37be30411b3a5'
MODEL = 'lib/src/models/log_level_model.dart'
MAPPER = MODEL.replace('.dart', '.mapper.dart')


def compare(stock, native):
    """Compare logical published sets, raw bytes, and all physical lib files."""
    expected = stock_outputs(stock)
    actions = native_graph(native)[0]
    actual = {output for action in actions.values() for output in action['outputs']}
    assert set(expected) == actual, ('published set', set(expected) ^ actual)
    assert len(expected) == 13, expected
    evidence = {}
    for asset, cached in expected.items():
        assert asset.startswith('fvm|') and not cached, asset
        path = asset.split('|', 1)[1]
        data = (stock / path).read_bytes()
        assert data == (native / path).read_bytes(), ('raw bytes', path)
        evidence[path] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    def files(root):
        """Include every physical lib file, including undeclared extra outputs."""
        return {str(p.relative_to(root)): p.read_bytes()
                for p in (root / 'lib').rglob('*') if p.is_file()}
    assert files(stock) == files(native), 'physical lib set/bytes differ'
    cache = native / '.dart_tool/build_runner_accelerator/cache'
    assert not any(p.is_file() for p in cache.rglob('*')), 'unexpected native cache output'
    return evidence


def stop(process):
    """Stop a whole watch process group, including worker subprocesses."""
    try:
        os.killpg(process.pid, signal.SIGINT)
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    except ProcessLookupError:
        pass


def main():
    """Run sequential builds, then a bounded paired watch using the same edit."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stock', type=Path)
    parser.add_argument('native', type=Path)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    stock, native, evidence = (p.resolve() for p in (args.stock, args.native, args.evidence))
    assert stock != native
    assert not any(evidence.is_relative_to(p) for p in (stock, native))
    evidence.mkdir(parents=True, exist_ok=True)
    for root in (stock, native):
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        assert head == COMMIT, head
    for path in ('pubspec.yaml', 'pubspec.lock', 'build.yaml', MODEL):
        assert (stock / path).read_bytes() == (native / path).read_bytes(), path
    dart = os.environ['DART_BIN']
    binary = os.environ['BUILD_RUNNER_ACCELERATOR_BIN']
    environment = dict(os.environ, BUILD_MAX_WORKERS_PER_TASK='1')
    environment.pop('HOME', None)
    report = {'commit': COMMIT, 'phases': {}}

    def command(root, phase, engine, watch=False):
        """Keep command lines, exit statuses and elapsed times with each log."""
        cmd = ([dart, 'run', 'build_runner', 'watch' if watch else 'build']
               if engine == 'stock' else
               [binary, 'watch' if watch else 'build', '--root', str(root),
                '--dart', dart, '--jobs', '1'])
        if watch and engine == 'native':
            cmd += ['--interval-ms', '200']
        log = evidence / f'{phase}.{engine}.log'
        stream = log.open('w')
        started = time.monotonic()
        process = subprocess.Popen(cmd, cwd=root, env=environment, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        stream.close()
        if watch:
            return process, log
        try:
            code = process.wait(timeout=300)
        except subprocess.TimeoutExpired:
            stop(process)
            raise
        report.setdefault('commands', []).append(
            dict(command=cmd, root=str(root), exit=code, seconds=time.monotonic()-started))
        assert code == 0, (cmd, code, log)

    def checkpoint(name):
        """Persist the complete raw output digest inventory at every checkpoint."""
        report['phases'][name] = compare(stock, native)
        (evidence / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'fvm: {name}: complete set and raw bytes match', flush=True)

    for phase in ('initial', 'noop', 'model-change'):
        if phase == 'model-change':
            for root in (stock, native):
                model = root / MODEL
                text = model.read_text()
                assert '  quiet,' in text and '  probe,' not in text
                model.write_text(text.replace('  quiet,', '  probe,\n  quiet,'))
        command(stock, phase, 'stock')
        command(native, phase, 'native')
        checkpoint(phase)
    assert report['phases']['initial'] == report['phases']['noop']
    assert report['phases']['initial'][MAPPER] != report['phases']['model-change'][MAPPER]
    assert 'No work to do' in (evidence / 'noop.native.log').read_text()
    assert 'wrote 0 outputs' in (evidence / 'noop.stock.log').read_text()

    environment['BUILD_RUNNER_ACCELERATOR_METRICS'] = '1'
    processes = []
    def wait_for(predicate):
        """Require convergence and live watchers within a fixed observation window."""
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            assert all(p.poll() is None for p in processes), 'watch exited'
            if predicate():
                return
            time.sleep(.2)
        raise TimeoutError('paired watch did not converge; inspect evidence logs')

    try:
        process, stock_log = command(stock, 'watch', 'stock', True)
        processes.append(process)
        stock_count = lambda: stock_log.read_text().count('Built with build_runner/aot in')
        wait_for(lambda: stock_count() > 0)
        process, native_log = command(native, 'watch', 'native', True)
        processes.append(process)
        native_count = lambda: len(re.findall(r'Rust watch cycle metrics: .* success=true', native_log.read_text()))
        wait_for(lambda: native_count() > 0 and 'native filesystem events' in native_log.read_text())
        checkpoint('watch-initial')
        before = stock_count(), native_count()
        # Replay the identical model change in watch by reverting to the original
        # model, checking convergence, then adding the same enum value again.
        for present in (False, True):
            for root in (stock, native):
                model = root / MODEL
                text = model.read_text().replace('  probe,\n', '')
                model.write_text(text.replace('  quiet,', '  probe,\n  quiet,') if present else text)
            wait_for(lambda: stock_count() > before[0] and native_count() > before[1])
            checkpoint('watch-change' if present else 'watch-revert')
            before = stock_count(), native_count()
        assert report['phases']['watch-revert'] == report['phases']['initial']
        assert report['phases']['watch-change'] == report['phases']['model-change']
    finally:
        for process in reversed(processes):
            stop(process)


if __name__ == '__main__':
    main()
