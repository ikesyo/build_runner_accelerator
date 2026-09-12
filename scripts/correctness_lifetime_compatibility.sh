#!/usr/bin/env bash
set -euo pipefail

# Validate builder-instance and ResourceManager lifetime compatibility between
# the current fast worker and stock build_runner.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
fixture_dir="$repo_root/fixtures/lifetime_builder_app"
lockfile_source="$repo_root/fixtures/arbitrary_builder_app/pubspec.lock"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
cargo_bin=$(resolve_toolchain_cargo)
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/build-runner-accelerator-lifetime.XXXXXX")
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"
pub_get_args=()
if [[ "${PUB_GET_OFFLINE:-0}" == 1 ]]; then
  pub_get_args+=(--offline)
fi

remove_tree() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  if [[ -L "$path" ]]; then
    rm -f -- "$path"
    return 0
  fi
  find "$path" -depth -type f -delete
  find "$path" -depth -type l -delete
  find "$path" -depth -type d -empty -delete
}

cleanup() {
  remove_tree "$temporary_dir"
}
trap cleanup EXIT

fail() {
  printf 'lifetime-compatibility: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    [[ -f "$log" ]] || continue
    printf '%s\n' "--- $log ---" >&2
    sed -n '1,220p' "$log" >&2
  done
  exit 1
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -f "$fixture_dir/build.yaml" ]] || fail "fixture not found: $fixture_dir"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  [[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"
  RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    "$cargo_bin" build --quiet --manifest-path "$repo_root/rust/Cargo.toml" \
    || fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || fail "Rust frontend is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

mkdir -p "$fixture_root"
ln -s "$repo_root/dart_worker" "$workspace_root/dart_worker"

write_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cp "$fixture_dir/pubspec.yaml" "$directory/pubspec.yaml"
  cp "$lockfile_source" "$directory/pubspec.lock"
  cp "$fixture_dir/build.yaml" "$directory/build.yaml"
  cp "$fixture_dir/lib/lifetime_builder.dart" "$directory/lib/lifetime_builder.dart"
  cp "$fixture_dir/lib"/input_*.txt "$directory/lib/"
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get "${pub_get_args[@]}" \
    >"$temporary_dir/$(basename "$directory").pub-get.log" 2>&1) \
    || fail "pub get failed for $directory"
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && \
    PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics run build_runner \
      build --delete-conflicting-outputs >"$log" 2>&1)
}

run_rust() {
  local directory=$1
  local log=$2
  PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
    "$script_dir/run_rust_frontend.sh" build --root "$directory" --dart "$dart_bin" \
    --jobs 1 \
    >"$log" 2>&1
}

field_values() {
  local file=$1
  local field=$2
  sed -E "s/.* ${field}=([^ ]+).*/\1/" "$file" | sort -n
}

assert_value_set() {
  local label=$1
  local expected=$2
  local actual=$3
  [[ "$actual" == "$expected" ]] || {
    printf '%s\n' "--- $label ---" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    fail "$label did not match"
  }
}

for directory in "$stock_dir" "$rust_dir"; do
  write_package "$directory"
done

run_stock "$stock_dir" "$temporary_dir/stock.log" || fail 'stock build failed'
run_rust "$rust_dir" "$temporary_dir/rust.log" || fail 'Rust build failed'

for input in 01 02 03 04; do
  [[ -f "$stock_dir/lib/input_${input}.lifetime.txt" ]] || \
    fail "stock output missing for input_${input}"
  [[ -f "$rust_dir/lib/input_${input}.lifetime.txt" ]] || \
    fail "Rust output missing for input_${input}"
  [[ -f "$stock_dir/lib/input_${input}.lifetime.final.txt" ]] || \
    fail "stock final output missing for input_${input}"
  [[ -f "$rust_dir/lib/input_${input}.lifetime.final.txt" ]] || \
    fail "Rust final output missing for input_${input}"
done

