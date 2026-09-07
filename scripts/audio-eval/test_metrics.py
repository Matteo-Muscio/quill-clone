import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('audio_eval', pathlib.Path(__file__).with_name('run.py'))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class ErrorRateTests(unittest.TestCase):
    def test_substitution(self):
        result = evaluation.error_rates('send the report', 'send a report')
        self.assertEqual(result['wordEdits'], {'distance': 1, 'substitutions': 1, 'deletions': 0, 'insertions': 0})
        self.assertAlmostEqual(result['wer'], 1 / 3)

    def test_deletion(self):
        result = evaluation.error_rates('send the report', 'send report')
        self.assertEqual(result['wordEdits']['deletions'], 1)
        self.assertEqual(result['wordEdits']['insertions'], 0)
        self.assertAlmostEqual(result['wer'], 1 / 3)

    def test_insertion(self):
        result = evaluation.error_rates('send report', 'please send report')
        self.assertEqual(result['wordEdits']['insertions'], 1)
        self.assertEqual(result['wordEdits']['deletions'], 0)
        self.assertEqual(result['wer'], 0.5)

    def test_unicode_case_punctuation_and_whitespace_normalization(self):
        result = evaluation.error_rates('CAFÉ,  sì!', 'cafe\u0301 SÌ')
        self.assertEqual(result['wer'], 0)
        self.assertEqual(result['cer'], 0)

    def test_character_edits_exclude_spaces(self):
        result = evaluation.error_rates('cat nap', 'cut naps')
        self.assertEqual(result['characterErrors'], 2)
        self.assertAlmostEqual(result['cer'], 2 / 6)

    def test_empty_reference_rates_are_explicit(self):
        self.assertIsNone(evaluation.error_rates('', 'one')['wer'])
        self.assertIsNone(evaluation.error_rates('', 'one')['cer'])
        self.assertEqual(evaluation.error_rates('', '')['wer'], 0)
        self.assertEqual(evaluation.error_rates('one', '')['wer'], 1)


if __name__ == '__main__':
    unittest.main()
