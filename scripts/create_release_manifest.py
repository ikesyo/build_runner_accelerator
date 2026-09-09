#!/usr/bin/env python3
"""Create the signed-release input manifest for frontend archives."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

EXPECTED_TARGETS = {
    "macos-arm64",
    "macos-x64",
    "linux-x64",
    "linux-arm64",
    "windows-x64",
    "windows-arm64",
}


def artifact_target(path: Path) -> str:
    name = path.name
    prefix = "build_runner_accelerator-"
    for suffix in (".tar.gz", ".zip"):
        if name.startswith(prefix) and name.endswith(suffix):
            return name[len(prefix) : -len(suffix)]
    raise ValueError(f"unexpected artifact filename: {path.name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--protocol-major", type=int, default=1)
    parser.add_argument("--artifacts-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    artifacts = []
    for path in sorted(args.artifacts_dir.iterdir()):
        if not path.is_file() or not (path.name.endswith(".tar.gz") or path.name.endswith(".zip")):
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        artifacts.append(
            {
                "target": artifact_target(path),
                "filename": path.name,
                "size": path.stat().st_size,
                "sha256": digest,
            }
        )

    if not artifacts:
        raise SystemExit("no release artifacts found")

    targets = {artifact["target"] for artifact in artifacts}
    if len(targets) != len(artifacts):
        raise SystemExit("invalid release artifact matrix (duplicate target)")
    missing = EXPECTED_TARGETS - targets
    unexpected = targets - EXPECTED_TARGETS
    if missing or unexpected:
        details = []
        if missing:
            details.append(f"missing targets: {sorted(missing)}")
        if unexpected:
            details.append(f"unexpected targets: {sorted(unexpected)}")
        raise SystemExit("invalid release artifact matrix (" + "; ".join(details) + ")")

    manifest = {
        "schema_version": 1,
        "package_version": args.version,
        "protocol_major": args.protocol_major,
        "artifacts": artifacts,
    }
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
