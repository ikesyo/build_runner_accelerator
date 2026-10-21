#!/usr/bin/env python3
"""Compare raw current outputs, excluding stock's logically deleted cache files."""
import json
import sys
from pathlib import Path


def fields(value):
    assert len(value) % 2 == 0
    return dict(zip(value[::2], value[1::2]))


def stock_outputs(root):
    graph = json.loads((root / '.dart_tool/build/asset_graph.json').read_bytes())
    assert graph['version'] == 47, 'update the pinned stock graph reader'
    ids = graph['ids']
    state = fields(graph['buildState'])
    outputs = {}
    for _, result in zip(state['buildStepResults'][::2], state['buildStepResults'][1::2]):
        result = fields(result)
        assert result.get('result') is not False, result
        for output in result['outputs']:
            outputs[ids[output]] = result['inArtifactTree']
    for key, result in zip(state['postProcessResults'][::2], state['postProcessResults'][1::2]):
        key, result = fields(key), fields(result)
        assert not result['errors'], result
        if result['deletedPrimaryInput']:
            outputs.pop(ids[key['input']], None)
        for output in result['outputs']:
            outputs[ids[output]] = result['inArtifactTree']
    return outputs


def compare(stock, native):
    for subtree in ['lib', 'web']:
        def files(root):
            return {str(p.relative_to(root)): p.read_bytes()
                    for p in (root / subtree).rglob('*') if p.is_file()}
        expected, actual = files(stock), files(native)
        assert expected.keys() == actual.keys(), (subtree, expected.keys() ^ actual.keys())
        for path in expected:
            assert expected[path] == actual[path], f'source byte mismatch: {path}'
    outputs = stock_outputs(stock)
    expected = {}
    for asset, cached in outputs.items():
        package, path = asset.split('|', 1)
        assert cached, f'unexpected source output: {asset}'
        expected[f'{package}/{path}'] = (stock / '.dart_tool/build/generated' / package / path).read_bytes()
    cache = native / '.dart_tool/build_runner_accelerator/cache'
    actual = {str(p.relative_to(cache)): p.read_bytes() for p in cache.rglob('*') if p.is_file()}
    # These public cleanup builders delete their inputs logically. Both engines
    # can retain physical normal outputs after cleanup; they are not published
    # entry artifacts. Never normalize the bytes of any current output.
    cleaned = ('.module.library', '.meta_module.raw', '.meta_module.clean', '.module', '.tar.gz')
    physical_intermediates = {p: value for p, value in actual.items() if p.endswith(cleaned)}
    actual = {p: value for p, value in actual.items() if not p.endswith(cleaned)}
    for path, value in physical_intermediates.items():
        if not path.endswith('.tar.gz') and (stock / '.dart_tool/build/generated' / path).is_file():
            assert value == (stock / '.dart_tool/build/generated' / path).read_bytes(), path
    assert expected.keys() == actual.keys(), ('cache set mismatch', expected.keys() ^ actual.keys())
    mismatches = [path for path in expected if expected[path] != actual[path]]
    assert not mismatches, ('raw cache byte mismatch', mismatches)
    entrypoints = list((stock / 'web').glob('*.dart'))
    for entry in entrypoints:
        if 'void main(' in entry.read_text():
            prefix = f'build_web_compilers_app/web/{entry.stem}.dart.js'
            assert prefix in actual and prefix + '.map' in actual, prefix
    assert not any(p.endswith(cleaned) for p in expected), expected.keys()
    print('web-compilers: raw current output set/bytes match:', ', '.join(sorted(actual)))


if __name__ == '__main__':
    compare(*(Path(p) for p in sys.argv[1:]))
