#!/usr/bin/env python3
"""Prepare a complete integration Pub download set without running builders."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from correctness_dependency_window import CASES, dependency_pubspec

REPO = Path(__file__).resolve().parents[1]
# The producer resolves every package before its own checks start, and the
# resolutions are independent downloads against one Pub cache, so run them
# with the same four-way bound the workflow uses for parallel lanes.
MAX_PARALLEL_RESOLUTIONS = 4
# These jobs deliberately resolve newer/older dependencies in their own scopes.
# Adding their unlocked latest solution to the integration set would also
# change which versions fresh offline integration fixtures select.
SEPARATE_RESOLUTION_FIXTURES = frozenset({'sdk_compat_app', 'shared_parts_app'})


def tracked_specs(repo):
    """Include integration/nested packages, excluding the separately resolved SDK jobs."""
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '--', 'fixtures/**/pubspec.yaml'], cwd=repo)
    return sorted((Path(name.decode()) for name in names.split(b'\0')
                   if name and Path(name.decode()).parts[1] not in SEPARATE_RESOLUTION_FIXTURES),
                  key=lambda path: (len(path.parts), path.as_posix()))


def prepare(repo, dart, pub_cache, *, offline=False):
    """Publish the receipt only after every declared resolution has succeeded."""
    pub_cache.mkdir(parents=True, exist_ok=True)
    receipt = pub_cache / 'ci-integration-prepared.json'
    receipt.unlink(missing_ok=True)
    env = {**os.environ, 'PUB_CACHE': str(pub_cache), 'DART_SUPPRESS_ANALYTICS': 'true'}
    with tempfile.TemporaryDirectory(prefix='ci-pub-') as directory:
        root = Path(directory)
        shutil.copy2(repo / 'pubspec.yaml', root / 'pubspec.yaml')
        shutil.copy2(repo / 'pubspec.lock', root / 'pubspec.lock')
        # Relative fixture path dependencies see the same repository layout.
        shutil.copytree(repo / 'fixtures', root / 'fixtures',
                        ignore=shutil.ignore_patterns('.dart_tool', '.cache'))

        def resolve(task):
            package, label = task
            started = time.monotonic()
            command = [dart, '--suppress-analytics', 'pub', 'get']
            if (package / 'pubspec.lock').is_file():
                command.append('--enforce-lockfile')
            if offline:
                command.append('--offline')
            print(f'ci-pub: start {label}', flush=True)
            subprocess.run(command, cwd=package, env=env, check=True, timeout=180)
            print(f'ci-pub: PASS {label} elapsed={time.monotonic() - started:.1f}s', flush=True)
            return label

        tasks = [(root, 'root')]
        tasks.extend((root / spec.parent, str(spec.parent))
                     for spec in tracked_specs(repo))
        resolutions = sorted({(runner, analyzer)
                              for native, analyzer, stock in CASES
                              for runner in (native, stock)})
        for runner, analyzer in resolutions:
            package = root / f'window-{runner}-{analyzer}'
            package.mkdir()
            (package / 'pubspec.yaml').write_text(dependency_pubspec(repo, runner, analyzer))
            tasks.append((package, package.name))
        with ThreadPoolExecutor(max_workers=MAX_PARALLEL_RESOLUTIONS) as executor:
            prepared = sorted(executor.map(resolve, tasks))
    receipt.write_text(json.dumps({'prepared': prepared}, indent=2) + '\n')
    print(f'ci-pub: complete resolutions={len(prepared)} receipt={receipt}', flush=True)


def main():
    """Use the caller's SDK and Pub directory; offline mode verifies completeness."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default=os.environ.get('DART_BIN', 'dart'))
    parser.add_argument('--pub-cache', type=Path, default=Path(os.environ.get('PUB_CACHE', REPO / '.pub-cache')))
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    prepare(REPO, args.dart, args.pub_cache.resolve(), offline=args.offline)


if __name__ == '__main__':
    main()
