"""Keep descendant discovery correct and bounded in large process tables."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class VerificationProcessGroupsTest(unittest.TestCase):
    def test_large_unrelated_snapshot_keeps_detached_descendants_and_bounds_cycles(self):
        """Discover out-of-order descendants without scanning every PID per ancestor."""
        support = Path(__file__).with_name('verification_support.sh')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / 'snapshot'
            # Descendants precede their parents; unrelated cycles and absent
            # parents must terminate without including those process groups.
            rows = ['400 300 401', '300 100 301', '100 1 100', '1 0 1',
                    '600 601 601', '601 600 601', '700 999999 701']
            rows.extend(f'{20000 + i} 1 {40000 + i}' for i in range(10000))
            snapshot.write_text('\n'.join(rows) + '\n')
            fake_ps = root / 'ps'
            fake_ps.write_text('''#!/usr/bin/env bash
case "$*" in
  '-o pgid= -p 100') echo 100 ;;
  '-eo pid=,ppid=,pgid=') cat "$TEST_PS_SNAPSHOT" ;;
  *) exit 2 ;;
esac
''')
            fake_ps.chmod(0o755)
            result = subprocess.run(
                ['bash', '-c', 'source "$1"; verification_process_group_ids 100',
                 'process-group-test', str(support)],
                env={**os.environ, 'PATH': f'{root}:{os.environ["PATH"]}',
                     'TEST_PS_SNAPSHOT': str(snapshot)},
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(set(result.stdout.split()), {'100', '301', '401'})


if __name__ == '__main__':
    unittest.main()
