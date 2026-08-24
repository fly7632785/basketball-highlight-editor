import unittest

from error_analysis import audio_status


class ErrorAnalysisTest(unittest.TestCase):
    def test_audio_status_is_triage_only(self):
        self.assertEqual(audio_status({"rms_db_delta": 4.0}), "strong_spike")
        self.assertEqual(audio_status({"rms_db_delta": 1.5}), "weak_spike")
        self.assertEqual(audio_status({"rms_db_delta": 0.2}), "no_spike")
        self.assertEqual(audio_status({}), "unknown")


if __name__ == "__main__":
    unittest.main()
