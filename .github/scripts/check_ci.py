#!/usr/bin/env python3
"""Fail CI when the PR runner budget or per-job parallelism grows unnoticed.

Requires PyYAML. Matrix expressions must declare finite JSON alternatives so
both the PR and main/scheduled expansion can be audited without executing code.
Also fails when a correctness suite gains a case group that no CI lane assigns,
or a lane assigns a group the suite does not define: group registries live in
the suite sources, so this reads them with the AST instead of executing code.
"""

import ast
import json
from pathlib import Path
import re
import subprocess

import yaml


REPO = Path(__file__).resolve().parents[2]
CI_BUDGET = 16
RESERVED_JOBS = 4
RUNNER_LIMIT = 20


def check_composite_anchors(source, path):
    """The Actions composite-action reader rejects YAML anchors and aliases."""
    for event in yaml.parse(source):
        if getattr(event, 'anchor', None) is not None:
            raise ValueError(f'{path}: composite actions do not support YAML anchors or aliases')


def matrix_size(matrix, event):
    if not matrix:
        return 1
    if set(matrix) == {'include'}:
        include = matrix['include']
        if isinstance(include, list):
            return len(include)
        # Accept only the finite event-dependent expression used by native-build.
        match = re.fullmatch(
            r"\$\{\{ fromJSON\(github.event_name == 'pull_request' && '(\[.*?\])' \|\| '(\[.*?\])'\) \}\}",
            include, re.S)
        if not match:
            raise ValueError('unrecognized matrix expression; declare finite JSON alternatives')
        value = match.group(1 if event == 'pull_request' else 2)
        return len(json.loads(value))
    raise ValueError('new matrix shape needs a runner-budget review')


def _dict_keys(node):
    return [key.value for key in node.keys
            if isinstance(key, ast.Constant) and isinstance(key.value, str)]


def _string_items(node):
    return [item.value for item in node.elts
            if isinstance(item, ast.Constant) and isinstance(item.value, str)]


def _resolve_names(value, symbols, seen=frozenset()):
    """Collect literal group names, following starred references to other
    module-level registries (a suite may compose GROUPS from sub-registries)."""
    names = set()
    if isinstance(value, ast.Dict):
        names.update(_dict_keys(value))
        for key, item in zip(value.keys, value.values):
            if key is not None:
                continue
            if isinstance(item, ast.Name) and item.id in symbols \
                    and item.id not in seen:
                names.update(_resolve_names(symbols[item.id], symbols,
                                            seen | {item.id}))
            else:
                raise ValueError('unsupported ** entry in a group registry; '
                                 'check_ci.py cannot resolve it')
    elif isinstance(value, (ast.Tuple, ast.List)):
        for item in value.elts:
            if isinstance(item, ast.Constant) and isinstance(item.value, str):
                names.add(item.value)
            elif isinstance(item, ast.Starred) and isinstance(item.value, ast.Name):
                name = item.value.id
                if name in symbols and name not in seen:
                    names.update(_resolve_names(symbols[name], symbols, seen | {name}))
            elif isinstance(item, ast.Name) and item.id in symbols \
                    and item.id not in seen:
                names.update(_resolve_names(symbols[item.id], symbols,
                                            seen | {item.id}))
    return names


def registry_names(path, kind, target):
    """Read a suite's valid group names from its source without executing it."""
    tree = ast.parse(Path(path).read_text())
    names = set()
    symbols = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    symbols[t.id] = node.value
    if kind == 'module':
        if target not in symbols:
            raise ValueError(f'{path}: no {target} registry found; update check_ci.py')
        names = _resolve_names(symbols[target], symbols)
    elif kind == 'local':
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id == target for t in node.targets):
                names.update(_resolve_names(node.value, symbols))
    elif kind == 'function':
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef) and node.name == target:
                for sub in ast.walk(node):
                    if isinstance(sub, (ast.Assign, ast.Return)):
                        names.update(_resolve_names(sub.value, symbols))
    else:
        raise ValueError(f'unknown registry kind: {kind}')
    if not names:
        raise ValueError(f'{path}: no {target} registry found; update check_ci.py')
    return names


