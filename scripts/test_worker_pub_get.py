"""Root dependency preparation must honor the same offline setting as fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class WorkerPubGetTest(unittest.TestCase):
    def test_root_preparation_honors_offline_without_duplicate_arguments(self):
        worker = Path(__file__).with_name('worker.sh').resolve()
        for offline, arguments, expected in (
            ('0', [], []),
            ('1', [], ['--offline']),
            ('1', ['--offline'], ['--offline']),
            ('1', ['--enforce-lockfile'], ['--enforce-lockfile', '--offline']),
        ):
            with self.subTest(offline=offline, arguments=arguments), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'pubspec.yaml').write_text('name: test_root\n')
                (root / 'pubspec.lock').touch()
                dart = root / 'dart'
                dart.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$CAPTURE_ARGS"\n')
                dart.chmod(0o755)
                capture = root / 'arguments'
                env = dict(os.environ, repo_root=str(root), WORKER_SCRIPT=str(worker),
                           DART_BIN=str(dart), PUB_CACHE=str(root / 'pub-cache'),
                           RUSTUP_HOME=str(root), CARGO_HOME=str(root),
                           PUB_GET_OFFLINE=offline, CAPTURE_ARGS=str(capture),
                           VERIFY_STREAM_LOGS='0')
                subprocess.run(['bash', '-c', 'source "$WORKER_SCRIPT"; worker_prepare "$@"',
                                'test', *arguments], env=env, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
                self.assertEqual(capture.read_text().splitlines(),
                                 ['--suppress-analytics', 'pub', 'get', *expected])


if __name__ == '__main__':
    unittest.main()
