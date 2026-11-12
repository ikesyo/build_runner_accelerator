import unittest

from classify_changes import classify, is_light


class ClassifyChangesTest(unittest.TestCase):
    def test_empty_and_blank_input_fails_safe_to_full(self):
        self.assertEqual(classify([]), 'full')
        self.assertEqual(classify(['', '  ']), 'full')

    def test_documentation_only_is_light(self):
        self.assertEqual(
            classify(['docs/ci.md', 'README.md', 'docs/benchmarks/x.md']),
            'light')

    def test_dart_tests_only_is_light(self):
        self.assertEqual(
            classify(['test/launcher_test.dart', 'test/helpers/fake.dart']),
            'light')

    def test_ci_helper_changes_are_light_except_cache_identity(self):
        self.assertEqual(
            classify(['.github/scripts/test_check_ci.py',
                      '.github/scripts/check_ci.py']),
            'light')
        self.assertEqual(
            classify(['.github/scripts/compiled_cache_key.py']), 'full')

    def test_classifier_change_forces_full(self):
        self.assertEqual(
            classify(['.github/scripts/classify_changes.py']), 'full')

    def test_any_productive_path_forces_full(self):
        for paths in (
            ['lib/worker.dart'],
            ['rust/src/build.rs'],
            ['fixtures/json_serializable_app/pubspec.yaml'],
            ['scripts/correctness_cli.sh'],
            ['.github/workflows/ci.yml'],
            ['.github/actions/setup-worker/action.yml'],
            ['pubspec.yaml'],
            ['docs/ci.md', 'lib/worker.dart'],
        ):
            with self.subTest(paths=paths):
                self.assertEqual(classify(paths), 'full')

    def test_renovate_config_is_light(self):
        self.assertTrue(is_light('renovate.json5'))


if __name__ == '__main__':
    unittest.main()
