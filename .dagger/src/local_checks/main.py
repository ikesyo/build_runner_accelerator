import asyncio
import re
import tomllib
from typing import Annotated

import dagger
from dagger import DefaultPath, Ignore, dag, function, object_type

# Do not import host SDKs, build state, credentials, or generated fixture output.
# Avoid **/build: rust/src/build is checked-in source.
Source = Annotated[
    dagger.Directory,
    DefaultPath("/"),
    Ignore(
        [
            ".git",
            ".agents",
            ".codex",
            ".aws",
            ".toolchains",
            ".downloads",
            ".pub-cache",
            ".dagger",
            "rust/target",
            "**/.dart_tool",
            "build",
            "fixtures/*/build",
            "fixtures/accelerator-build-correctness-*",
            "bench_*",
            "upload",
        ]
    ),
]


@object_type
class LocalChecks:
    async def _rust(self, source: dagger.Directory) -> dagger.Container:
        config = tomllib.loads(await source.file("rust-toolchain.toml").contents())
        version = config["toolchain"]["channel"]
        return (
            dag.container()
            .from_(f"rust:{version}-bookworm")
            .with_workdir("/workspace")
            .with_mounted_cache(
                "/usr/local/cargo/registry",
                dag.cache_volume("local-checks-cargo-registry"),
            )
            .with_mounted_cache(
                "/usr/local/cargo/git", dag.cache_volume("local-checks-cargo-git")
            )
        )

    async def _frontend(self, source: dagger.Directory) -> dagger.Container:
        # Keep target in an immutable container snapshot, not a mutable shared
        # cache: parallel callers cannot overwrite each other's executables.
        return (
            (await self._rust(source))
            .with_directory(
                "/workspace",
                source.filter(
                    include=[
                        "rust/**",
                        "rust-toolchain.toml",
                        "test/data/cli_contract.json",
                    ]
                ),
            )
            .with_exec(
                ["cargo", "build", "--locked", "--manifest-path", "rust/Cargo.toml"]
            )
        )

    async def _workspace(self, source: dagger.Directory) -> dagger.Container:
        versions = await source.file(".github/worker-toolchain.env").contents()
        match = re.search(
            r"^DART_WORKER_SDK_VERSION=([0-9.]+)$", versions, re.MULTILINE
        )
        if match is None:
            raise ValueError("DART_WORKER_SDK_VERSION is missing")
        sdk = dag.container().from_(f"dart:{match[1]}").directory("/usr/lib/dart")
        return (
            (await self._rust(source))
            .with_exec(["apt-get", "update"])
            .with_exec(
                [
                    "apt-get",
                    "install",
                    "-y",
                    "--no-install-recommends",
                    "python3",
                    "ripgrep",
                    "time",
                    "util-linux",
                    "procps",
                ]
            )
            .with_directory("/usr/lib/dart", sdk)
            .with_env_variable(
                "PATH", "/usr/lib/dart/bin:/usr/local/cargo/bin:$PATH", expand=True
            )
            .with_env_variable("DART_BIN", "/usr/lib/dart/bin/dart")
            .with_env_variable("PUB_CACHE", "/pub-cache")
            .with_env_variable(
                "BUILD_RUNNER_ACCELERATOR_BIN",
                "/workspace/rust/target/debug/build_runner_accelerator",
            )
            .with_mounted_cache("/pub-cache", dag.cache_volume("local-checks-pub"))
            # Resolve root dependencies before adding frequently changed sources.
            .with_directory(
                "/workspace", source.filter(include=["pubspec.yaml", "pubspec.lock"])
            )
            .with_exec(
                ["dart", "--suppress-analytics", "pub", "get", "--enforce-lockfile"]
            )
            .with_directory(
                "/workspace/rust/target",
                (await self._frontend(source)).directory("/workspace/rust/target"),
            )
            .with_directory("/workspace", source)
        )

    @function
    async def rust_unit(self, source: Source, run_id: str = "") -> str:
        """Run locked Rust unit tests. Change run-id to execute again with warm dependencies."""
        return await (
            (await self._frontend(source))
            .with_env_variable("CHECK_RUN_ID", run_id)
            .with_exec(
                ["cargo", "test", "--locked", "--manifest-path", "rust/Cargo.toml"]
            )
            .stdout()
        )

    @function
    async def dart_unit(self, source: Source, run_id: str = "") -> str:
        """Run Dart unit tests using the source compiler, matching CI."""
        return await (
            (await self._workspace(source))
            .with_env_variable("CHECK_RUN_ID", run_id)
            .with_exec(["dart", "test", "--compiler=source"])
            .stdout()
        )

    @function
    async def check(self, source: Source, run_id: str = "") -> str:
        """Run format, analysis/lint and both unit suites in two isolated lanes."""

        async def rust_checks() -> str:
            return await (
                (await self._frontend(source))
                .with_env_variable("CHECK_RUN_ID", run_id)
                .with_exec(
                    [
                        "cargo",
                        "fmt",
                        "--all",
                        "--manifest-path",
                        "rust/Cargo.toml",
                        "--",
                        "--check",
                    ]
                )
                .with_exec(
                    [
                        "cargo",
                        "clippy",
                        "--locked",
                        "--manifest-path",
                        "rust/Cargo.toml",
                        "--all-targets",
                        "--all-features",
                        "--",
                        "-D",
                        "warnings",
                    ]
                )
                .with_exec(
                    ["cargo", "test", "--locked", "--manifest-path", "rust/Cargo.toml"]
                )
                .stdout()
            )

        async def dart_checks() -> str:
            return await (
                (await self._workspace(source))
                .with_env_variable("CHECK_RUN_ID", run_id)
                .with_exec(
                    [
                        "dart",
                        "format",
                        "--output=none",
                        "--set-exit-if-changed",
                        "lib",
                        "bin",
                        "test",
                        "tool",
                    ]
                )
                .with_exec(
                    ["dart", "analyze", "--fatal-infos", "lib", "bin", "test", "tool"]
                )
                .with_exec(["dart", "test", "--compiler=source"])
                .stdout()
            )

        async with asyncio.TaskGroup() as tasks:
            rust = tasks.create_task(rust_checks())
            dart = tasks.create_task(dart_checks())
        return f"Rust:\n{rust.result()}\nDart:\n{dart.result()}"

    @function
    async def verify(
        self,
        source: Source,
        level: str = "quick",
        suites: str = "all",
        arbitrary_builder: bool = False,
        run_id: str = "",
    ) -> str:
        """Run existing correctness scripts, preserving ordered state transitions."""
        if level not in {"quick", "full"}:
            raise ValueError("level must be quick or full")
        return await (
            (await self._workspace(source))
            .with_env_variable("CHECK_RUN_ID", run_id)
            .with_env_variable("VERIFY_LEVEL", level)
            .with_env_variable("VERIFY_FULL_SUITES", suites)
            .with_env_variable(
                "VERIFY_ARBITRARY_BUILDER", "1" if arbitrary_builder else "0"
            )
            .with_exec(["bash", "scripts/verify.sh"])
            .stdout()
        )
