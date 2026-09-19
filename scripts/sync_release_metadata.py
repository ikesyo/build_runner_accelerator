#!/usr/bin/env python3
"""Synchronize release metadata and path-dependency fixture lockfiles."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from pathlib import Path


SEMVER = r"\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
PUBSPEC_VERSION_PATTERN = re.compile(
    rf"(?m)^version:\s*({SEMVER})\s*(?:#.*)?$"
)
INSTALLATION_SECTION_PATTERN = re.compile(r"(?ms)^## Installation\s*\n.*?(?=^## |\Z)")
YAML_PACKAGE_BLOCK_PATTERN = re.compile(
    r"(?ms)^  build_runner_accelerator:\n(?P<body>.*?)(?=^  \S|\Z)"
)
CARGO_PACKAGE_BLOCK_PATTERN = re.compile(
    r'(?ms)^\[\[package\]\]\n(?P<body>.*?)(?=^\[\[package\]\]|\Z)'
)


def read_package_version(pubspec_path: Path) -> str:
    contents = pubspec_path.read_text(encoding="utf-8")
    matches = PUBSPEC_VERSION_PATTERN.findall(contents)
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one SemVer version in {pubspec_path}, found {len(matches)}"
        )
    return matches[0]


def package_block(contents: str, path: Path) -> str:
    match = YAML_PACKAGE_BLOCK_PATTERN.search(contents)
    if match is None:
        raise RuntimeError(f"missing build_runner_accelerator entry in {path}")
    return match.group("body")


def is_accelerator_fixture(pubspec_path: Path) -> bool:
    contents = pubspec_path.read_text(encoding="utf-8")
    match = YAML_PACKAGE_BLOCK_PATTERN.search(contents)
    if match is None:
        return False
    return re.search(
        r"(?m)^\s+path:\s*[\"']?\.\./\.\.[\"']?\s*$", match.group("body")
    ) is not None


def accelerator_fixtures(repository_root: Path) -> list[Path]:
    fixtures_root = repository_root / "fixtures"
    # Only synchronize tracked lockfiles. Some verification-only fixtures
    # intentionally omit a lockfile and resolve dependencies in a temporary
    # workspace created by their verification script.
    fixtures = sorted(
        lockfile.parent
        for lockfile in fixtures_root.rglob("pubspec.lock")
        for pubspec in [lockfile.with_name("pubspec.yaml")]
        if pubspec.exists()
        if is_accelerator_fixture(pubspec)
    )
    if not fixtures:
        raise RuntimeError(f"no accelerator fixtures found under {fixtures_root}")
    return fixtures


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


def read_installation_section(readme_path: Path) -> tuple[str, re.Match[str]]:
    readme = readme_path.read_text(encoding="utf-8")
    matches = list(INSTALLATION_SECTION_PATTERN.finditer(readme))
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one Installation section in {readme_path}, found {len(matches)}"
        )
    return readme, matches[0]


def synchronize_readme(repository_root: Path, version: str, check: bool) -> None:
    readme_path = repository_root / "README.md"
    readme, match = read_installation_section(readme_path)
    section = match.group(0)
    synchronized_section = synchronize_installation_section(section, version)
    if synchronized_section == section:
        print(f"README installation version is already {version}.")
        return

    if check:
        raise RuntimeError(f"README installation version is out of date; expected {version}")

    synchronized_readme = (
        readme[: match.start()] + synchronized_section + readme[match.end() :]
    )
    readme_path.write_text(synchronized_readme, encoding="utf-8")
    print(f"Synchronized README installation version to {version}.")


def run_cargo_update(repository_root: Path) -> None:
    print("release metadata sync: updating Cargo.lock")
    subprocess.run(
        [
            "cargo",
            "update",
            "--manifest-path",
            str(repository_root / "rust/Cargo.toml"),
            "--workspace",
        ],
        cwd=repository_root,
        check=True,
    )


def read_cargo_lock_version(cargo_lock_path: Path) -> str:
    contents = cargo_lock_path.read_text(encoding="utf-8")
    matches = []
    for match in CARGO_PACKAGE_BLOCK_PATTERN.finditer(contents):
        body = match.group("body")
        if re.search(r'^name = "build_runner_accelerator"$', body, re.MULTILINE):
            matches.append(body)

    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one build_runner_accelerator package in {cargo_lock_path}, found {len(matches)}"
        )

    version_match = re.search(r'^version = "([^"]+)"$', matches[0], re.MULTILINE)
    if version_match is None:
        raise RuntimeError(f"missing build_runner_accelerator version in {cargo_lock_path}")
    return version_match.group(1)


def check_cargo_lock(repository_root: Path, version: str) -> None:
    cargo_lock_path = repository_root / "rust/Cargo.lock"
    actual = read_cargo_lock_version(cargo_lock_path)
    if actual != version:
        raise RuntimeError(
            f"{cargo_lock_path} has {actual}; expected {version}. Run cargo update --manifest-path rust/Cargo.toml --workspace"
        )
    print(f"Cargo.lock package version matches {version}.")


def read_fixture_lock_version(lock_path: Path) -> str:
    contents = lock_path.read_text(encoding="utf-8")
    body = package_block(contents, lock_path)
    matches = re.findall(r'(?m)^    version:\s*["\']?([^"\'\s]+)', body)
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one build_runner_accelerator version in {lock_path}, found {len(matches)}"
        )
    return matches[0]


def check_fixture_lockfiles(repository_root: Path, version: str) -> None:
    errors = []
    fixtures = accelerator_fixtures(repository_root)
    for fixture in fixtures:
        lock_path = fixture / "pubspec.lock"
        try:
            actual = read_fixture_lock_version(lock_path)
        except RuntimeError as error:
            errors.append(str(error))
            continue
        if actual != version:
            errors.append(f"{lock_path} has {actual}; expected {version}")

    if errors:
        details = "\n".join(f"- {error}" for error in errors)
        raise RuntimeError(
            f"fixture lockfiles are inconsistent with {version}; run dart pub get in each affected fixture:\n{details}"
        )
    print(f"fixture lockfile check: {len(fixtures)} fixture lockfiles match {version}")


def synchronize_fixture_lockfiles(repository_root: Path) -> None:
    dart_bin = os.environ.get("DART_BIN", "dart")
    fixtures = accelerator_fixtures(repository_root)
    for fixture in fixtures:
        print(f"release metadata sync: {fixture.relative_to(repository_root)}")
        subprocess.run(
            [dart_bin, "--suppress-analytics", "pub", "get"],
            cwd=fixture,
            check=True,
        )
    print(f"fixture lockfile sync: updated {len(fixtures)} fixture lockfiles")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate release metadata without modifying files or running dependency resolution",
    )
    args = parser.parse_args()

    repository_root = Path(__file__).resolve().parents[1]
    version = read_package_version(repository_root / "pubspec.yaml")

    if args.check:
        synchronize_readme(repository_root, version, check=True)
        check_cargo_lock(repository_root, version)
        check_fixture_lockfiles(repository_root, version)
        print(f"release metadata check: all metadata matches {version}")
        return

    run_cargo_update(repository_root)
    synchronize_readme(repository_root, version, check=False)
    synchronize_fixture_lockfiles(repository_root)
    print(f"release metadata sync: completed for {version}")


if __name__ == "__main__":
    main()
