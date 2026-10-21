#!/usr/bin/env bash
# Published web compiler fixture setup; no modifications to hosted package sources.
web_prepare() {
  export BUILD_MAX_WORKERS_PER_TASK=1
  worker_ensure_frontend
  mkdir -p "$workspace_root/fixtures"
  worker_attach "$workspace_root"
  local directory
  local fixture=${WEB_COMPILERS_FIXTURE:-build_web_compilers_app}
  for directory in "$stock_dir" "$rust_dir"; do
    mkdir -p "$directory"
    cp "$repo_root/fixtures/$fixture/"{pubspec.yaml,pubspec.lock,build.yaml} "$directory/"
    cp -R "$repo_root/fixtures/$fixture/"{lib,web} "$directory/"
    verification_run_pub_get "$directory" "web-compilers/pub/$(basename "$directory")" \
      "$dart_bin" "$pub_cache" "${pub_get_args[@]}"
  done
}
web_stock() {
  verification_run_stock_build "$stock_dir" "web-compilers/stock/$1" \
    "$temporary_dir/$1.stock.log" "$dart_bin" "$pub_cache" build
}
web_native() {
  VERIFY_COMMAND_LOG="$temporary_dir/$1.native.log" VERIFY_WORKSPACE="$rust_dir" \
    worker_run_frontend build --root "$rust_dir" --dart "$dart_bin" --jobs 1
}
web_compare() {
  PYTHONDONTWRITEBYTECODE=1 python3 "$script_dir/compare_web_compilers.py" "$stock_dir" "$rust_dir" "${WEB_COMPILERS_MODE:-dart2js}"
}
web_pair() { web_stock "$1"; web_native "$1"; web_compare; }
web_atomic() {
  python3 - "$rust_dir" "$temporary_dir/atomic.json" "$1" <<'PY'
import json
import sys
from pathlib import Path
root, saved, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
paths = [root / '.dart_tool/build_runner_accelerator/graph-v3.bin']
paths += [p for p in (root / '.dart_tool/build_runner_accelerator/cache').rglob('*') if p.is_file()]
snapshot = {str(p.relative_to(root)): p.read_bytes().hex() for p in paths}
if mode == 'save':
    saved.write_text(json.dumps(snapshot))
else:
    assert snapshot == json.loads(saved.read_text()), 'failed build changed published cache/graph'
PY
}
