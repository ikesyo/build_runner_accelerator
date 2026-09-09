#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)

if [[ -n "${FAST_BUILD_RUNNER_BIN:-}" ]]; then
  exec "$FAST_BUILD_RUNNER_BIN" "$@"
fi

cargo_bin=${CARGO_BIN:-"$repo_root/.toolchains/cargo/bin/cargo"}
rustup_home=${RUSTUP_HOME:-"$repo_root/.toolchains/rustup"}
cargo_home=${CARGO_HOME:-"$repo_root/.toolchains/cargo"}

[[ -x "$cargo_bin" ]] || {
  printf 'Cargo executable not found: %s\n' "$cargo_bin" >&2
  exit 1
}

RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" \
  "$cargo_bin" run --quiet --manifest-path "$repo_root/rust/Cargo.toml" -- "$@"
