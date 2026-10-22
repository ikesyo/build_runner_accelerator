#!/usr/bin/env python3
"""Package the built frontend identically in CI and releases."""
import argparse
import json
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path


def package(repo, binary, target, output, evidence=None):
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
        facts = {'os': platform.platform(), 'machine': platform.machine(),
                 'runner_image': os_image()}
        commands = [['ldd', '--version'], ['readelf', '--version-info', str(binary)]] if target.startswith('linux-') else (
            [['sw_vers'], ['otool', '-l', str(binary)]] if target.startswith('macos-') else [])
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            (evidence / (command[0] + '.log')).write_text(result.stdout + result.stderr)
            if command[0] == 'readelf':
                symbols = sorted(set(re.findall(r'GLIBC_([0-9.]+)', result.stdout)),
                                 key=lambda value: tuple(map(int, value.split('.'))))
                facts['required_glibc_symbols'] = symbols
                facts['highest_glibc_symbol'] = symbols[-1] if symbols else None
        (evidence / 'build-platform.json').write_text(json.dumps(facts, indent=2) + '\n')
    output.mkdir(parents=True, exist_ok=True)
    version = next(line.split(':', 1)[1].strip() for line in
                   (repo / 'pubspec.yaml').read_text().splitlines() if line.startswith('version:'))
    with tempfile.TemporaryDirectory() as temporary:
        staging = Path(temporary) / target
        staging.mkdir()
        shutil.copy2(binary, staging / binary.name)
        (staging / 'VERSION').write_text(version + '\n')
        (staging / 'SOURCE_COMMIT').write_bytes(subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=repo))
        for name in ('README.md', 'LICENSE'):
            shutil.copy2(repo / name, staging / name)
        suffix = '.zip' if target.startswith('windows-') else '.tar.gz'
        archive = output / f'build_runner_accelerator-{target}{suffix}'
        if suffix == '.zip':
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as stream:
                for path in sorted(staging.iterdir()):
                    stream.write(path, f'{target}/{path.name}')
        else:
            with tarfile.open(archive, 'w:gz') as stream:
                stream.add(staging, arcname=target)
        return archive


def os_image():
    import os
    return {name: os.environ.get(name) for name in ('ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH')}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    print(package(Path(__file__).resolve().parents[1], args.binary,
                  args.target, args.output, args.evidence))
