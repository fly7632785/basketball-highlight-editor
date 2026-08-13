import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))

from export_review_queue import is_automatic_goal, unique_matches


class ExportReviewQueueTest(unittest.TestCase):
    def test_auto_only_keeps_safe_candidate(self):
        match = {
            "time": 12.0,
            "speed_px_s": 90.0,
            "approach_horizontal_span_px": 100.0,
            "horizontal_ratio": 0.4,
            "net_motion_score": 0.1,
            "net_score": 0.1,
            "net_changed_ratio": 0.02,
        }
        self.assertTrue(is_automatic_goal(match))

    def test_auto_only_rejects_known_miss_shape(self):
        match = {
            "time": 12.0,
            "speed_px_s": 181.0,
            "approach_horizontal_span_px": 45.0,
            "horizontal_ratio": 0.32,
            "net_motion_score": 0.3,
            "net_score": 0.3,
            "net_changed_ratio": 0.047,
        }
        self.assertFalse(is_automatic_goal(match))

    def test_auto_only_rejects_non_made_verdict_even_if_geometry_is_safe(self):
        match = {
            "time": 12.0,
            "verdict": "ambiguous",
            "speed_px_s": 90.0,
            "approach_horizontal_span_px": 100.0,
            "horizontal_ratio": 0.4,
            "net_motion_score": 0.1,
            "net_score": 0.1,
            "net_changed_ratio": 0.02,
        }
        self.assertFalse(is_automatic_goal(match))

    def test_unique_matches_can_filter_auto_only(self):
        data = {
            "results": [{
                "refined": [
                    {
                        "time": 1.0,
                        "speed_px_s": 90.0,
                        "approach_horizontal_span_px": 100.0,
                        "horizontal_ratio": 0.4,
                        "net_motion_score": 0.1,
                        "net_score": 0.1,
                        "net_changed_ratio": 0.02,
                    },
                    {
                        "time": 4.0,
                        "speed_px_s": 181.0,
                        "approach_horizontal_span_px": 45.0,
                        "horizontal_ratio": 0.32,
                        "net_motion_score": 0.3,
                        "net_score": 0.3,
                        "net_changed_ratio": 0.047,
                    },
                ],
            }],
        }
        matches = unique_matches(data, 2.0, auto_only=True)
        self.assertEqual([match["time"] for match in matches], [1.0])


if __name__ == "__main__":
    unittest.main()
