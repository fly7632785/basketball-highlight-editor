from basketball_highlight.roi import expand_hoop_bbox_to_roi, select_stable_hoop


def test_expand_hoop_bbox_includes_trajectory_context():
    roi = expand_hoop_bbox_to_roi([490, 320, 505, 334], 960, 720)

    assert roi["x1"] < 490 < roi["x2"]
    assert roi["y1"] < 320 < roi["y2"]
    assert roi["x2"] - roi["x1"] >= 120
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
