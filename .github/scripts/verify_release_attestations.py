"""Fail closed on release provenance or downloaded-byte mismatches (gh >=2.80.0)."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

SUBJECTS = tuple(
    f'build_runner_accelerator-{target}.{extension}'
    for target, extension in (
        ('macos-arm64', 'tar.gz'), ('linux-x64', 'tar.gz'),
        ('linux-arm64', 'tar.gz'), ('windows-x64', 'zip'),
        ('windows-arm64', 'zip'))
) + ('release-manifest.json',)


def verify(dist, repo, source_commit, source_ref, results, expected_dist=None):
    results.mkdir(parents=True, exist_ok=True)
    evidence = dict(result='failed', repository=repo, source_commit=source_commit,
                    source_ref=source_ref, subjects=[])
    try:
        if not re.fullmatch(r'[0-9a-f]{40}', source_commit):
            raise ValueError('expected a full release commit SHA')
        version = subprocess.check_output(['gh', '--version'], text=True, timeout=30)
        evidence['gh_version'] = version.strip()
        match = re.search(r'gh version (\d+)\.(\d+)\.(\d+)', version)
        if not match or tuple(map(int, match.groups())) < (2, 80, 0):
            raise ValueError('GitHub CLI >=2.80.0 is required for source/signer digest policy')
        identity = f'https://github.com/{repo}/.github/workflows/release.yml@{source_ref}'
        for name in SUBJECTS:
            path = dist / name
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            item = dict(filename=name, sha256=digest, result='failed')
            evidence['subjects'].append(item)
            if expected_dist is not None:
                expected = hashlib.sha256((expected_dist / name).read_bytes()).hexdigest()
                if digest != expected:
                    raise ValueError(f'{name}: downloaded SHA-256 {digest} != attested local SHA-256 {expected}')
            command = [
                'gh', 'attestation', 'verify', str(path), '--repo', repo,
                '--cert-identity', identity,
                '--cert-oidc-issuer', 'https://token.actions.githubusercontent.com',
                '--signer-digest', source_commit, '--source-digest', source_commit,
                '--source-ref', source_ref, '--deny-self-hosted-runners',
                '--predicate-type', 'https://slsa.dev/provenance/v1', '--format', 'json',
            ]
            item['command'] = command
            print(f'Verifying {name} ({digest}), source/signer {source_commit}, {identity}', flush=True)
            # Keep stdout and stderr, including gh's policy/network diagnostics.
            # A nonzero exit or timeout must block publication.
            with (results / f'{name}.json').open('w') as output, \
                 (results / f'{name}.log').open('w') as errors:
                subprocess.run(command, stdout=output, stderr=errors, check=True, timeout=180)
            item['result'] = 'passed'
        evidence['result'] = 'passed'
    except Exception as error:
        evidence['error'] = str(error)
        raise
    finally:
        (results / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--source-ref', required=True)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--expected-dist', type=Path)
    args = parser.parse_args()
    verify(args.dist, args.repo, args.source_commit, args.source_ref,
           args.results, args.expected_dist)


if __name__ == '__main__':
    main()
