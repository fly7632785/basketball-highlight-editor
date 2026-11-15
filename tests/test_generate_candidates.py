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


def test_later_above_rim_seed_cannot_suppress_an_earlier_below_rim_sighting():
    module = _load_module()
    rim = {"center_x": 500, "rim_y": 300, "width": 50, "height": 20}
    records = [
        {"time": time, "detections": [{"name": "ball", "center": [500, y], "confidence": confidence}]}
        for time, y, confidence in [(19.2, 325, .7), (20.0, 275, .9), (20.3, 330, .8)]
    ]
    seeds = module.find_rim_band_seeds(records, rim, [])
    assert sorted(item["time"] for item in seeds) == [19.2, 20.0]
    # A paired crossing still accounts for nearby sightings on either side.
    assert module.find_rim_band_seeds(records, rim, [{"time": 19.5}]) == []
