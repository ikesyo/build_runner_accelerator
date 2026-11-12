from pathlib import Path
import os
import subprocess
import tempfile
import unittest

import yaml

REPO = Path(__file__).resolve().parents[2]


class CiCachePolicyTest(unittest.TestCase):
    def test_restore_discards_only_transport_stale_leases_before_workers(self):
        """A reused PID must not retain a foreign lease or discard cached pack data."""
        action = yaml.safe_load((REPO / '.github/actions/setup-worker/action.yml').read_text())
        steps = action['runs']['steps']
        index = next(i for i, step in enumerate(steps)
                     if step.get('name') == 'Discard restored byte-store leases before starting workers')
        restore = next(i for i, step in enumerate(steps)
                       if step.get('name') == 'Restore validated compiled assets')
        build = next(i for i, step in enumerate(steps)
                     if step.get('name') == 'Build native frontend')
        self.assertLess(restore, index)
        self.assertLess(index, build)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            generation = root / '.dart_tool/ci-compiled-cache/byte_store/v2/hash/store/generation'
            generation.mkdir(parents=True)
            lease = generation / f'lease-{os.getpid()}-old-runner'
            lease.write_text('')
            data = generation / 'data.bin'
            data.write_bytes(b'pack contents')
            subprocess.run(['bash', '-euo', 'pipefail', '-c', steps[index]['run']],
                           env={**os.environ, 'GITHUB_WORKSPACE': str(root)}, check=True)
            self.assertFalse(lease.exists())
            self.assertEqual(data.read_bytes(), b'pack contents')

    def test_one_complete_pub_writer_and_read_only_consumers(self):
        """The union has exactly one writer, and separate SDK resolutions stay scoped."""
        workflow = yaml.safe_load((REPO / '.github/workflows/ci.yml').read_text())
        producers, consumers = [], []
        for name, job in workflow['jobs'].items():
            for step in job['steps']:
                if step.get('uses') != '$/.github/actions/setup-worker':
                    continue
                inputs = step['with']
                if inputs.get('prepare-integration-cache') == 'true':
                    producers.append(name)
                if inputs.get('integration-cache') == 'true':
                    consumers.append(name)
                    self.assertEqual(inputs.get('dependency-resolution', 'get'), 'get')
                    self.assertNotIn('dart-version', inputs)
        self.assertEqual(producers, ['integration-codegen'])
        self.assertEqual(set(consumers), {name for name in workflow['jobs']
                                         if name.startswith('integration-')})
        action = yaml.safe_load((REPO / '.github/actions/setup-worker/action.yml').read_text())
        steps = action['runs']['steps']
        prepare = next(i for i, s in enumerate(steps)
                       if s.get('name') == 'Prepare complete integration Pub downloads')
        save = next(i for i, s in enumerate(steps)
                    if s.get('name') == 'Save complete integration Pub downloads')
        self.assertLess(prepare, save)
        self.assertIn("github.ref == 'refs/heads/main'", steps[save]['if'])
        self.assertIn("inputs.prepare-integration-cache == 'true'", steps[save]['if'])
        for step in steps:
            if step.get('name') in ('Cache Pub downloads', 'Restore Pub downloads'):
                self.assertIn("inputs.integration-cache != 'true'", step['if'])
        compiled = [step for step in steps if step.get('name') in (
            'Cache validated compiled assets', 'Restore validated compiled assets')]
        self.assertEqual(len(compiled), 2)
        self.assertEqual(compiled[0]['with'], compiled[1]['with'])
        self.assertEqual(compiled[0]['with']['path'].split(), [
            '.dart_tool/ci-compiled-cache/byte_store',
            '.dart_tool/ci-compiled-cache/worker-aot',
            '.dart_tool/ci-compiled-cache/manifest-kernel'])
        self.assertNotIn('restore-keys', compiled[0]['with'])
        cold = next(step for step in workflow['jobs']['integration-settings-watch']['steps']
                    if 'parallel' in step)['parallel'][2]
        self.assertEqual(cold['env']['BUILD_RUNNER_ACCELERATOR_CACHE'],
                         '${{ runner.temp }}/settings-compile-cold-cache')

    def test_workspace_json_moves_once_without_splitting_its_lifecycle(self):
        """Keep all workspace transitions together in the measured lighter lane."""
        workflow = yaml.safe_load((REPO / '.github/workflows/ci.yml').read_text())
        owners = []
        for job, config in workflow['jobs'].items():
            for step in config['steps']:
                for lane in step.get('parallel', [step]):
                    if 'bash scripts/correctness_workspace_json.sh' in lane.get('run', ''):
                        owners.append((job, lane['name']))
        self.assertEqual(owners, [('integration-settings-watch', 'Trigger lifecycle and JSON workspace')])


if __name__ == '__main__':
    unittest.main()
