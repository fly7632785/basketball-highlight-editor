import unittest

from basketball_highlight.events import find_candidate_crossings


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


if __name__ == "__main__":
    unittest.main()
