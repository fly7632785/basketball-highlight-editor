import unittest

from basketball_highlight.events import find_candidate_crossings, find_refined_crossings


class EventsTest(unittest.TestCase):
    def test_downward_ball_crossing_inside_rim_is_candidate(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 350]}]},
        ]
        candidates = find_candidate_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["x_cross"], 491)

    def test_crossing_outside_rim_is_rejected(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [530, 300]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [530, 350]}]},
        ]
        candidates = find_candidate_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(candidates, [])

    def test_refined_crossing_requires_persistent_trajectory(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [489, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [494, 385]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)

    def test_refined_crossing_rejects_horizontal_pass(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [450, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [455, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [520, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [525, 365]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(candidates, [])

    def test_refined_crossing_rejects_rebound_after_rim_contact(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 370]}]},
            {"time": 1.6, "detections": [{"name": "ball", "confidence": 0.8, "center": [480, 350]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(candidates, [])

    def test_refined_crossing_rejects_lateral_exit_below_rim(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 370]}]},
            {"time": 1.6, "detections": [{"name": "ball", "confidence": 0.8, "center": [420, 385]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(candidates, [])


if __name__ == "__main__":
    unittest.main()
