from pathlib import Path
import tempfile
import unittest

import classify_changes
from classify_changes import ScopeIndex, derive_scope, format_jobs


WORKFLOW = """
jobs:
  changes:
    steps: []
  dart-package:
    steps:
      - run: python3 -m unittest discover -s scripts
  integration-a:
    needs: changes
    steps:
      - parallel:
          - run: bash scripts/suite_a.sh
  integration-b:
    needs: changes
    steps:
      - run: python3 scripts/suite_b.py
"""

SCRIPTS = {
    'suite_a.sh': 'source "$script_dir/harness.sh"\n# uses fixtures/app_a\n',
    'harness.sh': 'true\n',
    'suite_b.py': 'import helper\n# uses fixtures/app_b\n',
    'helper.py': 'VALUE = 1\n',
    'orphan.sh': 'true\n',
    'critical.py': 'VALUE = 2\n',
}

FIXTURES = {
    'app_a': 'dependencies:\n  app_b:\n    path: ../app_b\n',
    'app_b': 'dependencies: {}\n',
}


class ClassifyChangesTest(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, classify_changes, 'NO_CI_SCRIPTS',
                        classify_changes.NO_CI_SCRIPTS)
        self.addCleanup(setattr, classify_changes, 'FULL_SCRIPTS',
                        classify_changes.FULL_SCRIPTS)
        classify_changes.NO_CI_SCRIPTS = {'orphan.sh'}
        classify_changes.FULL_SCRIPTS = {'scripts/critical.py'}
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        (root / '.github/workflows').mkdir(parents=True)
        (root / '.github/workflows/ci.yml').write_text(WORKFLOW)
        (root / 'scripts').mkdir()
        for name, source in SCRIPTS.items():
            (root / 'scripts' / name).write_text(source)
        for name, pubspec in FIXTURES.items():
            fixture = root / 'fixtures' / name
            fixture.mkdir(parents=True)
            (fixture / 'pubspec.yaml').write_text(pubspec)
        self.index = ScopeIndex(root)

    def scope(self, *paths):
        return derive_scope(self.index, list(paths))

    def test_light_paths_need_no_gated_jobs(self):
        self.assertEqual(self.scope('docs/ci.md', 'README.md'), set())
        self.assertEqual(self.scope('test/worker_test.dart'), set())
        self.assertEqual(self.scope('renovate.json5'), set())
        self.assertEqual(self.scope('scripts/orphan.sh'), set())

    def test_fixture_scope_follows_reverse_path_dependencies(self):
        self.assertEqual(self.scope('fixtures/app_a/pubspec.yaml'),
                         {'integration-a'})
        self.assertEqual(self.scope('fixtures/app_b/lib/x.dart'),
                         {'integration-a', 'integration-b'})

    def test_script_scope_follows_reverse_references(self):
        self.assertEqual(self.scope('scripts/suite_a.sh'), {'integration-a'})
        self.assertEqual(self.scope('scripts/harness.sh'), {'integration-a'})
        self.assertEqual(self.scope('scripts/helper.py'), {'integration-b'})

    def test_full_scope_cases(self):
        for paths in (['rust/src/build.rs'], ['lib/worker.dart'],
                      ['scripts/critical.py'], ['unknown/path.txt'], []):
            with self.subTest(paths=paths):
                self.assertIsNone(self.scope(*paths))

    def test_unions_across_paths(self):
        self.assertEqual(
            self.scope('fixtures/app_a/pubspec.yaml', 'scripts/helper.py'),
            {'integration-a', 'integration-b'})

    def test_format_jobs_wraps_tokens(self):
        self.assertEqual(format_jobs(set()), 'jobs=,,')
        self.assertEqual(format_jobs({'integration-b', 'integration-a'}),
                         'jobs=,integration-a,integration-b,')

    def test_unaccounted_is_clean_and_detects_contradictions(self):
        self.assertEqual(self.index.unaccounted(), [])
        classify_changes.NO_CI_SCRIPTS = {'orphan.sh', 'harness.sh'}
        self.assertTrue(any('harness.sh' in problem
                            for problem in self.index.unaccounted()))


if __name__ == '__main__':
    unittest.main()
