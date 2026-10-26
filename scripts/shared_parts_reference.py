"""Isolate the correction for build_runner 2.17.1's partial-content cache.

Only the stock test compiler is redirected. The application lockfile, native
package configuration, Pub cache and accelerator runtime are never patched.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
from urllib.parse import unquote, urljoin, urlparse


def prepare_stock_reference(root: Path, results: Path):
    config_path = root / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text())
    runner = next(p for p in config['packages'] if p['name'] == 'build_runner')
    original_root = Path(unquote(urlparse(urljoin(config_path.as_uri(), runner['rootUri'])).path))
    assert re.search(r'^version:\s*2\.17\.1\s*$', (original_root / 'pubspec.yaml').read_text(), re.M)
    relative_source = Path('lib/src/build/shared_part_accumulator.dart')
    original = (original_root / relative_source).read_text()
    needle = '    _finalContent = null;\n    _contributions[phase] ='
    assert original.count(needle) == 1, 'unexpected stock shared-part cache shape'
    correction = '    _contentsByPhase.removeWhere((cachedPhase, _) => cachedPhase >= phase);\n'
    corrected = original.replace(needle, correction + needle)
    target = results / 'stock-reference-runner'
    target.mkdir()
    for name in ('lib', 'bin'):
        shutil.copytree(original_root / name, target / name)
    for name in ('pubspec.yaml', 'LICENSE'):
        shutil.copy2(original_root / name, target / name)
    (target / relative_source).write_text(corrected)
    evidence = {
        'runner': '2.17.1', 'source': relative_source.as_posix(),
        'original_sha256': hashlib.sha256(original.encode()).hexdigest(),
        'corrected_sha256': hashlib.sha256(corrected.encode()).hexdigest(),
        'correction': correction.strip(),
        'original_package_config': config,
    }
    (results / 'stock-reference.json').write_text(json.dumps(evidence, indent=2) + '\n')
    runner['rootUri'] = target.as_uri() + '/'
    config_path.write_text(json.dumps(config, indent=2) + '\n')
    assert (original_root / relative_source).read_text() == original, 'Pub cache source changed'
    print('stock-reference: isolated 2.17.1 shared-part cache invalidation correction', flush=True)
