import json
import subprocess
import sys
from pathlib import Path


def test_export_cross_platform_replay_preserves_python_contract(tmp_path):
    source = tmp_path / "records.json"
    output = tmp_path / "replay.json"
    source.write_text(json.dumps({
        "frame_width": 1000,
        "frame_height": 600,
        "rim": {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        "records": [
            {"time": 0.0, "net_measurement_valid": True, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 0.1, "net_measurement_valid": True, "net_lower_motion_score": 0.0, "net_below_motion_score": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 0.3, "net_measurement_valid": True, "net_lower_motion_score": 0.5, "net_below_motion_score": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 0.4, "net_measurement_valid": True, "net_lower_motion_score": 0.6, "net_below_motion_score": 0.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 0.5, "net_measurement_valid": True, "net_lower_motion_score": 0.5, "net_below_motion_score": 0.7, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ],
    }), encoding="utf-8")

    root = Path(__file__).resolve().parents[1]
    subprocess.run([
        sys.executable,
        str(root / "scripts" / "export_cross_platform_replay.py"),
        "--input", str(source),
        "--output", str(output),
    ], check=True, cwd=root)

    replay = json.loads(output.read_text(encoding="utf-8"))
    assert replay["schema_version"] == "bhe-decision-replay-v1"
    assert replay["algorithm_version"] == "analysis-contract-v1"
    assert replay["replays"][0]["expected"]["verdict"] == "made"
    assert replay["replays"][0]["hoop_roi"]["left"] == 0.48
