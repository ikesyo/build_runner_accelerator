#!/usr/bin/env bash
# Shared setup and assertions for the real Conduit registry override experiment.

registry_override_prepare() {
  worker_ensure_frontend
  mkdir -p "$workspace_root/fixtures"
  worker_attach "$workspace_root"
  local directory
  for directory in "$stock_dir" "$rust_dir"; do
    mkdir -p "$directory/lib"
    cp "$repo_root/fixtures/registry_builder_override_app/"{pubspec.yaml,pubspec.lock,build.yaml} "$directory/"
    cp -R "$repo_root/fixtures/registry_builder_app/lib/." "$directory/lib/"
    cp -R "$repo_root/fixtures/registry_builder_override_app/lib/." "$directory/lib/"
    # A real source ending in the token must retain normal suffix replacement.
    printf 'ordinary source\n' > "$directory/lib/suffix\$lib\$"
    # Virtual IDs stay unreadable even if a file occupies their reserved path.
    local path
    for path in '$package$' 'lib/$lib$' 'test/$test$' 'web/$web$'; do
      mkdir -p "$(dirname -- "$directory/$path")"
      printf 'not virtual content\n' > "$directory/$path"
    done
    verification_run_pub_get "$directory" "registry-override/pub/$(basename "$directory")" \
      "$dart_bin" "$pub_cache" "${pub_get_args[@]}"
  done
}

registry_override_stock() {
  verification_run_stock_build "$stock_dir" "registry-override/stock/$1" \
    "$temporary_dir/$1.stock.log" "$dart_bin" "$pub_cache" build
}

registry_override_native() {
  VERIFY_COMMAND_LOG="$temporary_dir/$1.native.log" VERIFY_WORKSPACE="$rust_dir" \
    worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" --jobs 1
}

registry_override_compare() {
  STOCK_DIR="$stock_dir" NATIVE_DIR="$rust_dir" python3 - <<'PY'
import json
import os
from pathlib import Path

stock, native = (Path(os.environ[key]) for key in ['STOCK_DIR', 'NATIVE_DIR'])
for subtree in ['lib', 'test', 'web']:
    def files(root):
        return {str(p.relative_to(root)): p.read_bytes()
                for p in (root / subtree).rglob('*') if p.is_file()}
    expected, actual = files(stock), files(native)
    assert expected.keys() == actual.keys(), (subtree, expected.keys() ^ actual.keys())
    for path in expected:
        assert expected[path] == actual[path], f'byte mismatch: {path}'

stock_cache = stock / '.dart_tool/build/generated/registry_builder_app'
native_cache = native / '.dart_tool/build_runner_accelerator/cache/registry_builder_app'
# Compare currently declared outputs. Stock may retain old physical artifacts
# after producer deletion; the ordered probes assert their logical invisibility.
expected_cache = {
    str(p.relative_to(stock)).removesuffix('.cached') + '.channel.conduit.json'
    for p in (stock / 'lib').glob('*.cached')
}
actual_cache = {str(p.relative_to(native_cache)) for p in native_cache.rglob('*') if p.is_file()}
assert actual_cache == expected_cache, (actual_cache, expected_cache)
for path in expected_cache:
    assert (stock_cache / path).read_bytes() == (native_cache / path).read_bytes(), path

for path in ['lib/placeholder.probe.txt', 'test/placeholder.probe.txt',
             'web/placeholder.probe.txt', 'lib/suffixplaceholder.probe.txt']:
    probe = json.loads((native / path).read_text())
    assert probe['unreadable'] == ['$package$', 'lib/$lib$', 'test/$test$', 'web/$web$']
    for reserved in probe['unreadable']:
        # Stock lists a physical file at a reserved path, despite canRead=false.
        # Purely virtual identities do not themselves become glob candidates.
        listed = reserved in probe['assets']
        assert listed == (reserved.startswith('lib/') and (native / reserved).is_file()), probe
    assert not any(p.endswith('.probe.txt') for p in probe['assets']), probe
    assert not any(p.endswith('.channel.conduit.json') and p not in expected_cache
                   for p in probe['assets']), probe
PY
}

registry_override_pair() {
  registry_override_stock "$1"
  registry_override_native "$1"
  registry_override_compare
}

registry_override_capture_atomic() {
  NATIVE_DIR="$rust_dir" ATOMIC_PATH="$temporary_dir/atomic.json" python3 - <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ['NATIVE_DIR'])
paths = [root / 'lib/conduit.g.dart', root / 'lib/controller.controller.conduit.json',
         root / '.dart_tool/build_runner_accelerator/graph-v3.bin']
paths += list(root.rglob('*.probe.txt'))
paths += [p for p in (root / '.dart_tool/build_runner_accelerator/cache').rglob('*') if p.is_file()]
snapshot = {str(p.relative_to(root)): p.read_bytes().hex() for p in paths}
Path(os.environ['ATOMIC_PATH']).write_text(json.dumps(snapshot))
PY
}

registry_override_assert_atomic() {
  NATIVE_DIR="$rust_dir" ATOMIC_PATH="$temporary_dir/atomic.json" python3 - <<'PY'
import json
import os
from pathlib import Path
root = Path(os.environ['NATIVE_DIR'])
for path, before in json.loads(Path(os.environ['ATOMIC_PATH']).read_text()).items():
    assert (root / path).read_bytes().hex() == before, f'failed build published {path}'
PY
}
