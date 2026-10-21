#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/verification_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/registry-builder-stock.XXXXXX")
app="$temporary_dir/app"
pub_get_args=()
[[ "${PUB_GET_OFFLINE:-0}" != 1 ]] || pub_get_args+=(--offline)

cleanup() {
  local status=$?
  if ((status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'registry-builder: retained logs/workspace: %s\n' "$temporary_dir" >&2
    return
  fi
  find "$temporary_dir" -depth -type f -delete
  find "$temporary_dir" -depth -type d -empty -delete
}
trap cleanup EXIT
fail() { printf 'registry-builder: FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$app"
cp "$repo_root/fixtures/registry_builder_app/"{pubspec.yaml,pubspec.lock,build.yaml} "$app/"
cp -R "$repo_root/fixtures/registry_builder_app/lib" "$app/"
verification_run_pub_get "$app" registry-stock "$dart_bin" "$pub_cache" "${pub_get_args[@]}"

run_stock() {
  verification_run_stock_build "$app" "registry-stock/$1" "$temporary_dir/$1.log" \
    "$dart_bin" "$pub_cache" build --low-resources-mode
}
assert_registry() {
  APP="$app" EXPECTED="$1" CHANNEL_STEM="${2:-channel}" python3 - <<'PY'
import os
import re
from pathlib import Path

app = Path(os.environ['APP'])
output = (app / 'lib/conduit.g.dart').read_text()
names = re.findall(r"    map\['([^']+)'\] =", output)
assert names == os.environ['EXPECTED'].split(','), names
assert names == sorted(names), names
assert 'void bootstrap()' in output
channel = os.environ['CHANNEL_STEM'] + '.channel.conduit.json'
assert not (app / 'lib' / channel).exists()
assert (app / '.dart_tool/build/generated/registry_builder_app/lib' / channel).is_file()
assert (app / 'lib/controller.controller.conduit.json').is_file()
# RegistryBuilder reads manifests and emits imports without resolving their
# companion Dart libraries. Deliberately do not supply those libraries.
for path in re.findall(r"import 'package:registry_builder_app/([^']+)'", output):
    assert not (app / 'lib' / path).exists(), path
PY
}

run_stock clean
assert_registry Alpha,Channel,Config,Entity,Health,Zulu
cp "$app/lib/conduit.g.dart" "$temporary_dir/baseline.dart"
run_stock no-op
cmp "$temporary_dir/baseline.dart" "$app/lib/conduit.g.dart"
grep -Fq '0 outputs' "$temporary_dir/no-op.log" || fail 'stock no-op wrote outputs'

printf 'still not JSON\n' >> "$app/lib/ignored.json"
run_stock non-target-change
cmp "$temporary_dir/baseline.dart" "$app/lib/conduit.g.dart"

sed -i 's/Health/UpdatedHealth/' "$app/lib/controller.record"
run_stock generated-input-change
assert_registry Alpha,Channel,Config,Entity,UpdatedHealth,Zulu
sed -i 's/UpdatedHealth/Health/' "$app/lib/controller.record"
sed -i 's/Zulu/ZuluV2/' "$app/lib/model.serializable.conduit.json"
run_stock source-input-change
assert_registry Alpha,Channel,Config,Entity,Health,ZuluV2

printf '{"controllers":["Added"]}\n' > "$app/lib/extra.record"
run_stock add
assert_registry Added,Alpha,Channel,Config,Entity,Health,ZuluV2
mv "$app/lib/extra.record" "$app/lib/renamed.record"
run_stock rename
assert_registry Added,Alpha,Channel,Config,Entity,Health,ZuluV2
[[ ! -e "$app/lib/extra.controller.conduit.json" ]] || fail 'rename retained old source output'
grep -Fq 'registry_builder_app/renamed.controller.conduit.dart' "$app/lib/conduit.g.dart"
find "$app/lib" -name renamed.record -delete
run_stock delete
assert_registry Alpha,Channel,Config,Entity,Health,ZuluV2
[[ ! -e "$app/lib/renamed.controller.conduit.json" ]] || fail 'delete retained old source output'
cp "$app/lib/conduit.g.dart" "$temporary_dir/before-failure.dart"

# The exception is raised by the real RegistryBuilder JSON decoder, not by a
# stand-in failure builder. Stock failure publication is not an atomic contract.
printf '{invalid JSON\n' > "$app/lib/controller.record"
if run_stock failure; then fail 'malformed generated manifest succeeded'; fi
grep -Fq 'FormatException' "$temporary_dir/failure.log" || fail 'unexpected failure'
grep -Fq 'registry_builder' "$temporary_dir/failure.log" || fail 'registry did not fail'
printf '{"controllers":["Health"]}\n' > "$app/lib/controller.record"
run_stock recovery
cmp "$temporary_dir/before-failure.dart" "$app/lib/conduit.g.dart"

mv "$app/lib/channel.cached" "$app/lib/new_channel.cached"
run_stock cache-rename
assert_registry Alpha,Channel,Config,Entity,Health,ZuluV2 new_channel
# Stock retains the old physical cache file, but excludes it from the glob.
# assert_registry already proves there is exactly one Channel binding.
[[ -f "$app/.dart_tool/build/generated/registry_builder_app/lib/channel.channel.conduit.json" ]] || \
  fail 'stock cache-retention observation changed'
if grep -Fq 'registry_builder_app/channel.channel.conduit.dart' "$app/lib/conduit.g.dart"; then
  fail 'cache rename retained the old logical registry input'
fi
grep -Fq 'registry_builder_app/new_channel.channel.conduit.dart' "$app/lib/conduit.g.dart"
find "$app/lib" -type f \( -name '*.conduit.json' -o -name '*.record' -o -name '*.cached' \) -delete
run_stock empty
APP="$app" python3 - <<'PY'
import os
from pathlib import Path
app = Path(os.environ['APP'])
output = (app / 'lib/conduit.g.dart').read_text()
assert 'void bootstrap()' in output
assert 'RuntimeCollection(map)' in output
assert "map['" not in output
assert 'package:registry_builder_app/' not in output
assert not list((app / 'lib').glob('*.conduit.json'))
# The empty registry excludes logically removed cache inputs, even though their
# old producer files remain in the artifact tree.
cache = app / '.dart_tool/build/generated/registry_builder_app/lib'
assert (cache / 'channel.channel.conduit.json').is_file()
assert (cache / 'new_channel.channel.conduit.json').is_file()
PY

# Verify the actual dependency boundary for both published versions. Do not
# call native under an override or an unsupported old build_runner solution.
for version in 6.0.0 7.0.0; do
  probe="$temporary_dir/constraint-$version"
  mkdir -p "$probe"
  cat > "$probe/pubspec.yaml" <<EOF
name: registry_constraint_probe
environment:
  sdk: '>=3.12.0 <4.0.0'
dev_dependencies:
  conduit_build_runner: $version
  build_runner: 2.16.2
  build_runner_accelerator:
    path: $repo_root
EOF
  if verification_run_pub_get "$probe" "registry-constraint/$version" \
      "$dart_bin" "$pub_cache" "${pub_get_args[@]}"; then
    fail "$version now resolves: re-evaluate the documented native boundary"
  fi
  log="$probe/.dart_tool/build_runner_accelerator/verification/pub-get.log"
  grep -Fq 'analyzer ^12.0.0' "$log" || fail 'missing Conduit Analyzer constraint'
  grep -Fq 'analyzer ^14.3.0' "$log" || fail 'missing stock Analyzer constraint'
  grep -Fq 'version solving failed' "$log" || fail 'failure was not dependency resolution'
  [[ ! -e "$probe/pubspec.lock" ]] || fail 'failed resolution created a lockfile'
done

printf 'registry-builder: PASS stock-only=7.0.0 stock=2.14.1 clean-noop=yes lifecycle=yes source-cache=yes failure-recovery=yes native=dependency-blocked\n'
