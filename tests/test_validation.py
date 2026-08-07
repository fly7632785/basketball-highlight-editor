import unittest

from basketball_highlight.features import normalize_geometry
from basketball_highlight.validation import binary_metrics
from evaluate_validation import matches_with_rim


class ValidationTest(unittest.TestCase):
    def test_normalize_geometry_uses_rim_width_as_scale(self):
        result = normalize_geometry(
            {
                "speed_px_s": 100.0,
                "approach_horizontal_span_px": 50.0,
                "x_cross": 525.0,
            },
            {"center_x": 500.0, "width": 50.0, "height": 20.0},
        )
        self.assertEqual(result["rim_width_px"], 50.0)
        self.assertEqual(result["speed_per_rim"], 2.0)
        self.assertEqual(result["approach_span_per_rim"], 1.0)
        self.assertEqual(result["crossing_offset_per_rim"], 0.5)

    def test_binary_metrics_reports_precision_and_recall(self):
        result = binary_metrics({1, 2, 4}, {1, 3, 4, 5})
        self.assertEqual(result["true_positive"], 2)
        self.assertEqual(result["false_positive"], 1)
        self.assertEqual(result["false_negative"], 2)
        self.assertAlmostEqual(result["precision"], 2 / 3)
        self.assertAlmostEqual(result["recall"], 0.5)

    def test_matches_with_rim_attaches_normalized_geometry(self):
        result = matches_with_rim({
            "results": [{
                "rim_local": {"center_x": 500.0, "rim_y": 300.0, "width": 50.0, "height": 20.0},
                "refined": [{
                    "time": 1.0,
                    "speed_px_s": 100.0,
                    "approach_horizontal_span_px": 25.0,
                    "x_cross": 500.0,
                }],
            }],
        }, 2.0)
        self.assertEqual(result[0]["speed_per_rim"], 2.0)
        self.assertEqual(result[0]["approach_span_per_rim"], 0.5)


if __name__ == "__main__":
    unittest.main()
