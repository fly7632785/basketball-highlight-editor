import unittest

from basketball_highlight.events import (
    _net_inside_motion_features,
    calibrated_gates,
    find_candidate_crossings,
    find_refined_crossings,
    normalized_calibrated_gates,
)
from basketball_highlight.trajectory import fit_descent, prediction_score


class EventsTest(unittest.TestCase):
    def test_net_motion_uses_local_baseline_before_calling_inside_motion(self):
        records = [
            {"time": 0.2, "net_measurement_valid": True,
             "net_lower_motion_score": 0.8, "net_below_motion_score": 0.8},
            {"time": 0.3, "net_measurement_valid": True,
             "net_lower_motion_score": 0.82, "net_below_motion_score": 0.79},
            {"time": 0.95, "net_measurement_valid": True,
             "net_lower_motion_score": 0.81, "net_below_motion_score": 0.8},
            {"time": 1.05, "net_measurement_valid": True,
             "net_lower_motion_score": 0.83, "net_below_motion_score": 0.82},
            {"time": 1.15, "net_measurement_valid": True,
             "net_lower_motion_score": 0.8, "net_below_motion_score": 0.81},
        ]

        signals = _net_inside_motion_features(records, 1.0)

        self.assertEqual(signals["net_motion_order"], "none")
        self.assertFalse(signals["net_no_motion"])
        self.assertLess(signals["net_lower_peak"], 0.12)
        self.assertLess(signals["net_below_peak"], 0.12)

    def test_normalized_gate_preserves_geometry_across_rim_scale(self):
        small = {
            "speed_px_s": 60.0,
            "approach_horizontal_span_px": 60.0,
            "rim_width_px": 30.0,
            "horizontal_ratio": 0.6,
            "net_motion_score": 0.0,
            "net_changed_ratio": 0.0,
        }
        large = {
            "speed_px_s": 120.0,
            "approach_horizontal_span_px": 120.0,
            "rim_width_px": 60.0,
            "horizontal_ratio": 0.6,
            "net_motion_score": 0.0,
            "net_changed_ratio": 0.0,
        }
        self.assertEqual(
            normalized_calibrated_gates(small, reference_rim_width=30.0)["high_precision"],
            normalized_calibrated_gates(large, reference_rim_width=30.0)["high_precision"],
        )

    def test_downward_ball_crossing_inside_rim_is_candidate(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 350]}]},
        ]
        candidates = find_candidate_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["x_cross"], 491)

    def test_coarse_crossing_sorts_detection_records_by_timestamp(self):
        records = [
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 350]}]},
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
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

    def test_refined_crossing_rejects_side_entry_with_interpolated_x_inside_rim(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [477, 300]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [478, 310]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [505, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [510, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [515, 385]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(candidates, [])

    def test_refined_crossing_requires_two_points_below_rim(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(candidates, [])

    def test_prediction_keeps_single_below_point_as_review_candidate(self):
        records = []
        ys = [280, 285, 295, 305, 315, 345]
        for index, y in enumerate(ys):
            records.append({
                "time": index * 0.1,
                "detections": [{
                    "name": "ball",
                    "confidence": 0.8,
                    "center": [490 + index * 0.2, y],
                }],
            })

        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )

        self.assertEqual(len(candidates), 1)
        self.assertTrue(candidates[0]["gates"]["prediction_review"])
        self.assertFalse(candidates[0]["complete_crossing"])
        self.assertEqual(candidates[0]["verdict"], "ambiguous")

    def test_refined_crossing_rejects_intermediate_side_deviation(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 310]}]},
            {"time": 1.2, "detections": [{"name": "ball", "confidence": 0.8, "center": [530, 320]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 365]}]},
        ]

        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )

        self.assertEqual(candidates, [])

    def test_refined_gate_uses_rim_relative_geometry(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 360]}]},
            {"time": 1.6, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 380]}]},
        ]

        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 60, "height": 20},
        )

        self.assertEqual(len(candidates), 1)
        self.assertTrue(candidates[0]["gates"]["strict_low_speed"])

    def test_missing_net_measurement_is_not_treated_as_zero_motion(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        for record in records:
            record["net_lower_motion_score"] = 0.0
            record["net_below_motion_score"] = 0.0

        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )

        self.assertEqual(len(candidates), 1)
        self.assertFalse(candidates[0]["verification"]["net_signal_available"])

    def test_valid_zero_net_measurement_is_negative_evidence(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        for record in records:
            record.update({
                "net_measurement_valid": True,
                "net_lower_motion_score": 0.0,
                "net_below_motion_score": 0.0,
            })

        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )

        self.assertEqual(len(candidates), 1)
        self.assertTrue(candidates[0]["verification"]["net_signal_available"])
        self.assertTrue(candidates[0]["verification"]["net_no_motion"])
        self.assertFalse(candidates[0]["gates"]["high_precision"])

    def test_refined_crossing_rejects_extreme_vertical_flyover(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 250]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 260]}]},
            {"time": 1.2, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 360]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 390]}]},
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

    def test_refined_crossing_skips_association_switch_after_early_below_point(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 270]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 280]}]},
            {"time": 1.2, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 350]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 330]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 370]}]},
            {"time": 1.6, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 400]}]},
        ]
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["below"]["time"], 1.5)

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

    def test_refined_crossing_keeps_deep_lateral_drift_reviewable(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [420, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [420, 385]}]},
        ]
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["verdict"], "ambiguous")
        self.assertFalse(candidates[0]["verification"]["lateral_exit"])

    def test_refined_crossing_accepts_fast_low_confidence_single_below_point(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [489, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.55, "center": [492, 365]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)

    def test_refined_crossing_keeps_low_auxiliary_signal_as_review_candidate(self):
        records = [
            {"time": 1.0, "net_motion_score": 0.0, "net_changed_ratio": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.1, "net_motion_score": 0.0, "net_changed_ratio": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "net_motion_score": 0.0, "net_changed_ratio": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "net_motion_score": 0.0, "net_changed_ratio": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertIn(candidates[0]["confidence"], {"low", "review"})

    def test_refined_crossing_tracks_continuous_ball_over_high_confidence_distractor(self):
        records = [
            {"time": 1.0, "detections": [
                {"name": "ball", "confidence": 0.45, "center": [489, 295]},
                {"name": "ball", "confidence": 0.95, "center": [650, 295]},
            ]},
            {"time": 1.1, "detections": [
                {"name": "ball", "confidence": 0.46, "center": [490, 300]},
                {"name": "ball", "confidence": 0.95, "center": [650, 300]},
            ]},
            {"time": 1.3, "detections": [
                {"name": "ball", "confidence": 0.47, "center": [491, 345]},
                {"name": "ball", "confidence": 0.95, "center": [650, 345]},
            ]},
            {"time": 1.4, "detections": [
                {"name": "ball", "confidence": 0.48, "center": [492, 365]},
                {"name": "ball", "confidence": 0.95, "center": [650, 365]},
            ]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["above"]["x"], 490)

    def test_recovery_stitches_split_track_without_following_distractor(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [520, 270]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [505, 295]}]},
            {"time": 1.2, "detections": []},
            {"time": 1.4, "detections": [
                {"name": "ball", "confidence": 0.8, "center": [490, 350]},
                {"name": "ball", "confidence": 0.9, "center": [620, 345]},
            ]},
            {"time": 1.5, "detections": [
                {"name": "ball", "confidence": 0.8, "center": [491, 375]},
                {"name": "ball", "confidence": 0.9, "center": [630, 365]},
            ]},
        ]

        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )

        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["verdict"], "ambiguous")
        self.assertAlmostEqual(candidates[0]["below"]["x"], 490)

    def test_refined_crossing_exposes_multi_signal_decision(self):
        records = [
            {"time": 1.0, "net_lower_motion_score": 0.05, "net_below_motion_score": 0.02,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [489, 295]}]},
            {"time": 1.1, "net_lower_motion_score": 0.08, "net_below_motion_score": 0.04,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "net_lower_motion_score": 0.85, "net_below_motion_score": 0.45,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "net_lower_motion_score": 0.9, "net_below_motion_score": 0.8,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "net_lower_motion_score": 0.75, "net_below_motion_score": 0.7,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertIn("score", candidates[0])
        self.assertIn("signals", candidates[0])
        self.assertGreaterEqual(candidates[0]["signals"]["net_lower"], 0.8)

    def test_net_motion_requires_lower_to_below_sequence_for_support(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "net_lower_motion_score": 0.8, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "net_lower_motion_score": 0.9, "net_below_motion_score": 0.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "net_below_motion_score": 0.8, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        for record in records:
            record["net_measurement_valid"] = True
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["signals"]["net_motion_order"], "lower_to_below")
        self.assertTrue(candidates[0]["verification"]["net_support"])

    def test_reliable_no_net_motion_stays_reviewable(self):
        records = [
            {"time": 1.0, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        for record in records:
            record["net_measurement_valid"] = True
        candidates = find_refined_crossings(records, {"center_x": 490, "rim_y": 325, "width": 20})
        self.assertEqual(len(candidates), 1)
        self.assertFalse(candidates[0]["gates"]["automatic_goal"])
        self.assertEqual(candidates[0]["verdict"], "ambiguous")

    def test_lower_net_motion_without_sequence_stays_reviewable(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "net_lower_motion_score": 0.9, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "net_lower_motion_score": 0.8, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "net_lower_motion_score": 0.7, "net_below_motion_score": 0.0,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        for record in records:
            record["net_measurement_valid"] = True
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["signals"]["net_motion_order"], "lower_only")
        self.assertFalse(candidates[0]["verification"]["net_support"])
        self.assertEqual(candidates[0]["verdict"], "ambiguous")

    def test_same_frame_net_motion_stays_reviewable_without_direction(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "net_lower_motion_score": 0.9, "net_below_motion_score": 0.8,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "net_lower_motion_score": 0.8, "net_below_motion_score": 0.7,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "net_lower_motion_score": 0.7, "net_below_motion_score": 0.6,
             "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        for record in records:
            record["net_measurement_valid"] = True
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["signals"]["net_motion_order"], "same_frame")
        self.assertTrue(candidates[0]["verification"]["net_support"])
        self.assertEqual(candidates[0]["verdict"], "ambiguous")

    def test_refined_crossing_continues_after_incomplete_early_below_pair(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.2, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 345]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [520, 350]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 385]}]},
        ]
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["below"]["time"], 1.4)

    def test_refined_event_time_uses_interpolated_rim_crossing_time(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.6, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertAlmostEqual(candidates[0]["time"], 1.27, places=2)

    def test_refined_crossing_exposes_overlay_trajectory_and_rim(self):
        records = [
            {"time": 1.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [489, 295]}]},
            {"time": 1.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 1.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 1.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 1.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ]
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )

        overlay = candidates[0]["overlay"]
        self.assertEqual(overlay["rim"]["center_x"], 490)
        self.assertEqual(overlay["rim"]["rim_y"], 325)
        self.assertGreaterEqual(len(overlay["trajectory"]), 4)
        self.assertEqual(overlay["crossing"]["y"], 325)
        self.assertTrue(overlay["crossing"]["valid"])

    def test_recall_review_gate_keeps_broad_candidates_out_of_auto_gate(self):
        gates = calibrated_gates({
            "speed_px_s": 105,
            "approach_horizontal_span_px": 170,
            "horizontal_ratio": 0.2,
            "net_score": 0.46,
            "net_motion_score": 0.2,
        })
        self.assertTrue(gates["recall_review"])
        self.assertFalse(gates["high_precision"])

    def test_recall_review_gate_rejects_wide_fast_flyover(self):
        gates = calibrated_gates({
            "speed_px_s": 276,
            "approach_horizontal_span_px": 304,
            "horizontal_ratio": 0.63,
            "net_score": 0.12,
            "net_motion_score": 0.05,
        })
        self.assertFalse(gates["recall_review"])

    def test_recall_review_gate_contains_default_review_gate(self):
        gates = calibrated_gates({
            "speed_px_s": 90,
            "approach_horizontal_span_px": 192,
            "horizontal_ratio": 0.9,
            "net_score": 0.0,
            "net_motion_score": 0.0,
        })
        self.assertTrue(gates["review"])
        self.assertTrue(gates["recall_review"])

    def test_automatic_goal_gate_accepts_safe_low_speed_crossing(self):
        gates = calibrated_gates({
            "speed_px_s": 95,
            "approach_horizontal_span_px": 120,
            "horizontal_ratio": 0.4,
            "net_score": 0.1,
            "net_motion_score": 0.1,
            "net_changed_ratio": 0.02,
        })
        self.assertTrue(gates["automatic_goal"])

    def test_automatic_goal_gate_accepts_strong_net_change(self):
        gates = calibrated_gates({
            "speed_px_s": 155,
            "approach_horizontal_span_px": 60,
            "horizontal_ratio": 0.4,
            "net_score": 0.4,
            "net_motion_score": 0.4,
            "net_changed_ratio": 0.14,
        })
        self.assertTrue(gates["automatic_goal"])

    def test_automatic_goal_gate_rejects_fast_weak_net_candidate(self):
        gates = calibrated_gates({
            "speed_px_s": 181,
            "approach_horizontal_span_px": 45,
            "horizontal_ratio": 0.32,
            "net_score": 0.3,
            "net_motion_score": 0.3,
            "net_changed_ratio": 0.047,
        })
        self.assertFalse(gates["automatic_goal"])

    def test_trajectory_prediction_uses_clear_descent_points(self):
        track = []
        for index in range(9):
            t = index * 0.1
            track.append({"time": t, "x": 380 + 55 * t, "y": 360 - 70 * t + 180 * t * t})
        result = prediction_score(track, {"center_x": 425, "rim_y": 470, "width": 50})
        self.assertIsNotNone(result)
        self.assertGreaterEqual(result["fit_r2"], 0.85)
        self.assertGreater(result["landing_center"], 0.5)

    def test_trajectory_prediction_rejects_insufficient_points(self):
        track = [{"time": i * 0.1, "x": 400 + i, "y": 300 + i * 5} for i in range(4)]
        self.assertIsNone(fit_descent(track, 450))

    def test_trajectory_prediction_rejects_low_quality_fit(self):
        ys = [300, 306, 350, 315, 370, 330, 390, 340]
        track = [{"time": i * 0.1, "x": 400 + i, "y": y} for i, y in enumerate(ys)]
        self.assertIsNone(fit_descent(track, 450, min_r2=0.85))

    def test_refined_crossing_exposes_prediction_as_recall_review_only(self):
        records = []
        ys = [280, 285, 295, 305, 315, 335, 355, 375]
        for index, y in enumerate(ys):
            records.append({
                "time": index * 0.1,
                "detections": [{
                    "name": "ball",
                    "confidence": 0.8,
                    "center": [490 + index * 0.2, y],
                }],
            })
        candidates = find_refined_crossings(
            records, {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        )
        self.assertEqual(len(candidates), 1)
        self.assertIsNotNone(candidates[0]["prediction"])
        self.assertTrue(candidates[0]["gates"]["prediction_review"])
        self.assertFalse(candidates[0]["gates"]["high_precision"])


if __name__ == "__main__":
    unittest.main()
