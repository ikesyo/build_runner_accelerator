#!/usr/bin/env python3
"""Compare exact production scanner bodies with the shared opt-in benchmark.

Requires an already-built release memchr rlib. Builds small standalone kernels
to avoid recompiling the frontend's entire test suite for each search strategy.
Never use the native variant as a distribution binary.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess


def scanner(source):
    start = source.index('pub(super) fn declares_part_directive')
    end = source.index('pub(super) fn empty_build_result', start)
    return source[start:end].split('#[cfg(test)]')[0].replace('pub(super) fn', 'fn')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, help='Git revision to compare')
    parser.add_argument('--memchr-rlib', required=True, type=Path)
    parser.add_argument('--results', required=True, type=Path)
    parser.add_argument('--rustc', default=os.environ.get('RUSTC'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    rustc = args.rustc or shutil.which('rustc') or str(root / '.toolchains/cargo/bin/rustc')
    rlib = args.memchr_rlib.resolve(strict=True)
    results = args.results.resolve()
    results.mkdir(parents=True)
    relative = 'rust/src/build/part_directive.rs'
    baseline = scanner(subprocess.check_output(
        ['git', 'show', f'{args.baseline}:{relative}'], cwd=root, text=True))
    candidate = scanner((root / relative).read_text())
    bench = (root / 'rust/src/build/part_directive_bench.rs').read_text()
    bench = bench.split('\n#[test]\nfn ')[0]
    bench = bench.replace('use super::declares_part_directive;', '')
    bench = bench.replace('#[test]\n', '').replace('//!', '//')
    bench = re.sub(r'#\[ignore = .*\]\n', '', bench)
    bench = bench.replace('fn part_scanner_benchmark()', 'fn main()')
    bench = re.sub(r'include_str!\("([^"]+)"\)', lambda match:
                   'include_str!("' + (root / 'rust/src/build' / match[1]).resolve().as_posix() + '")', bench)
    needle = ('while i + 4 <= len {\n'
              '        if &bytes[i..i + 4] != b"part"\n'
              '            || (i > 0 && is_ident_byte(bytes[i - 1]))')
    assert needle in baseline, 'baseline loop changed; inspect before benchmarking'
    memmem = baseline.replace(needle,
        'while let Some(offset) = memchr::memmem::find(&bytes[i..], b"part") {\n'
        '        i += offset;\n'
        '        if (i > 0 && is_ident_byte(bytes[i - 1]))')
    for name, source in [('baseline', baseline), ('native', baseline),
                         ('proposal', candidate), ('memmem', memmem)]:
        source_path = results / f'{name}.rs'
        if 'OnceLock<' in source:
            source = 'use std::sync::OnceLock;\n' + source
        source_path.write_text(source + bench)
        binary = results / (name + ('.exe' if os.name == 'nt' else ''))
        command = [rustc, '--edition', '2024', '-O', str(source_path),
                   '--extern', f'memchr={rlib}', '-o', str(binary)]
        if name == 'native':
            command += ['-C', 'target-cpu=native']
        subprocess.run(command, check=True, cwd=root)
    # All compilation finishes before any timing starts.
    for name in ['baseline', 'native', 'proposal', 'memmem']:
        binary = results / (name + ('.exe' if os.name == 'nt' else ''))
        with (results / f'{name}.csv').open('w') as output:
            subprocess.run([str(binary)], check=True, stderr=output, cwd=root)
    print(f'part scanner measurements: {results}')


if __name__ == '__main__':
    main()
