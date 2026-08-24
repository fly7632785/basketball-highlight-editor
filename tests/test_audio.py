import unittest

import numpy as np

from basketball_highlight.audio import audio_features, event_window_features, merge_time_ranges


class AudioTest(unittest.TestCase):
    def test_invalid_sample_rate_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "SAMPLE_RATE_INVALID"):
            audio_features(np.zeros(8, dtype=np.float32), 0)

    def test_silence_has_zero_energy(self):
        result = audio_features(np.zeros(16000, dtype=np.float32), 16000)
        self.assertEqual(result["rms"], 0.0)
        self.assertEqual(result["peak"], 0.0)

    def test_impulse_has_peak_and_crest(self):
        samples = np.zeros(16000, dtype=np.float32)
        samples[8000] = 1.0
        result = audio_features(samples, 16000)
        self.assertAlmostEqual(result["peak"], 1.0)
        self.assertGreater(result["crest_factor"], 10.0)

    def test_event_window_features_detects_active_energy_spike(self):
        sample_rate = 1000
        samples = np.zeros(1800, dtype=np.float32)
        samples[1000:1100] = 0.5
        result = event_window_features(samples, sample_rate, event_offset=1.0)
        self.assertGreater(result["rms_delta"], 0.0)
        self.assertGreater(result["rms_ratio"], 1.0)
        self.assertGreater(result["active_peak"], result["baseline_peak"])

    def test_merge_time_ranges_keeps_gaps_and_combines_overlaps(self):
        result = merge_time_ranges([(0.0, 1.0), (0.8, 2.0), (4.0, 5.0)])
        self.assertEqual(result, [(0.0, 2.0), (4.0, 5.0)])


if __name__ == "__main__":
    unittest.main()
