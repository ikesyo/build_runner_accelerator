#!/usr/bin/env python3
"""Derive which gated CI jobs a pull request's changed paths can affect.

Reads newline-separated paths on stdin and prints ``jobs=`` followed by a
comma-wrapped list of the gated job ids that must run (for example
``jobs=,integration-codegen,``; just ``jobs=,,`` when only the always-on
package jobs are needed). The scope is derived from the checked-out tree
itself (workflow lanes, script references, fixture references), never from a
hand-maintained copy of the layout, so it cannot drift from the workflow it
gates. Anything unrecognized or unmapped derives to every gated job:
selection must fail safe toward running everything, because a wrong skip
silently weakens the gate while a wrong run only costs runner time.

Derivation rules:
- Product code (rust/, lib/, bin/, tool/), root package files, the workflow
  and the composite actions can affect every job.
- A fixture change maps to the jobs whose lanes run scripts that reference
  the fixture, following fixture path-dependencies in reverse (a fixture
  that depends on the changed one is affected too).
- A script change maps to the jobs whose lanes run it, following script
  references in reverse (a suite that sources or imports the changed file
  is affected too). Shared harness files therefore fan out on their own.
- Scripts that prepare every integration job's environment, the compiled
  cache key helper, and this classifier always force a full run.
- Documentation, the Dart package tests and CI helper tests need only the
  always-on package jobs, as do the scripts and fixtures listed in the
  buckets below: PR CI never executes them (benchmarks, release and
  evaluation tools, fixture generators, and scripts exercised only through
  verify.sh or the always-on package jobs). check_ci.py asserts every
  script and fixture is accounted for exactly once across derivation and
  these buckets.
"""

from pathlib import Path
import re
import sys

import yaml

# Scripts whose change can alter every gated job's environment or verdict.
FULL_SCRIPTS = {
    'scripts/prepare_ci_pub_cache.py',
    '.github/scripts/compiled_cache_key.py',
    # The classifier derives scope from the PR's own tree, so a change to it
    # must never be allowed to narrow its own pull request's scope.
    '.github/scripts/classify_changes.py',
}

# Scripts PR CI never executes. Every other script must derive to at least
# one gated job; check_ci.py enforces the partition.
NO_CI_SCRIPTS = {
    'aot_prewarm.sh', 'benchmark_build_filter.py', 'benchmark_cold_aot.py',
    'benchmark_cold_build.py', 'benchmark_cold_startup.sh',
    'benchmark_cross_workspace_startup.sh', 'benchmark_current_baseline.sh',
    'benchmark_environment.py', 'benchmark_freezed.sh',
    'benchmark_frontend_regen.py', 'benchmark_json_serializable.sh',
    'benchmark_manifest_generator.sh', 'benchmark_matrix.sh',
    'benchmark_one_file.py', 'benchmark_optional_builder.sh',
    'benchmark_part_scanner.py', 'benchmark_plan_retention.py',
    'benchmark_resolver_cold_path.sh', 'benchmark_resolver_comparison.py',
    'benchmark_riverpod.sh', 'benchmark_shared_byte_store.py',
    'benchmark_workspace_scheduler.py', 'check_otel_trace.py',
    'compile_worker_kernel.sh', 'correctness_aot_background.sh',
    'correctness_aot_prewarm.sh', 'correctness_arbitrary_dependency_builder.sh',
    'correctness_current_json.sh', 'create_release_manifest.py',
    'diagnose_riverpod_resolver.py', 'evaluate_aot_matrix.sh',
    'generate_application_fixture.py', 'generate_json_serializable_fixture.sh',
    'measure_process.py', 'prepare_cycle_read_fixture.py',
    'prepare_resolver_digest_fixture.py', 'probe_fvm.py',
    'probe_worker_dependencies.py',
    'summarize_ci_timings.py', 'summarize_frontend_wall.py', 'verify.sh',
    'watch_smoke_current_json.sh',
}

# Scripts and fixtures exercised only by the always-on package jobs (or, for
# the large JSON fixtures, only by benchmarks), never by gated jobs.
FLOOR_ONLY_SCRIPTS = {
    'correctness_commit_recovery.py', 'correctness_commit_recovery.sh',
    'correctness_sdk.sh', 'correctness_shared_parts.sh',
    'verification_pool.sh', 'watch_smoke.sh',
}

NO_CI_FIXTURES = {
    'json_serializable_100_app',
    'json_serializable_500_app',
}

FULL_PREFIXES = (
    'rust/', 'lib/', 'bin/', 'tool/', '.github/workflows/', '.github/actions/',
)

FULL_FILES = {
    'pubspec.yaml', 'pubspec.lock', 'Cargo.toml', 'Cargo.lock',
    'analysis_options.yaml',
}

LIGHT_PREFIXES = (
    'docs/',
    'test/',
    '.github/scripts/test_',
)

LIGHT_FILES = {
    'renovate.json5',
}

LIGHT_SUFFIXES = (
    '.md',
)


def _lane_texts(job):
    for step in job.get('steps', []):
        for lane in step.get('parallel', [step]):
            if lane.get('run'):
                # Ignore full-line comments: a commented-out invocation
                # does not exercise anything.
                yield '\n'.join(
                    line for line in lane['run'].splitlines()
                    if not line.lstrip().startswith('#'))


