"""Keep CI's JSON split exhaustive as correctness cases are added."""
from collections import Counter
from pathlib import Path
import re
import subprocess
import unittest


REPO = Path(__file__).resolve().parents[2]


def selected_cases(group):
    source = (REPO / 'scripts/correctness_json_serializable.sh').read_text()
    names = re.search(r'^known_case_names=\(.*?^\)', source, re.M | re.S).group(0)
    selection = source[source.index('is_known_case() {'):source.index('case_is_selected() {')]
    # Execute the actual pure Bash selector without setting up fixtures or Dart.
    script = ('fail() { exit 1; }; case_filter=$1; selected_case_names=();\n'
              + names + '\n' + selection
              + '\nprintf "%s\\n" "${selected_case_names[@]}"')
    result = subprocess.run(['bash', '-c', script, 'json-selector', group],
                            text=True, capture_output=True, check=True)
    return result.stdout.splitlines()


class JsonCasePartitionTest(unittest.TestCase):
    def test_shared_and_independent_cases_cover_all_exactly_once(self):
        shared = selected_cases('shared-baseline')
        independent = selected_cases('conditional-dependency')
        self.assertTrue(shared)
        self.assertEqual(independent, ['conditional-dependency'])
        self.assertEqual(Counter(shared + independent), Counter(selected_cases('all')))

    def test_unknown_cases_are_rejected(self):
        with self.assertRaises(subprocess.CalledProcessError):
            selected_cases('unknown-case')


if __name__ == '__main__':
    unittest.main()