stock_instances=$(for file in "$stock_dir"/lib/*.lifetime.txt; do field_values "$file" instance; done | sort -n -u)
stock_builds=$(for file in "$stock_dir"/lib/*.lifetime.txt; do field_values "$file" build; done | sort -n -u)
stock_resources=$(for file in "$stock_dir"/lib/*.lifetime.txt; do field_values "$file" resource; done | sort -n -u)
stock_resource_uses=$(for file in "$stock_dir"/lib/*.lifetime.txt; do field_values "$file" resource_use; done | sort -n -u)
rust_instances=$(for file in "$rust_dir"/lib/*.lifetime.txt; do field_values "$file" instance; done | sort -n -u)
rust_builds=$(for file in "$rust_dir"/lib/*.lifetime.txt; do field_values "$file" build; done | sort -n -u)
rust_resources=$(for file in "$rust_dir"/lib/*.lifetime.txt; do field_values "$file" resource; done | sort -n -u)
rust_resource_uses=$(for file in "$rust_dir"/lib/*.lifetime.txt; do field_values "$file" resource_use; done | sort -n -u)
stock_final_instances=$(for file in "$stock_dir"/lib/*.lifetime.final.txt; do field_values "$file" instance; done | sort -n -u)
stock_final_builds=$(for file in "$stock_dir"/lib/*.lifetime.final.txt; do field_values "$file" build; done | sort -n -u)
stock_final_resources=$(for file in "$stock_dir"/lib/*.lifetime.final.txt; do field_values "$file" resource; done | sort -n -u)
stock_final_resource_uses=$(for file in "$stock_dir"/lib/*.lifetime.final.txt; do field_values "$file" resource_use; done | sort -n -u)
rust_final_instances=$(for file in "$rust_dir"/lib/*.lifetime.final.txt; do field_values "$file" instance; done | sort -n -u)
rust_final_builds=$(for file in "$rust_dir"/lib/*.lifetime.final.txt; do field_values "$file" build; done | sort -n -u)
rust_final_resources=$(for file in "$rust_dir"/lib/*.lifetime.final.txt; do field_values "$file" resource; done | sort -n -u)
rust_final_resource_uses=$(for file in "$rust_dir"/lib/*.lifetime.final.txt; do field_values "$file" resource_use; done | sort -n -u)

expected_one=1
expected_sequence=$'1\n2\n3\n4'
expected_final_resource_sequence=$'5\n6\n7\n8'
assert_value_set 'stock builder instances' "$expected_one" "$stock_instances"
assert_value_set 'stock builder build sequence' "$expected_sequence" "$stock_builds"
assert_value_set 'stock resource instances' "$expected_one" "$stock_resources"
assert_value_set 'stock resource use sequence' "$expected_sequence" "$stock_resource_uses"
assert_value_set 'stock final builder instances' "$expected_one" "$stock_final_instances"
assert_value_set 'stock final builder build sequence' "$expected_sequence" "$stock_final_builds"
assert_value_set 'stock final resource instances' "$expected_one" "$stock_final_resources"
assert_value_set \
  'stock final resource use sequence' \
  "$expected_final_resource_sequence" \
  "$stock_final_resource_uses"

printf 'stock: instances=%s builds=%s resources=%s resource_uses=%s\n' \
  "$(tr '\n' ',' <<<"$stock_instances" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$stock_builds" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$stock_resources" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$stock_resource_uses" | sed 's/,$//')"
printf 'stock-final: instances=%s builds=%s resources=%s resource_uses=%s\n' \
  "$(tr '\n' ',' <<<"$stock_final_instances" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$stock_final_builds" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$stock_final_resources" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$stock_final_resource_uses" | sed 's/,$//')"
printf 'rust: instances=%s builds=%s resources=%s resource_uses=%s\n' \
  "$(tr '\n' ',' <<<"$rust_instances" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$rust_builds" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$rust_resources" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$rust_resource_uses" | sed 's/,$//')"
printf 'rust-final: instances=%s builds=%s resources=%s resource_uses=%s\n' \
  "$(tr '\n' ',' <<<"$rust_final_instances" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$rust_final_builds" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$rust_final_resources" | sed 's/,$//')" \
  "$(tr '\n' ',' <<<"$rust_final_resource_uses" | sed 's/,$//')"

for input in 01 02 03 04; do
  cmp "$stock_dir/lib/input_${input}.lifetime.txt" \
    "$rust_dir/lib/input_${input}.lifetime.txt" || \
    fail "post-rebase output mismatch for input_${input}"
  cmp "$stock_dir/lib/input_${input}.lifetime.final.txt" \
    "$rust_dir/lib/input_${input}.lifetime.final.txt" || \
    fail "post-rebase final output mismatch for input_${input}"
done
printf 'lifetime-compatibility: PASS (stock match)\n'
