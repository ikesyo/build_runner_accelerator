#!/usr/bin/env python3
"""Bind persisted code/Analyzer caches to SDK contents and absolute locations."""
import argparse
import hashlib
from pathlib import Path


COMPILER_INPUTS = (
    'version', 'revision', 'bin/dart', 'bin/dartaotruntime',
    'bin/utils/gen_snapshot', 'bin/snapshots/dartdev_aot.dart.snapshot',
    'bin/snapshots/gen_kernel_aot.dart.snapshot',
    'bin/snapshots/kernel-service.dart.snapshot',
)


def fingerprint(sdk, workspace, pub_cache):
    """Ignore mtimes, and invalidate even same-version SDK library replacements."""
    digest = hashlib.sha256()
    for path in (sdk, workspace, pub_cache):
        digest.update(str(path.resolve()).encode() + b'\0')
    paths = [sdk / name for name in COMPILER_INPUTS]
    paths.extend(sorted(path for path in (sdk / 'lib').rglob('*') if path.is_file()))
    for path in paths:
        digest.update(str(path.relative_to(sdk)).encode() + b'\0')
        content = hashlib.sha256()
        with path.open('rb') as source:
            while chunk := source.read(1024 * 1024):
                content.update(chunk)
        digest.update(content.digest())
    return digest.hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--pub-cache', type=Path, required=True)
    args = parser.parse_args()
    print(fingerprint(args.sdk.resolve(), args.workspace.resolve(), args.pub_cache.resolve()))
