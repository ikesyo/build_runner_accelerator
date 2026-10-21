#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
source "$script_dir/toolchain.sh"
source "$script_dir/worker.sh"
source "$script_dir/web_compilers_support.sh"
dart_bin=$(resolve_toolchain_dart)
pub_cache=$(resolve_toolchain_pub_cache)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/web-compilers.XXXXXX")
workspace_root="$temporary_dir/workspace"
stock_dir="$workspace_root/fixtures/stock"
rust_dir="$workspace_root/fixtures/native"
pub_get_args=()
[[ "${PUB_GET_OFFLINE:-0}" != 1 ]] || pub_get_args+=(--offline)
cleanup() {
  local status=$?
  if ((status != 0)) && [[ "${VERIFY_KEEP_TEMP_ON_FAILURE:-1}" != 0 ]]; then
    printf 'web-compilers: retained workspace/logs: %s\n' "$temporary_dir" >&2
    return
  fi
  find "$temporary_dir" -depth -type f -delete
  find "$temporary_dir" -depth -type l -delete
  find "$temporary_dir" -depth -type d -empty -delete
}
trap cleanup EXIT
web_prepare
web_pair clean
web_pair no-op
grep -Fq 'No work to do (Rust frontend)' "$temporary_dir/no-op.native.log"
cp "$rust_dir/.dart_tool/build_runner_accelerator/cache/build_web_compilers_app/web/main.dart.js" "$temporary_dir/initial.js"
for directory in "$stock_dir" "$rust_dir"; do
  printf 'unrelated edit\n' >> "$directory/web/notes.txt"
done
web_pair non-target
cmp "$temporary_dir/initial.js" "$rust_dir/.dart_tool/build_runner_accelerator/cache/build_web_compilers_app/web/main.dart.js"
for directory in "$stock_dir" "$rust_dir"; do
  sed -i 's/hello web/changed library/' "$directory/lib/message.dart"
done
web_pair library-change
! cmp -s "$temporary_dir/initial.js" "$rust_dir/.dart_tool/build_runner_accelerator/cache/build_web_compilers_app/web/main.dart.js"
for directory in "$stock_dir" "$rust_dir"; do
  sed -i "s/print(message());/print('entry: \${message()}');/" "$directory/web/main.dart"
done
web_pair entry-change
for directory in "$stock_dir" "$rust_dir"; do
  printf "String extra() => 'added dependency';\n" > "$directory/lib/extra.dart"
  printf "import 'package:build_web_compilers_app/extra.dart';\nvoid main() { print(extra()); }\n" > "$directory/web/extra.dart"
done
web_pair add
for directory in "$stock_dir" "$rust_dir"; do
  mv "$directory/lib/extra.dart" "$directory/lib/renamed.dart"
  mv "$directory/web/extra.dart" "$directory/web/renamed.dart"
  sed -i 's@/extra.dart@/renamed.dart@' "$directory/web/renamed.dart"
done
web_pair rename
[[ ! -e "$rust_dir/.dart_tool/build_runner_accelerator/cache/build_web_compilers_app/web/extra.dart.js" ]]
for directory in "$stock_dir" "$rust_dir"; do
  rm "$directory/lib/renamed.dart" "$directory/web/renamed.dart"
done
web_pair delete
web_atomic save
for directory in "$stock_dir" "$rust_dir"; do
  printf "String message() => missingCompilerSymbol;\n" > "$directory/lib/message.dart"
  printf "void main() { print('tentative output'); }\n" > "$directory/web/tentative.dart"
done
if web_stock failure; then exit 1; fi
if web_native failure; then exit 1; fi
grep -Fq 'missingCompilerSymbol' "$temporary_dir/failure.stock.log"
grep -Fq 'missingCompilerSymbol' "$temporary_dir/failure.native.log"
web_atomic check
for directory in "$stock_dir" "$rust_dir"; do
  printf "String message() => 'recovered';\n" > "$directory/lib/message.dart"
done
web_pair recovery
printf 'web-compilers: PASS raw-bytes=yes lifecycle=yes compiler-failure=yes atomic-recovery=yes\n'
