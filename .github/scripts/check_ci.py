#!/usr/bin/env python3
"""Fail CI when the PR runner budget or per-job parallelism grows unnoticed.

Requires PyYAML. Matrix expressions must declare finite JSON alternatives so
both the PR and main/scheduled expansion can be audited without executing code.
"""

import itertools
import json
from pathlib import Path
import re
import subprocess

import yaml


REPO = Path(__file__).resolve().parents[2]
CI_BUDGET = 16
RESERVED_JOBS = 4
RUNNER_LIMIT = 20


def matrix_sizes(matrix):
    if not matrix:
        return {1}
    if set(matrix) == {'include'}:
        include = matrix['include']
        if isinstance(include, list):
            return {len(include)}
        # Accept only the finite event-dependent expression used by native-build.
        match = re.fullmatch(
            r"\$\{\{ fromJSON\(github.event_name == 'pull_request' && '(\[.*?\])' \|\| '(\[.*?\])'\) \}\}",
            include, re.S)
        if not match:
            raise ValueError('unrecognized matrix expression; declare finite JSON alternatives')
        return {len(json.loads(value)) for value in match.groups()}
    raise ValueError('new matrix shape needs a runner-budget review')


def check(workflow):
    totals = {0}
    for name, job in workflow['jobs'].items():
        sizes = matrix_sizes(job.get('strategy', {}).get('matrix'))
        totals = {total + size for total, size in itertools.product(totals, sizes)}
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
    # PR selects the smaller native target set; main/schedule retain all five.
    pr_jobs = min(totals)
    if pr_jobs > CI_BUDGET or pr_jobs + RESERVED_JOBS > RUNNER_LIMIT:
        raise ValueError(f'PR expands to {pr_jobs} CI jobs + {RESERVED_JOBS} reserved; '
                         f'budget is {CI_BUDGET} + {RESERVED_JOBS} <= {RUNNER_LIMIT}')
    print(f'CI runner budget: PR={pr_jobs}, main/schedule={max(totals)}, '
          f'reserved={RESERVED_JOBS}, limit={RUNNER_LIMIT}')


if __name__ == '__main__':
    check(yaml.safe_load((REPO / '.github/workflows/ci.yml').read_text()))
