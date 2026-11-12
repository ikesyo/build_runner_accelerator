#!/usr/bin/env python3
"""Classify a pull request's changed paths for change-based CI selection.

Reads newline-separated paths on stdin and prints ``level=full`` or
``level=light``. ``light`` means the change cannot affect the integration or
native jobs, so those may be skipped; the package jobs always run. Anything
unrecognized, empty, or malformed classifies as ``full``: selection must fail
safe toward running everything, because a wrong ``light`` silently weakens
the gate while a wrong ``full`` only costs runner time.

Light-safe classes (each verified against the workflow layout):
- Documentation and repository meta that no job executes.
- test/**: the Dart package tests. Integration fixtures consume the package's
  lib/ through path dependencies, never its tests, and the native jobs build
  only rust/.
- CI helper tests and the checkers themselves: they run inside the package
  jobs, which light mode keeps. compiled_cache_key.py is excluded because the
  setup action uses it to key the integration compiled cache.
"""

import sys

LIGHT_PREFIXES = (
    'docs/',
    'test/',
    '.github/scripts/test_',
)

LIGHT_FILES = {
    'renovate.json5',
}

LIGHT_SUFFIXES = (
    '.md',
)

FULL_FILES = {
    '.github/scripts/compiled_cache_key.py',
    # The classifier runs from the PR's own tree, so a change to it must never
    # be allowed to classify its own pull request as light.
    '.github/scripts/classify_changes.py',
}


def is_light(path):
    if path in FULL_FILES:
        return False
    if path in LIGHT_FILES:
        return True
    if path.startswith(LIGHT_PREFIXES):
        return True
    if path.startswith('.github/scripts/') and path.endswith('.py'):
        return True
    return path.endswith(LIGHT_SUFFIXES)


def classify(paths):
    paths = [path.strip() for path in paths if path.strip()]
    if not paths:
        return 'full'
    return 'light' if all(is_light(path) for path in paths) else 'full'


def main():
    try:
        level = classify(sys.stdin.read().splitlines())
    except Exception:
        level = 'full'
    print(f'level={level}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
