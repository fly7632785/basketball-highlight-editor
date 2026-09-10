from basketball_highlight.roi import (
    expand_hoop_bbox_to_roi,
    hoop_bbox_to_rim_roi,
    select_stable_hoop,
)
from scripts.refine_candidates import _net_zones


def test_expand_hoop_bbox_includes_trajectory_context():
    roi = expand_hoop_bbox_to_roi([490, 320, 505, 334], 960, 720)

    assert roi["x1"] < 490 < roi["x2"]
    assert roi["y1"] < 320 < roi["y2"]
    assert roi["x2"] - roi["x1"] >= 220
    assert roi["y2"] - roi["y1"] >= 190


def test_select_stable_hoop_uses_repeated_detections():
    detections = [
        {"bbox": [480, 310, 500, 330], "confidence": 0.12},
        {"bbox": [481, 311, 501, 331], "confidence": 0.14},
        {"bbox": [479, 309, 499, 329], "confidence": 0.11},
    ]

    result = select_stable_hoop(detections, 960, 720)

    assert result is not None
    assert result["samples"] == 3
    assert result["preview_time_ms"] == 0
    assert result["roi"]["x2"] - result["roi"]["x1"] > 100


def test_select_stable_hoop_uses_highest_confidence_frame_for_preview():
    detections = [
        {"bbox": [480, 310, 500, 330], "confidence": 0.12, "time": 1.0},
        {"bbox": [481, 311, 501, 331], "confidence": 0.24, "time": 4.0},
        {"bbox": [479, 309, 499, 329], "confidence": 0.11, "time": 2.0},
    ]

    result = select_stable_hoop(detections, 960, 720)

    assert result is not None
    assert result["preview_time_ms"] == 4000


def test_hoop_bbox_to_rim_roi_matches_refiner_plane_calibration():
    rim = hoop_bbox_to_rim_roi([480, 310, 500, 330], 960, 720)

    assert rim["left"] == 0.5
    assert rim["right"] == 500 / 960
    assert rim["top"] == (320 - 20 * 0.28 - 20 * 0.45 / 2) / 720
    assert rim["bottom"] == (320 - 20 * 0.28 + 20 * 0.45 / 2) / 720


def test_fallback_net_zones_include_upper_net_opening():
    zones = _net_zones(
        {"center_x": 500, "rim_y": 330, "width": 20, "height": 20},
        960,
        720,
    )

    assert zones["upper"][1] == 320
    assert zones["upper"][0] == zones["lower"][0]
    assert zones["lower"][3] == zones["below"][1]
    assert zones["below"][3] > zones["upper"][1]
