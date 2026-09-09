#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

source "$script_dir/toolchain.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
toolchain_bin=${RUST_TOOLCHAIN_BIN:-"$repo_root/.toolchains/rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin"}
cargo_bin=${CARGO_BIN:-"$toolchain_bin/cargo"}
rustup_home=$(resolve_toolchain_rustup_home)
cargo_home=$(resolve_toolchain_cargo_home)
temporary_dir=$(mktemp -d)
workspace_root="$temporary_dir/workspace"
fixture_root="$workspace_root/fixtures"
stock_dir="$fixture_root/stock"
rust_dir="$fixture_root/rust"

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
  printf 'target-cycle: FAIL: %s\n' "$*" >&2
  for log in "$temporary_dir"/*.log; do
    if [[ -f "$log" ]]; then
      printf '%s\n' "--- $log ---" >&2
      sed -n '1,220p' "$log" >&2
    fi
  done
  exit 1
}

assert_same_file() {
  local expected=$1
  local actual=$2
  [[ -f "$expected" ]] || fail "missing expected file: $expected"
  [[ -f "$actual" ]] || fail "missing actual file: $actual"
  cmp "$expected" "$actual" || fail "file mismatch: $expected vs $actual"
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -Fq -- "$expected" "$file" || fail "${file##*/} does not contain: $expected"
}

[[ -x "$dart_bin" ]] || fail "Dart executable not found: $dart_bin"
[[ -x "$cargo_bin" ]] || fail "Cargo executable not found: $cargo_bin"

if [[ -z "${BUILD_RUNNER_ACCELERATOR_BIN:-}" ]]; then
  PATH="$toolchain_bin:$PATH" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
    RUSTUP_TOOLCHAIN=1.98.1 "$cargo_bin" build --quiet \
    --manifest-path "$repo_root/rust/Cargo.toml" || fail 'Rust frontend build failed'
  BUILD_RUNNER_ACCELERATOR_BIN="$repo_root/rust/target/debug/build_runner_accelerator"
  export BUILD_RUNNER_ACCELERATOR_BIN
fi
[[ -x "$BUILD_RUNNER_ACCELERATOR_BIN" ]] || \
  fail "Rust frontend binary is not executable: $BUILD_RUNNER_ACCELERATOR_BIN"

write_package() {
  local directory=$1
  mkdir -p "$directory/lib"
  cat >"$directory/pubspec.yaml" <<EOF
name: cycle_app
publish_to: none

environment:
  sdk: ">=3.13.0 <4.0.0"

dependencies:
  build: 4.0.0

dev_dependencies:
  build_runner: 2.7.2
  build_runner_accelerator_worker:
    path: ../../dart_worker
EOF
  cat >"$directory/build.yaml" <<'EOF'
builders:
  cycle_builder:
    import: "package:cycle_app/cycle_builder.dart"
    builder_factories:
      - cycleBuilder
    build_extensions:
      ".txt":
        - ".cycle.txt"
    auto_apply: none
    build_to: source

targets:
  $default:
    sources:
      include:
        - lib/**
    dependencies:
      - :cycle_a
  cycle_a:
    sources:
      include:
        - lib/a.txt
    dependencies:
      - :cycle_b
    builders:
      cycle_app:cycle_builder:
        generate_for:
          - lib/a.txt
  cycle_b:
    sources:
      include:
        - lib/b.txt
    dependencies:
      - :cycle_a
    builders:
      cycle_app:cycle_builder:
        generate_for:
          - lib/b.txt
EOF
  cat >"$directory/lib/cycle_builder.dart" <<'EOF'
import 'package:build/build.dart';

Builder cycleBuilder(BuilderOptions options) => _CycleBuilder();

class _CycleBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.txt': ['.cycle.txt'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final peerPath = buildStep.inputId.path.endsWith('/a.txt')
        ? 'lib/b.cycle.txt'
        : 'lib/a.cycle.txt';
    final peer = AssetId(buildStep.inputId.package, peerPath);
    final visible = await buildStep.canRead(peer);
    final peerValue = visible ? await buildStep.readAsString(peer) : 'unavailable';
    final input = await buildStep.readAsString(buildStep.inputId);
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      input.trimRight() + '|peer=' + peerValue.trimRight() + '\n',
    );
  }
}
EOF
  printf 'a\n' >"$directory/lib/a.txt"
  printf 'b\n' >"$directory/lib/b.txt"
  (cd "$directory" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics pub get --offline >/dev/null) || \
    fail "pub get failed for $directory"
}

run_stock() {
  local directory=$1
  local log=$2
  (cd "$directory" && PUB_CACHE="$pub_cache" "$dart_bin" --suppress-analytics \
    run build_runner build --delete-conflicting-outputs >"$log" 2>&1)
}

run_rust() {
  local directory=$1
  local log=$2
  PUB_CACHE="$pub_cache" BUILD_RUNNER_ACCELERATOR_BIN="$BUILD_RUNNER_ACCELERATOR_BIN" \
    "$script_dir/run_rust_frontend.sh" build --root "$directory" --dart "$dart_bin" \
    >"$log" 2>&1
}

mkdir -p "$fixture_root"
ln -s "$repo_root/dart_worker" "$workspace_root/dart_worker"
write_package "$stock_dir"
write_package "$rust_dir"

run_stock "$stock_dir" "$temporary_dir/initial.stock.log"
run_rust "$rust_dir" "$temporary_dir/initial.rust.log"
for output in a.cycle.txt b.cycle.txt; do
  assert_same_file "$stock_dir/lib/$output" "$rust_dir/lib/$output"
done
assert_contains "$stock_dir/lib/a.cycle.txt" 'a|peer=unavailable'
assert_contains "$stock_dir/lib/b.cycle.txt" 'b|peer=a|peer=unavailable'
assert_contains "$temporary_dir/initial.rust.log" 'Rust frontend: 2 build action(s)'

run_rust "$rust_dir" "$temporary_dir/no-op.rust.log"
assert_contains "$temporary_dir/no-op.rust.log" 'No work to do (Rust frontend)'

printf 'a changed\n' >"$stock_dir/lib/a.txt"
printf 'a changed\n' >"$rust_dir/lib/a.txt"
run_stock "$stock_dir" "$temporary_dir/change.stock.log"
run_rust "$rust_dir" "$temporary_dir/change.rust.log"
for output in a.cycle.txt b.cycle.txt; do
  assert_same_file "$stock_dir/lib/$output" "$rust_dir/lib/$output"
done
assert_contains "$temporary_dir/change.rust.log" 'Rust frontend: 2 build action(s)'

rm -f -- "$stock_dir/lib/b.txt" "$rust_dir/lib/b.txt"
run_stock "$stock_dir" "$temporary_dir/delete.stock.log"
run_rust "$rust_dir" "$temporary_dir/delete.rust.log"
assert_same_file "$stock_dir/lib/a.cycle.txt" "$rust_dir/lib/a.cycle.txt"
[[ ! -e "$stock_dir/lib/b.cycle.txt" ]] || fail 'stock cycle output was not deleted'
[[ ! -e "$rust_dir/lib/b.cycle.txt" ]] || fail 'Rust cycle output was not deleted'
assert_contains "$temporary_dir/delete.rust.log" 'Rust frontend: 0 build action(s)'

printf 'target-cycle: scc-order=yes phase-order=yes no-op=yes incremental=yes delete-only=yes\n'
