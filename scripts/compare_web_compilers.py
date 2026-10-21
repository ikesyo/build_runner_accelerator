#!/usr/bin/env python3
"""Compare raw current outputs, excluding stock's logically deleted cache files."""
import json
import sys
from pathlib import Path

from web_compilers_graph import native_graph


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


def compare_evidence(stock, native, mode):
    """Compare configured chain order, official inputs and generated globs."""
    graph = json.loads((stock / '.dart_tool/build/asset_graph.json').read_bytes())
    ids, state = graph['ids'], fields(graph['buildState'])
    actions, inputs, globs = native_graph(native)
    by_identity = {(a['builder'], a['input']): key for key, a in actions.items()}
    suffixes = [('.module.library', 'module_library'),
                ('.meta_module.raw', 'dart2js_modules#factory0'),
                ('.meta_module.clean', 'dart2js_modules#factory1'),
                ('.dart2js.module', 'dart2js_modules#factory2'),
                ('.dart.js', 'entrypoint')]
    if mode == "ddc":
        suffixes = [(".module.library", "module_library"),
                    (".meta_module.raw", "ddc_modules#factory0"),
                    (".meta_module.clean", "ddc_modules#factory1"),
                    (".ddc.module", "ddc_modules#factory2"),
                    (".ddc.dill", "ddc#factory0"),
                    (".ddc.js", "ddc#factory1"),
                    (".dart.js", "entrypoint"),
                    ("/dart_sdk.js", "sdk_js#factory0"),
                    ("/require.js", "sdk_js#factory1")]
        manifest_path = native / '.dart_tool/build_runner_accelerator/builder-manifest.json'
        manifest = json.loads(manifest_path.read_bytes())
        scopes = {(b['id'], b['package']): (b['target_order'], b['phase'])
                  for b in manifest['builders']}
    timeline = []
    checked = 0
    checked_builders = set()
    for key, result in zip(state['buildStepResults'][::2], state['buildStepResults'][1::2]):
        key, result = fields(key), fields(result)
        primary = ids[key['primaryInput']]
        tracked_primary = primary.startswith('build_web_compilers_app|') or (
            mode == 'ddc' and primary == 'build_web_compilers|$package$')
        marker = mode == 'ddc' and primary == 'build_web_compilers_app|web/$web$'
        if not tracked_primary or (not result['outputs'] and not marker):
            continue
        outputs = [ids[i] for i in result['outputs']]
        builder = 'entrypoint_marker' if marker else next((name for suffix, name in suffixes if any(p.endswith(suffix) for p in outputs)), None)
        if builder is None:
            continue
        identity = (f'build_web_compilers:{builder}', primary)
        native_key = by_identity[identity]
        assert inputs[native_key] == [ids[i] for i in result['inputs']], ('input order', identity, inputs[native_key], result['inputs'])
        assert not result['resolverEntrypoints'] and not actions[native_key]['entrypoints'], identity
        checked += 1
        checked_builders.add(builder)
        if mode == 'ddc':
            scope = scopes[(identity[0], primary.split('|')[0])]
            timeline.append((key['phaseNumber'], scope, identity))
    assert checked >= 5, checked
    if mode == "ddc":
        assert checked_builders == {name for _, name in suffixes} | {"entrypoint_marker"}, checked_builders
        # Numeric phase IDs differ between engines; compare the configured
        # timeline using target order and phase, never BuilderDefinition.phase.
        stock_order = [identity for _, _, identity in sorted(timeline)]
        native_order = [identity for _, _, identity in
                        sorted(timeline, key=lambda row: (row[1], row[2]))]
        assert stock_order == native_order, ('configured chain order', stock_order, native_order)
        assert not any(a["outputs"] for a in actions.values()
                       if a["builder"].startswith(("build_web_compilers:dart2js_modules",
                                                   "build_web_compilers:dart2wasm_modules")))
    stock_globs = {}
    for key, result in zip(state['globResults'][::2], state['globResults'][1::2]):
        key, result = fields(key), fields(result)
        if key['package'] == 'build_web_compilers_app':
            stock_globs[f"{key['package']}|{key['glob']}"] = [ids[i] for i in result['results']]
    actual_globs = {}
    for key, action in actions.items():
        if action['builder'] == f'build_web_compilers:{"ddc" if mode == "ddc" else "dart2js"}_modules#factory0' and action['input'].startswith('build_web_compilers_app|'):
            actual_globs.update(globs[key])
    assert stock_globs == actual_globs, ('ordered generated glob', stock_globs, actual_globs)


