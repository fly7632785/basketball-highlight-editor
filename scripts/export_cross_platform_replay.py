#!/usr/bin/env python3
"""Export Python refined candidates as ONNX-free Rust decision replays."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from basketball_highlight.events import ANALYSIS_CONTRACT_VERSION, find_refined_crossings


def point(value: dict, width: float, height: float) -> dict:
    return {
        "time_ms": round(float(value["time"]) * 1000),
        "x": float(value["x"]) / width,
        "y": float(value["y"]) / height,
        "confidence": float(value.get("confidence", 0.0)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True, help="JSON: records, rim, frame_width, frame_height")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    source = json.loads(args.input.read_text(encoding="utf-8"))
    records = source["records"]
    rim = source["rim"]
    width = float(source["frame_width"])
    height = float(source["frame_height"])
    if width <= 0 or height <= 0:
        parser.error("frame_width and frame_height must be positive")

    candidates = find_refined_crossings(records, rim)
    has_validity_flag = any("net_measurement_valid" in item for item in records)
    net_records = [
        item
        for item in records
        if not has_validity_flag or item.get("net_measurement_valid") is True
    ]
    hoop_roi = {
        "left": (float(rim["center_x"]) - float(rim["width"]) / 2) / width,
        "right": (float(rim["center_x"]) + float(rim["width"]) / 2) / width,
        "top": (float(rim["rim_y"]) - float(rim.get("height", 20.0)) / 2) / height,
        "bottom": (float(rim["rim_y"]) + float(rim.get("height", 20.0)) / 2) / height,
    }
    replays = []
    for candidate in candidates:
        trajectory = [
            {
                "time_ms": round(float(item["time"]) * 1000),
                "x": float(item["x"]) / width,
                "y": float(item["y"]) / height,
                "confidence": float(item.get("confidence", 0.0)),
            }
            for item in candidate["overlay"]["trajectory"]
        ]
        replays.append({
            "candidate_id": f"python-{candidate['event_ms']}",
            "hoop_roi": hoop_roi,
            "above": point(candidate["above"], width, height),
            "below": point(candidate["below"], width, height),
            "trajectory": trajectory,
            "net_history": [
                {
                    "time_ms": round(float(item["time"]) * 1000),
                    "upper": float(item.get("net_upper_motion_score", 0.0)),
                    "lower": float(item.get("net_lower_motion_score", 0.0)),
                    "below": float(item.get("net_below_motion_score", 0.0)),
                }
                for item in net_records
            ],
            "expected": {
                key: candidate[key]
                for key in (
                    "algorithm_version",
                    "event_ms",
                    "complete_crossing",
                    "ball_persistence",
                    "rebound",
                    "lateral_exit",
                    "post_crossing_lateral_recovery",
                    "net_signal_available",
                    "net_support",
                    "net_no_motion",
                    "auto_export_eligible",
                    "verdict",
                )
            },
        })

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(
            {
                "schema_version": "bhe-decision-replay-v1",
                "algorithm_version": ANALYSIS_CONTRACT_VERSION,
                "replays": replays,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    print(f"{args.output}: {len(replays)} replay(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
