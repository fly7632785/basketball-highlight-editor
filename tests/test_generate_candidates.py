import importlib.util
from pathlib import Path


def _load_module():
    path = Path(__file__).parents[1] / "scripts" / "generate_candidates.py"
    spec = importlib.util.spec_from_file_location("generate_candidates", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_estimate_rim_accepts_low_confidence_specialized_model_detections():
    module = _load_module()
    records = [
        {
            "detections": [
                {
                    "name": "hoop",
                    "confidence": 0.11,
                    "xyxy": [480, 310, 500, 330],
                    "center": [490, 320],
                }
            ]
        }
    ]

    rim = module.estimate_rim(records, confidence=0.3)

    assert rim["source"] == "median_hoop_detections"
    assert rim["confidence_threshold"] == 0.055
    assert rim["center_x"] == 490
    assert rim["rim_y"] == 320


def test_estimate_rim_still_fails_when_no_hoop_is_detected():
    module = _load_module()

    try:
        module.estimate_rim([{"detections": []}], confidence=0.08)
    except ValueError as error:
        assert "No hoop detections found" in str(error)
    else:
        raise AssertionError("estimate_rim should fail without hoop detections")