# (suite name, registry source, CI variable, registry location kind, target name)
GROUP_SUITES = (
    ('build-filter', 'scripts/correctness_build_filter.py',
     'BUILD_FILTER_CASE_GROUP', 'module', 'GROUPS'),
    ('settings', 'scripts/correctness_settings.py',
     'SETTINGS_CASE_GROUP', 'module', 'GROUPS'),
    ('output-policies', 'scripts/correctness_output_policies.py',
     'OUTPUT_POLICY_CASE_GROUP', 'local', 'groups'),
    ('nested-packages', 'scripts/correctness_nested_packages.py',
     'NESTED_PACKAGE_CASE_GROUP', 'function', 'case_groups'),
)

# Shell suites select cases with CASE_FILTER instead of group variables. Their
# full case lists also run under verify.sh, so CI only needs its filter names
# to be ones the script actually recognizes.
CASE_FILTER_SUITES = (
    ('scripts/correctness_json_serializable.sh',),
    ('scripts/correctness_drift_analyzer.sh',),
)


def _strip_comment_lines(text):
    """Drop full-line shell comments so a commented-out command cannot
    masquerade as an assignment or an invocation."""
    return '\n'.join(line for line in text.splitlines()
                     if not line.lstrip().startswith('#'))


def lane_run_texts(workflow):
    for job in workflow['jobs'].values():
        for step in job.get('steps', []):
            for lane in step.get('parallel', [step]):
                if lane.get('run'):
                    yield _strip_comment_lines(lane['run'])


def assigned_values(texts, variable):
    values = []
    for text in texts:
        for match in re.findall(rf'{re.escape(variable)}=([\w,.-]+)', text):
            values.extend(value for value in match.split(',') if value)
    return values


def dependency_window_registry(path):
    """The (native runner, analyzer) pair each dependency-window case needs."""
    tree = ast.parse(Path(path).read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == 'CASES' for t in node.targets):
            return {(entry.elts[0].value, entry.elts[1].value)
                    for entry in node.value.elts}
    raise ValueError(f'{path}: no CASES registry found; update check_ci.py')


def check_group_coverage(workflow, repo):
    """Every registered group must be assigned by exactly one CI lane."""
    texts = list(lane_run_texts(workflow))
    for name, script, variable, kind, target in GROUP_SUITES:
        registry = registry_names(repo / script, kind, target)
        assigned = assigned_values(texts, variable)
        if name == 'nested-packages':
            # The recovery-actions group is split across lanes by its
            # NESTED_PACKAGE_RECOVERY_CASE sub-selection, so count
            # (group, sub-case) units instead of raw group assignments.
            recovery = registry_names(repo / script, 'function', 'recovery_cases')
            units = [('group', group) for group in assigned
                     if group != 'recovery-actions']
            for text in texts:
                groups = assigned_values([text], variable)
                if 'recovery-actions' not in groups:
                    continue
                cases = assigned_values([text], 'NESTED_PACKAGE_RECOVERY_CASE')
                units.extend(('recovery', case)
                             for case in cases or sorted(recovery))
            expected = [('group', group) for group in registry
                        if group != 'recovery-actions']
            expected.extend(('recovery', case) for case in recovery)
            if sorted(units) != sorted(expected):
                raise ValueError(
                    f'{name}: CI assignment drifted from {script}: '
                    f'units={sorted(units)} expected={sorted(expected)}')
            continue
        if sorted(assigned) != sorted(registry):
            raise ValueError(
                f'{name}: CI assignment drifted from {script}: '
                f'unassigned={sorted(registry - set(assigned))} '
                f'unknown={sorted(set(assigned) - registry)} '
                f'duplicated={sorted(v for v in set(assigned) if assigned.count(v) > 1)}')
    registry = dependency_window_registry(
        repo / 'scripts/correctness_dependency_window.py')
    assigned = set()
    for text in texts:
        flat = re.sub(r'\\\n', ' ', text)
        assigned.update(re.findall(
            r'correctness_dependency_window\.py.*?--runner\s+([\d.]+)'
            r'\s+--analyzer\s+([\d.]+)', flat, re.S))
    if assigned != registry:
        raise ValueError(
            f'dependency-window: CI assignment drifted: '
            f'unassigned={sorted(registry - assigned)} '
            f'unknown={sorted(assigned - registry)}')
    for (script,) in CASE_FILTER_SUITES:
        source = (repo / script).read_text()
        recognized = set(re.findall(r'"\$case_filter" == ([\w-]+)', source))
        case_match = re.search(r'case "\$case_filter" in\s*\n\s*([\w\s|-]+)\)', source)
        if case_match:
            recognized.update(name.strip() for name in case_match.group(1).split('|'))
        array_match = re.search(r'known_case_names=\((.*?)\)', source, re.S)
        if array_match:
            recognized.update(re.findall(r'[\w-]+', array_match.group(1)))
        used = set()
        for text in texts:
            for match in re.findall(
                    rf'CASE_FILTER=([\w,.-]+)\s+bash\s+{re.escape(script)}', text):
                used.update(value for value in match.split(',') if value)
        if not used <= recognized:
            raise ValueError(
                f'{script}: CI uses unrecognized CASE_FILTER values: '
                f'{sorted(used - recognized)}')
    print('CI group coverage: every registered group is assigned exactly once')


