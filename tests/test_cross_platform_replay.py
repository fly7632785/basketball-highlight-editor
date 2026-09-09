import json
import subprocess
import sys
from pathlib import Path

from scripts.export_cross_platform_replay import candidate_rim


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
    assert "candidate_complete_crossing" not in replay["replays"][0]
    assert "candidate_net_support" not in replay["replays"][0]
    assert abs(replay["replays"][0]["horizontal_ratio"] - (2 / 90)) < 1e-9
    assert all(point["whole"] == 0.0 for point in replay["replays"][0]["net_history"])
    assert replay["replays"][0]["net_history"][2]["lower"] == 0.5
    assert replay["replays"][0]["net_history"][2]["measurement_valid"] is True
    assert replay["replays"][0]["net_history"][2]["lower_inside"] == 0.5
    assert replay["replays"][0]["net_history"][2]["lower_components"] == [0.5, 0.0, 0.0, 0.0]


def test_export_cross_platform_replay_treats_legacy_net_records_as_valid(tmp_path):
    source = tmp_path / "records.json"
    output = tmp_path / "replay.json"
    source.write_text(json.dumps({
        "frame_width": 1000,
        "frame_height": 600,
        "rim": {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        "records": [
            {"time": 0.0, "net_lower_motion_score": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 0.1, "net_lower_motion_score": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 0.3, "net_lower_motion_score": 0.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 0.4, "net_lower_motion_score": 0.6, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 0.5, "net_lower_motion_score": 0.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ],
    }), encoding="utf-8")

    root = Path(__file__).resolve().parents[1]
    subprocess.run([
        sys.executable,
        str(root / "scripts" / "export_cross_platform_replay.py"),
        "--input", str(source),
        "--output", str(output),
    ], check=True, cwd=root)

    replay = json.loads(output.read_text(encoding="utf-8"))["replays"][0]
    assert all(point["measurement_valid"] is True for point in replay["net_history"])


def test_export_cross_platform_replay_does_not_invent_net_measurements(tmp_path):
    source = tmp_path / "records.json"
    output = tmp_path / "replay.json"
    source.write_text(json.dumps({
        "frame_width": 1000,
        "frame_height": 600,
        "rim": {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        "records": [
            {"time": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 0.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 0.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 0.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 0.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ],
    }), encoding="utf-8")

    root = Path(__file__).resolve().parents[1]
    subprocess.run([
        sys.executable,
        str(root / "scripts" / "export_cross_platform_replay.py"),
        "--input", str(source),
        "--output", str(output),
    ], check=True, cwd=root)

    replay = json.loads(output.read_text(encoding="utf-8"))["replays"][0]
    assert all(point["measurement_valid"] is False for point in replay["net_history"])


def test_compare_report_uses_tolerances_and_summary(tmp_path):
    source = tmp_path / "records.json"
    source.write_text(json.dumps({
        "frame_width": 1000,
        "frame_height": 600,
        "rim": {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        "records": [
            {"time": 0.0, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 0.1, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 0.3, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 0.4, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 0.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ],
    }), encoding="utf-8")
    root = Path(__file__).resolve().parents[1]
    binary = root / "packages" / "bhe_runtime" / "target" / "debug" / "bhe-runtime"
    if not binary.exists():
        return
    report = tmp_path / "report.json"
    result = subprocess.run([
        sys.executable,
        str(root / "scripts" / "compare_cross_platform_replay.py"),
        "--input", str(source),
        "--rust-binary", str(binary),
        "--output", str(report),
    ], check=True, cwd=root)
    del result
    rendered = json.loads(report.read_text(encoding="utf-8"))
    assert rendered["match_rate"] == 1.0
    assert rendered["summary"]["event_tolerance_ms"] == 300
    assert rendered["summary"]["numeric_tolerance"] == 0.01
    assert rendered["summary"]["mismatch_counts"] == {}


def test_replay_uses_candidate_overlay_rim_when_available():
    fallback = {"center_x": 490, "rim_y": 325, "width": 20}
    candidate = {"overlay": {"rim": {"center_x": 512, "rim_y": 310, "width": 24}}}

    assert candidate_rim(candidate, fallback) == candidate["overlay"]["rim"]


def test_export_cross_platform_replay_can_lock_derived_decisions(tmp_path):
    source = tmp_path / "records.json"
    output = tmp_path / "replay.json"
    source.write_text(json.dumps({
        "frame_width": 1000,
        "frame_height": 600,
        "rim": {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        "records": [
            {"time": 0.0, "net_measurement_valid": True, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 0.1, "net_measurement_valid": True, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 0.3, "net_measurement_valid": True, "net_lower_motion_score": 0.5, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
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
        "--locked-decision",
    ], check=True, cwd=root)

    replay = json.loads(output.read_text(encoding="utf-8"))["replays"][0]
    assert replay["candidate_complete_crossing"] is True
    assert replay["candidate_net_support"] is True


def test_export_cross_platform_replay_preserves_unavailable_net_measurements(tmp_path):
    source = tmp_path / "records.json"
    output = tmp_path / "replay.json"
    source.write_text(json.dumps({
        "frame_width": 1000,
        "frame_height": 600,
        "rim": {"center_x": 490, "rim_y": 325, "width": 20, "height": 20},
        "records": [
            {"time": 0.0, "net_measurement_valid": False, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 295]}]},
            {"time": 0.1, "net_measurement_valid": False, "detections": [{"name": "ball", "confidence": 0.8, "center": [490, 300]}]},
            {"time": 0.3, "net_measurement_valid": False, "detections": [{"name": "ball", "confidence": 0.8, "center": [491, 345]}]},
            {"time": 0.4, "net_measurement_valid": False, "detections": [{"name": "ball", "confidence": 0.8, "center": [492, 365]}]},
            {"time": 0.5, "net_measurement_valid": False, "detections": [{"name": "ball", "confidence": 0.8, "center": [493, 385]}]},
        ],
    }), encoding="utf-8")

    root = Path(__file__).resolve().parents[1]
    subprocess.run([
        sys.executable,
        str(root / "scripts" / "export_cross_platform_replay.py"),
        "--input", str(source),
        "--output", str(output),
    ], check=True, cwd=root)

    replay = json.loads(output.read_text(encoding="utf-8"))["replays"][0]
    assert len(replay["net_history"]) == 5
    assert all(point["measurement_valid"] is False for point in replay["net_history"])
