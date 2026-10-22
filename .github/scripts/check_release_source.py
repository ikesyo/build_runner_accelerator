"""Fail closed unless tag, checkout, workflow and successful correctness CI agree."""
import argparse
import json
import os
import re
import subprocess
import time
from urllib.parse import quote

SUBPROCESS_TIMEOUT = 120


def validate_identity(tag, source, tag_sha, workflow_ref, workflow_sha, *, dry_run=False):
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', tag):
        raise ValueError('invalid release tag')
    if dry_run:
        if workflow_sha != source:
            raise ValueError('dry-run source_ref must match the workflow commit')
        return
    if source != tag_sha:
        raise ValueError('source_ref does not resolve to the release tag commit')
    # The reusable pub publisher checks out the caller ref, not source_ref.
    if workflow_ref != f'refs/tags/{tag}' or workflow_sha != source:
        raise ValueError('run release.yml at the release tag (--ref TAG); pub.dev uses the caller ref')


def validate_requested_source(source, requested_sha):
    if requested_sha != source:
        raise ValueError('source_ref must resolve to the immutable workflow commit')


def successful_ci(runs, sha):
    return next((run for run in runs if run['head_sha'] == sha
                 and run['event'] in ('push', 'workflow_dispatch')
                 and run['status'] == 'completed'
                 and run['conclusion'] == 'success'), None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity-only', action='store_true')
    args = parser.parse_args()
    def git(*args):
        return subprocess.check_output(['git', *args], text=True,
                                       timeout=SUBPROCESS_TIMEOUT).strip()
    tag = os.environ['RELEASE_TAG']
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', tag):
        raise ValueError('invalid release tag')
    source = git('rev-parse', 'HEAD')
    requested_ref = os.environ.get('SOURCE_REF', '')
    if requested_ref:
        requested_sha = subprocess.check_output([
            'gh', 'api', f'repos/{os.environ["GITHUB_REPOSITORY"]}/commits/{quote(requested_ref, safe="")}',
            '--jq', '.sha'], text=True, timeout=SUBPROCESS_TIMEOUT).strip()
        validate_requested_source(source, requested_sha)
    dry_run = os.environ.get('RELEASE_DRY_RUN') == 'true'
    tag_sha = None
    if not dry_run:
        subprocess.run(['git', 'fetch', '--no-tags', 'origin',
                        f'refs/tags/{tag}:refs/tags/{tag}'], check=True,
                       timeout=SUBPROCESS_TIMEOUT)
        tag_sha = git('rev-parse', f'refs/tags/{tag}^{{commit}}')
    validate_identity(tag, source, tag_sha, os.environ['GITHUB_REF'],
                      os.environ['GITHUB_SHA'], dry_run=dry_run)
    evidence = {'dry_run': dry_run, 'source_commit': source, 'tag': tag}
    if not args.identity_only:
        deadline = time.monotonic() + int(os.environ.get('RELEASE_CI_WAIT_SECONDS', '0'))
        while True:
            pages = json.loads(subprocess.check_output([
                'gh', 'api', '--paginate', '--slurp',
                f'repos/{os.environ["GITHUB_REPOSITORY"]}/actions/workflows/ci.yml/runs?head_sha={source}&per_page=100'
            ], text=True, timeout=SUBPROCESS_TIMEOUT))
            runs = [run for page in pages for run in page['workflow_runs']]
            run = successful_ci(runs, source)
            if run:
                break
            relevant = [run for run in runs if run['head_sha'] == source
                        and run['event'] in ('push', 'workflow_dispatch')]
            if time.monotonic() >= deadline or (relevant and all(
                    run['status'] == 'completed' for run in relevant)):
                raise ValueError('no successful push/dispatch CI for this exact commit; run CI at the source ref, then retry Release')
            print('Waiting for exact-commit correctness CI (no suite is rerun)...', flush=True)
            time.sleep(min(15, max(0, deadline - time.monotonic())))
        evidence.update(correctness_run=run['html_url'], correctness_run_id=run['id'],
                        correctness_run_attempt=run.get('run_attempt'))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write(f'sha={source}\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
        stream.write(f'Release source: `{source}`; correctness: {evidence.get("correctness_run", "checked before signing")}\n')
    with open('release-source.json', 'w') as stream:
        json.dump(evidence, stream, indent=2)


if __name__ == '__main__':
    main()
