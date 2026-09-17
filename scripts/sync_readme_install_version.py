#!/usr/bin/env python3
"""Synchronize the README installation version with pubspec.yaml."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SEMVER = r"\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
PUBSPEC_VERSION_PATTERN = re.compile(
    rf"(?m)^version:\s*({SEMVER})\s*(?:#.*)?$"
)
INSTALLATION_SECTION_PATTERN = re.compile(r"(?ms)^## Installation\s*\n.*?(?=^## |\Z)")


def read_package_version(pubspec_path: Path) -> str:
    contents = pubspec_path.read_text(encoding="utf-8")
    matches = PUBSPEC_VERSION_PATTERN.findall(contents)
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one SemVer version in {pubspec_path}, found {len(matches)}"
        )
    return matches[0]


def synchronize_installation_section(section: str, version: str) -> str:
    replacements = (
        (
            re.compile(r"(?m)(^The current package version is `)[^`\n]+(`\.)"),
            "installation summary",
        ),
        (
            re.compile(
                r"(?m)(^dart pub add dev:build_runner_accelerator:\^)[^\s`\n]+([ \t]*)$"
            ),
            "dart pub add command",
        ),
        (
            re.compile(
                r"(?m)^([ \t]+build_runner_accelerator:[ \t]+\^)[^\s#\n]+([ \t]*)$"
            ),
            "YAML dependency",
        ),
    )

    synchronized = section
    for pattern, description in replacements:
        synchronized, count = pattern.subn(
            lambda match: f"{match.group(1)}{version}{match.group(2)}",
            synchronized,
        )
        if count != 1:
            raise RuntimeError(
                f"expected exactly one {description} version in the README, found {count}"
            )
    return synchronized


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of writing when the README is out of date",
    )
    args = parser.parse_args()

    repository_root = Path(__file__).resolve().parents[1]
    pubspec_path = repository_root / "pubspec.yaml"
    readme_path = repository_root / "README.md"

    version = read_package_version(pubspec_path)
    readme = readme_path.read_text(encoding="utf-8")
    matches = list(INSTALLATION_SECTION_PATTERN.finditer(readme))
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one Installation section in {readme_path}, found {len(matches)}"
        )

    match = matches[0]
    section = match.group(0)
    synchronized_section = synchronize_installation_section(section, version)
    if synchronized_section == section:
        print(f"README installation version is already {version}.")
        return

    if args.check:
        raise SystemExit(
            f"README installation version is out of date; expected {version}."
        )

    synchronized_readme = (
        readme[: match.start()] + synchronized_section + readme[match.end() :]
    )
    readme_path.write_text(synchronized_readme, encoding="utf-8")
    print(f"Synchronized README installation version to {version}.")


if __name__ == "__main__":
    main()