def compare(stock, native, mode="dart2js"):
    """Compare sources and the full logical public cache set without normalization."""
    assert mode in {"dart2js", "ddc"}, mode
    for subtree in ['lib', 'web']:
        def files(root):
            return {str(p.relative_to(root)): p.read_bytes()
                    for p in (root / subtree).rglob('*') if p.is_file()}
        expected, actual = files(stock), files(native)
        assert expected.keys() == actual.keys(), (subtree, expected.keys() ^ actual.keys())
        for path in expected:
            assert expected[path] == actual[path], f'source byte mismatch: {path}'
    compare_evidence(stock, native, mode)
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
    cleaned = ('.module.library', '.meta_module.raw', '.meta_module.clean', '.module')
    if mode == 'dart2js':
        cleaned += ('.tar.gz',)
    physical_intermediates = {p: value for p, value in actual.items() if p.endswith(cleaned)}
    actual = {p: value for p, value in actual.items() if not p.endswith(cleaned)}
    for path, value in physical_intermediates.items():
        if not path.endswith('.tar.gz') and (stock / '.dart_tool/build/generated' / path).is_file():
            assert value == (stock / '.dart_tool/build/generated' / path).read_bytes(), path
    assert expected.keys() == actual.keys(), ('cache set mismatch', expected.keys() ^ actual.keys())
    mismatches = [path for path in expected if expected[path] != actual[path]]
    assert not mismatches, ('raw cache byte mismatch', mismatches)
    for path, value in physical_intermediates.items():
        other = stock / '.dart_tool/build/generated' / path
        if path.endswith('.tar.gz') and other.is_file():
            print('web-compilers: logically deleted archive raw-byte equality:', value == other.read_bytes())
    if mode == "ddc":
        assert any(p.endswith(".ddc.js") for p in actual), actual.keys()
        sdk_prefix = "build_web_compilers/lib/src/dev_compiler/"
        assert all(sdk_prefix + name in actual for name in
                   ["dart_sdk.js", "dart_sdk.js.map", "require.js", "ddc_module_loader.js"])
        for entry in (stock / "web").rglob("*.dart"):
            if "void main(" not in entry.read_text():
                continue
            prefix = f"build_web_compilers_app/{entry.relative_to(stock)}"
            assert all(prefix + suffix in actual for suffix in
                       [".js", ".bootstrap.js", ".bootstrap.end.js", ".ddc_merged_metadata"]), prefix
            assert prefix.removesuffix(".dart") + ".digests" in actual, prefix
            assert actual[prefix + ".bootstrap.end.js"] == b"", prefix
        assert not any(p.endswith((".ddc.full.dill", ".ddc.js.symbols", ".ddc.js.errors")) for p in actual)
        print("web-compilers: DDC complete raw current output set/bytes match:", ", ".join(sorted(actual)))
        return
    entrypoints = list((stock / 'web').rglob('*.dart'))
    entry_outputs = set()
    for entry in entrypoints:
        if 'void main(' in entry.read_text():
            prefix = f'build_web_compilers_app/{entry.relative_to(stock)}.js'
            entry_outputs.update([prefix, prefix + '.map'])
            assert prefix in actual and prefix + '.map' in actual, prefix
    assert set(actual) == entry_outputs, ('live entrypoint outputs', set(actual) ^ entry_outputs)
    assert not any(p.endswith(cleaned) for p in expected), expected.keys()
    print('web-compilers: raw current output set/bytes match:', ', '.join(sorted(actual)))


if __name__ == '__main__':
    compare(Path(sys.argv[1]), Path(sys.argv[2]), *(sys.argv[3:]))