def check_scope_accounting(repo):
    """Every script and fixture must be accounted for by the classifier."""
    from classify_changes import ScopeIndex
    problems = ScopeIndex(repo).unaccounted()
    if problems:
        raise ValueError('change classification accounting: '
                         + '; '.join(problems))
    print('CI change classification: every script and fixture is accounted for')


def check(workflow):
    pr_jobs = 0
    full_jobs = 0
    classifier_jobs = 0
    for name, job in workflow['jobs'].items():
        matrix = job.get('strategy', {}).get('matrix')
        if name == 'changes':
            # The change classifier is a seconds-long control job, not a test
            # job: it is excluded from the runner budget but must stay a
            # leaf so a classification failure cannot cascade.
            classifier_jobs += 1
            if 'needs' in job:
                raise ValueError('changes: the classification job must not '
                                 'depend on other jobs')
        else:
            pr_jobs += matrix_size(matrix, 'pull_request')
            full_jobs += matrix_size(matrix, 'push')
        for step in job['steps']:
            lanes = step.get('parallel', [step])
            if not 1 <= len(lanes) <= 4:
                raise ValueError(f'{name}: keep parallel groups within four lanes')
            for lane in lanes:
                if 'parallel' in lane:
                    raise ValueError(f'{name}: nested parallel groups are not supported')
                if 'run' in lane:
                    # Check shell syntax without interpreting GitHub expressions.
                    script = re.sub(r'\$\{\{.*?\}\}', 'ci-value', lane['run'], flags=re.S)
                    subprocess.run(['bash', '-n'], input=script, text=True, check=True)
    if pr_jobs > CI_BUDGET or pr_jobs + RESERVED_JOBS > RUNNER_LIMIT:
        raise ValueError(f'PR expands to {pr_jobs} CI jobs + {RESERVED_JOBS} reserved; '
                         f'budget is {CI_BUDGET} + {RESERVED_JOBS} <= {RUNNER_LIMIT}')
    jobs = workflow['jobs']
    if 'dart-package' in jobs and 'needs' in jobs['dart-package']:
        raise ValueError('dart-package: the always-on package jobs must not be '
                         'gated by change classification')
    gated = set()
    for name, job in jobs.items():
        needs = job.get('needs')
        needs = [needs] if isinstance(needs, str) else (needs or [])
        if 'changes' not in needs:
            continue
        gated.add(name)
        condition = str(job.get('if', ''))
        if 'needs.changes.outputs.jobs' not in condition \
                or f',{name},' not in condition:
            raise ValueError(f'{name}: jobs gated by the classifier must test '
                             'their own token in needs.changes.outputs.jobs')
    if 'changes' in jobs and gated:
        # The classification step must default to the full gated set, so a
        # failed lookup runs everything instead of skipping it.
        texts = '\n'.join(lane_run_texts({'jobs': {'changes': jobs['changes']}}))
        match = re.search(r"jobs='(,[a-z0-9,-]+,)'", texts)
        if not match or set(match.group(1).split(',')) - {''} != gated:
            raise ValueError('changes: the default jobs value must list '
                             'every gated job')
    print(f'CI runner budget: PR={pr_jobs}, main/schedule={full_jobs}, '
          f'reserved={RESERVED_JOBS}, limit={RUNNER_LIMIT}'
          + (f', plus {classifier_jobs} classifier' if classifier_jobs else ''))


if __name__ == '__main__':
    workflow = yaml.safe_load((REPO / '.github/workflows/ci.yml').read_text())
    check(workflow)
    check_group_coverage(workflow, REPO)
    check_scope_accounting(REPO)
    for path in (REPO / '.github/actions').glob('*/action.y*ml'):
        source = path.read_text()
        if yaml.safe_load(source).get('runs', {}).get('using') == 'composite':
            check_composite_anchors(source, path)