class ScopeIndex:
    """Maps scripts and fixtures to the gated jobs that exercise them."""

    def __init__(self, repo):
        self.repo = Path(repo)
        workflow = yaml.safe_load(
            (self.repo / '.github/workflows/ci.yml').read_text())
        def needs_changes(job):
            needs = job.get('needs')
            needs = [needs] if isinstance(needs, str) else (needs or [])
            return 'changes' in needs

        self.gated_jobs = sorted(
            name for name, job in workflow['jobs'].items()
            if needs_changes(job))
        self.script_jobs = {}
        for name, job in workflow['jobs'].items():
            if name not in self.gated_jobs:
                continue
            for text in _lane_texts(job):
                for script in re.findall(r'scripts/([\w.-]+)', text):
                    self.script_jobs.setdefault(script, set()).add(name)
        scripts_dir = self.repo / 'scripts'
        self.script_texts = {
            path.name: path.read_text(errors='replace')
            for path in scripts_dir.iterdir() if path.is_file()}
        # Reverse script references: changing a file affects every script
        # that mentions it (by name, or by module for Python imports) and
        # every script that depends on those, transitively.
        self.script_dependents = {name: set() for name in self.script_texts}
        for name, text in self.script_texts.items():
            for other in self.script_texts:
                if other != name and (other in text or
                                      (other.endswith('.py') and
                                       re.search(rf'\b{re.escape(other[:-3])}'
                                                 rf'\b', text))):
                    self.script_dependents[other].add(name)
        fixtures_dir = self.repo / 'fixtures'
        self.fixtures = sorted(
            path.name for path in fixtures_dir.iterdir() if path.is_dir())
        # Fixture path-dependencies, reversed: changing a fixture affects
        # the fixtures that depend on it.
        self.fixture_dependents = {name: set() for name in self.fixtures}
        for name in self.fixtures:
            pubspec = fixtures_dir / name / 'pubspec.yaml'
            if not pubspec.is_file():
                continue
            for other in re.findall(r'path:\s*\.\./([\w-]+)',
                                    pubspec.read_text(errors='replace')):
                if other in self.fixture_dependents and other != name:
                    self.fixture_dependents[other].add(name)
        self.fixture_scripts = {}
        for fixture in self.fixtures:
            users = {name for name, text in self.script_texts.items()
                     if fixture in text}
            self.fixture_scripts[fixture] = users

    @staticmethod
    def _closure(start, dependents):
        seen = set(start)
        frontier = list(start)
        while frontier:
            for nxt in dependents.get(frontier.pop(), ()):
                if nxt not in seen:
                    seen.add(nxt)
                    frontier.append(nxt)
        return seen

    def jobs_for_script(self, name):
        jobs = set()
        for script in self._closure({name}, self.script_dependents):
            jobs.update(self.script_jobs.get(script, set()))
        return jobs

    def jobs_for_fixture(self, name):
        jobs = set()
        for fixture in self._closure({name}, self.fixture_dependents):
            for script in self.fixture_scripts.get(fixture, set()):
                jobs.update(self.jobs_for_script(script))
        return jobs

    def unaccounted(self):
        """Scripts and fixtures neither derived nor bucketed, for check_ci."""
        problems = []
        for name in sorted(self.script_texts):
            if name.startswith('test_') or name in NO_CI_SCRIPTS \
                    or name in FLOOR_ONLY_SCRIPTS:
                if self.jobs_for_script(name):
                    problems.append(
                        f'scripts/{name}: bucketed as no-CI but derives to '
                        'gated jobs')
                continue
            if f'scripts/{name}' in FULL_SCRIPTS:
                continue
            if not self.jobs_for_script(name):
                problems.append(
                    f'scripts/{name}: no gated job derives from it; wire '
                    'it, bucket it in classify_changes.py, or accept that '
                    'changes to it force a full run')
        for fixture in self.fixtures:
            if fixture in NO_CI_FIXTURES:
                if self.jobs_for_fixture(fixture):
                    problems.append(
                        f'fixtures/{fixture}: bucketed as no-CI but derives '
                        'to gated jobs')
                continue
            if not self.jobs_for_fixture(fixture):
                problems.append(
                    f'fixtures/{fixture}: no gated job derives from it')
        return problems


def is_light(path):
    if path in LIGHT_FILES:
        return True
    if path.startswith(LIGHT_PREFIXES):
        return True
    if path.startswith('.github/scripts/') and path.endswith('.py'):
        return True
    return path.endswith(LIGHT_SUFFIXES)


def derive_scope(index, paths):
    """Return the gated jobs the changed paths can affect, or None for all."""
    paths = [path.strip() for path in paths if path.strip()]
    if not paths:
        return None
    jobs = set()
    for path in paths:
        if path in FULL_SCRIPTS or path.startswith(FULL_PREFIXES) \
                or path in FULL_FILES:
            return None
        if is_light(path):
            continue
        if path.startswith('fixtures/'):
            fixture = path.split('/')[1]
            if fixture in NO_CI_FIXTURES:
                continue
            derived = index.jobs_for_fixture(fixture)
            if not derived:
                return None
            jobs.update(derived)
            continue
        if path.startswith('scripts/'):
            name = path.split('/')[1]
            if name.startswith('test_') or name in NO_CI_SCRIPTS \
                    or name in FLOOR_ONLY_SCRIPTS:
                continue
            derived = index.jobs_for_script(name)
            if not derived:
                return None
            jobs.update(derived)
            continue
        if path.startswith('.github/scripts/'):
            continue
        return None
    return jobs


def format_jobs(jobs):
    return 'jobs=,' + ','.join(sorted(jobs)) + ','


def main():
    # On any failure print nothing and exit nonzero: the workflow step
    # treats a missing or malformed result as a full run.
    repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
    index = ScopeIndex(repo)
    scope = derive_scope(index, sys.stdin.read().splitlines())
    print(format_jobs(index.gated_jobs if scope is None else scope))
    return 0


if __name__ == '__main__':
    sys.exit(main())
