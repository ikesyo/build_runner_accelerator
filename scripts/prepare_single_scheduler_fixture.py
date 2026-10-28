#!/usr/bin/env python3
"""Convert a fresh scheduler fixture copy into a standalone package."""
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
if len(sys.argv) == 3:
    shutil.copytree(Path(sys.argv[2]), root, ignore=shutil.ignore_patterns('.dart_tool', '.cache'))
assert not (root / '.dart_tool').exists(), 'Convert before pub get or building'
shutil.move(root / 'a/lib', root / 'lib')
shutil.move(root / 'a/build.yaml', root / 'build.yaml')
pubspec = (root / 'pubspec.yaml').read_text()
pubspec = pubspec.replace('name: schedule_root', 'name: schedule_a')
pubspec = pubspec.replace('workspace: [a, b, c, gen]\n', '')
pubspec = pubspec.replace('dev_dependencies:', 'dependencies:\n  schedule_gen:\n    path: gen\ndev_dependencies:')
(root / 'pubspec.yaml').write_text(pubspec)
gen = root / 'gen/pubspec.yaml'
gen.write_text(gen.read_text().replace('resolution: workspace\n', ''))
for name in ['a', 'b', 'c', 'helper']:
    shutil.rmtree(root / name)
