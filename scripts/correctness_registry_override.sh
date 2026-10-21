#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/verification_support.sh"
source "$script_dir/registry_override_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/registry-override.XXXXXX")
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/native"
pub_get_args=()
[[ "${PUB_GET_OFFLINE:-0}" != 1 ]] || pub_get_args+=(--offline)
cleanup() {
  local status=$?
  if ((status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'registry-override: retained workspace/logs: %s\n' "$temporary_dir" >&2
    return
  fi
  find "$temporary_dir" -depth -type f -delete
  find "$temporary_dir" -depth -type l -delete
  find "$temporary_dir" -depth -type d -empty -delete
}
trap cleanup EXIT

registry_override_prepare
registry_override_pair clean
cp "$rust_dir/lib/conduit.g.dart" "$temporary_dir/initial.dart"
registry_override_pair no-op
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.native.log"
cmp "$temporary_dir/initial.dart" "$rust_dir/lib/conduit.g.dart"

printf 'ignored change\n' | tee -a "$stock_dir/lib/ignored.json" >> "$rust_dir/lib/ignored.json"
registry_override_pair non-target
cmp "$temporary_dir/initial.dart" "$rust_dir/lib/conduit.g.dart"
for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/Zulu/ZuluV2/' "$directory/lib/model.serializable.conduit.json"
done
registry_override_pair source-change
grep -Fq "map['ZuluV2']" "$rust_dir/lib/conduit.g.dart"
for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/Health/HealthV2/' "$directory/lib/controller.record"
  sed -i 's/Channel/ChannelV2/' "$directory/lib/channel.cached"
done
registry_override_pair generated-change
grep -Fq "map['HealthV2']" "$rust_dir/lib/conduit.g.dart"
grep -Fq "map['ChannelV2']" "$rust_dir/lib/conduit.g.dart"

for directory in "$stock_dir" "$rust_dir"; do
  printf '{"controllers":["Added"]}\n' > "$directory/lib/extra.record"
  printf '{"channels":["AddedChannel"]}\n' > "$directory/lib/extra.cached"
done
registry_override_pair add
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/extra.record" "$directory/lib/renamed.record"
  mv "$directory/lib/extra.cached" "$directory/lib/renamed.cached"
done
registry_override_pair rename
[[ ! -e "$rust_dir/lib/extra.controller.conduit.json" ]]
grep -Fq 'registry_builder_app/renamed.controller.conduit.dart' "$rust_dir/lib/conduit.g.dart"
for directory in "$stock_dir" "$rust_dir"; do
  find "$directory/lib" -maxdepth 1 -type f \( -name 'renamed.record' -o -name 'renamed.cached' \) -delete
done
registry_override_pair delete
[[ ! -e "$rust_dir/lib/renamed.controller.conduit.json" ]]

registry_override_capture_atomic lib/controller.record lib/channel.cached
for directory in "$stock_dir" "$rust_dir"; do
  printf '{invalid JSON\n' > "$directory/lib/controller.record"
  sed -i 's/ChannelV2/BrokenChannel/' "$directory/lib/channel.cached"
done
if registry_override_stock failure; then exit 1; fi
if registry_override_native failure; then exit 1; fi
grep -Fq 'FormatException' "$temporary_dir/failure.stock.log"
grep -Fq 'FormatException' "$temporary_dir/failure.native.log"
registry_override_assert_atomic
for directory in "$stock_dir" "$rust_dir"; do
  printf '{"controllers":["HealthV2"]}\n' > "$directory/lib/controller.record"
  sed -i 's/BrokenChannel/ChannelV2/' "$directory/lib/channel.cached"
done
registry_override_pair recovery

# Physical sources at reserved virtual paths have history-dependent stock
# deletion behavior. Reject the unvalidated shape before actions/publication.
for path in '$package$' 'lib/$lib$' 'test/$test$' 'web/$web$'; do
  printf 'reserved physical source\n' > "$rust_dir/$path"
  registry_override_capture_atomic
  if registry_override_native reserved-source; then exit 1; fi
  grep -Fq 'Unsupported native source at a virtual primary path' "$temporary_dir/reserved-source.native.log"
  registry_override_assert_atomic
  find "$rust_dir/$path" -maxdepth 0 -type f -delete
done

# generate_for applies to the virtual input, not to its fixed output path.
for directory in "$stock_dir" "$rust_dir"; do
  sed -i '/conduit_build_runner:registry_builder:/a\        generate_for: ["lib/**"]' "$directory/build.yaml"
done
registry_override_pair excluded-primary
[[ ! -e "$rust_dir/lib/conduit.g.dart" ]]
for directory in "$stock_dir" "$rust_dir"; do
  cp "$repo_root/fixtures/registry_builder_override_app/build.yaml" "$directory/build.yaml"
done
registry_override_pair restored-primary

for directory in "$stock_dir" "$rust_dir"; do
  find "$directory/lib" -maxdepth 1 -type f \( -name '*.conduit.json' -o -name '*.record' -o -name '*.cached' \) -delete
done
registry_override_pair empty
if grep -Fq "map['" "$rust_dir/lib/conduit.g.dart"; then exit 1; fi
registry_override_pair empty-no-op
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/empty-no-op.native.log"

# The virtual primary also participates in selected-output demand. Compare the
# demanded registry and producer; unselected source-file retention is separate.
for directory in "$stock_dir" "$rust_dir"; do
  printf '{"controllers":["Filtered"]}\n' > "$directory/lib/filtered.record"
done
for label in filtered filtered-no-op filtered-change; do
  if [[ "$label" == filtered-change ]]; then
    sed -i 's/Filtered/FilteredV2/' "$stock_dir/lib/filtered.record" "$rust_dir/lib/filtered.record"
  fi
  verification_run_stock_build "$stock_dir" "registry-override/stock/$label" \
    "$temporary_dir/$label.stock.log" "$dart_bin" "$pub_cache" build --build-filter=lib/conduit.g.dart
  VERIFY_COMMAND_LOG="$temporary_dir/$label.native.log" VERIFY_WORKSPACE="$rust_dir" \
    worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" --jobs 1 --build-filter=lib/conduit.g.dart
  cmp "$stock_dir/lib/conduit.g.dart" "$rust_dir/lib/conduit.g.dart"
  cmp "$stock_dir/lib/filtered.controller.conduit.json" "$rust_dir/lib/filtered.controller.conduit.json"
done
grep -Fq "map['FilteredV2']" "$rust_dir/lib/conduit.g.dart"
printf 'registry-override: PASS bytes=yes virtual-inputs=4 suffix=yes ordered-glob=yes source-cache=yes lifecycle=yes atomic-recovery=yes empty=yes\n'
