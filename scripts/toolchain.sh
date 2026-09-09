# Shared toolchain resolution for repository scripts.
# Source this file after defining repo_root.

: "${repo_root:?repo_root must be set before sourcing toolchain.sh}"

resolve_toolchain_executable() {
  local explicit=$1
  local local_candidate=$2
  local command_name=$3
  if [[ -n "$explicit" ]]; then
    printf '%s\n' "$explicit"
  elif [[ -x "$local_candidate" ]]; then
    printf '%s\n' "$local_candidate"
  else
    command -v "$command_name" || true
  fi
}

resolve_toolchain_dart() {
  resolve_toolchain_executable \
    "${DART_BIN:-}" \
    "$repo_root/.toolchains/dart/dart-sdk/bin/dart" \
    dart
}

resolve_toolchain_cargo() {
  resolve_toolchain_executable \
    "${CARGO_BIN:-}" \
    "$repo_root/.toolchains/cargo/bin/cargo" \
    cargo
}

resolve_toolchain_pub_cache() {
  printf '%s\n' "${PUB_CACHE:-$repo_root/.pub-cache}"
}

resolve_toolchain_rustup_home() {
  if [[ -n "${RUSTUP_HOME:-}" ]]; then
    printf '%s\n' "$RUSTUP_HOME"
  elif [[ -d "$repo_root/.toolchains/rustup" ]]; then
    printf '%s\n' "$repo_root/.toolchains/rustup"
  else
    printf '%s\n' "${HOME:-$repo_root}/.rustup"
  fi
}

resolve_toolchain_cargo_home() {
  if [[ -n "${CARGO_HOME:-}" ]]; then
    printf '%s\n' "$CARGO_HOME"
  elif [[ -d "$repo_root/.toolchains/cargo" ]]; then
    printf '%s\n' "$repo_root/.toolchains/cargo"
  else
    printf '%s\n' "${HOME:-$repo_root}/.cargo"
  fi
}

resolve_toolchain_dart_sdk() {
  if [[ -n "${DART_SDK:-}" ]]; then
    printf '%s\n' "$DART_SDK"
  elif [[ -d "$repo_root/.toolchains/dart/dart-sdk" ]]; then
    printf '%s\n' "$repo_root/.toolchains/dart/dart-sdk"
  else
    local dart_path
    dart_path=$(resolve_toolchain_dart)
    if [[ "$dart_path" == */bin/dart ]]; then
      printf '%s\n' "${dart_path%/bin/dart}"
    else
      printf '%s\n' ""
    fi
  fi
}
