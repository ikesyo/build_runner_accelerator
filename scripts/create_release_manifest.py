#!/usr/bin/env python3
"""Create the signed-release input manifest for frontend archives."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tarfile
import zipfile
from pathlib import Path

EXPECTED_TARGETS = {
    "macos-arm64",
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


def validate_archive(path: Path, target: str, version: str, source_commit: str) -> None:
    expected = {'VERSION': version, 'SOURCE_COMMIT': source_commit}
    if path.name.endswith('.zip'):
        with zipfile.ZipFile(path) as archive:
            for name, value in expected.items():
                member = archive.getinfo(f'{target}/{name}')
                if member.file_size > 256 or archive.read(member).decode().strip() != value:
                    raise ValueError(f'{path.name}: {name} mismatch')
            archive.getinfo(f'{target}/build_runner_accelerator.exe')
    else:
        with tarfile.open(path, 'r:gz') as archive:
            for name, value in expected.items():
                member = archive.getmember(f'{target}/{name}')
                if not member.isfile() or member.size > 256:
                    raise ValueError(f'{path.name}: invalid {name}')
                if archive.extractfile(member).read().decode().strip() != value:
                    raise ValueError(f'{path.name}: {name} mismatch')
            if not archive.getmember(f'{target}/build_runner_accelerator').isfile():
                raise ValueError(f'{path.name}: invalid binary')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--protocol-major", type=int, default=1)
    parser.add_argument("--artifacts-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if not re.fullmatch(r'[0-9a-f]{40}', args.source_commit):
        raise SystemExit('source commit must be a full Git SHA')

    artifacts = []
    for path in sorted(args.artifacts_dir.iterdir()):
        if not path.is_file() or not (path.name.endswith(".tar.gz") or path.name.endswith(".zip")):
            continue
        target = artifact_target(path)
        suffix = '.zip' if target.startswith('windows-') else '.tar.gz'
        if not path.name.endswith(suffix):
            raise SystemExit(f'invalid archive format for {target}: {path.name}')
        validate_archive(path, target, args.version, args.source_commit)
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
        "source_commit": args.source_commit,
        "package_version": args.version,
        "protocol_major": args.protocol_major,
        "artifacts": artifacts,
    }
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
