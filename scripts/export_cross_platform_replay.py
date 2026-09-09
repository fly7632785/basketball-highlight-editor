#!/usr/bin/env python3
"""Export Python refined candidates as ONNX-free Rust decision replays."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from basketball_highlight.events import (
    ANALYSIS_CONTRACT_VERSION,
    _zone_signal_value,
    find_refined_crossings,
)


def point(value: dict, width: float, height: float) -> dict:
    result = {
        "time_ms": round(float(value["time"]) * 1000),
        "x": float(value["x"]) / width,
        "y": float(value["y"]) / height,
        "confidence": float(value.get("confidence", 0.0)),
    }
    if value.get("width") is not None:
        result["width"] = float(value["width"]) / width
    if value.get("height") is not None:
        result["height"] = float(value["height"]) / height
    return result


def multi_zone_signal(record: dict, zone: str) -> float:
    """The zone signal used by Python `_multi_signal_features`."""
    return max(
        float(record.get(f"net_{zone}_motion_score", 0.0)),
        float(record.get(f"net_{zone}_orange_score", 0.0)),
        float(record.get(f"net_{zone}_white_motion_score", 0.0)),
        float(record.get(f"net_{zone}_downward_motion_score", 0.0)),
    )


def candidate_rim(candidate: dict, fallback: dict) -> dict:
    overlay = candidate.get("overlay")
    overlay_rim = overlay.get("rim") if isinstance(overlay, dict) else None
    if isinstance(overlay_rim, dict) and all(
        key in overlay_rim for key in ("center_x", "rim_y", "width")
    ):
        return overlay_rim
    return fallback


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True, help="JSON: records, rim, frame_width, frame_height")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--locked-decision",
        action="store_true",
        help=(
            "保留 Python 候选的派生字段，仅用于隔离 verdict 规则；"
            "默认回放只传原始轨迹和篮网时序信号"
        ),
    )
    args = parser.parse_args(argv)

    source = json.loads(args.input.read_text(encoding="utf-8"))
    records = source["records"]
    rim = source["rim"]
    width = float(source["frame_width"])
    height = float(source["frame_height"])
    if width <= 0 or height <= 0:
        parser.error("frame_width and frame_height must be positive")

    candidates = find_refined_crossings(records, rim, include_replay_trajectory=True)
    # Match both Python net paths: legacy records without the flag are usable
    # only when they actually contain net measurements. A record with no net
    # fields is not a measured zero-motion frame.
    explicit_net_validity = any("net_measurement_valid" in item for item in records)
    net_records = records
    replays = []
    for candidate in candidates:
        decision_rim = candidate_rim(candidate, rim)
        hoop_roi = {
            "left": (float(decision_rim["center_x"]) - float(decision_rim["width"]) / 2) / width,
            "right": (float(decision_rim["center_x"]) + float(decision_rim["width"]) / 2) / width,
            "top": (float(decision_rim["rim_y"]) - float(decision_rim.get("height", 20.0)) / 2) / height,
            "bottom": (float(decision_rim["rim_y"]) + float(decision_rim.get("height", 20.0)) / 2) / height,
        }
        trajectory = [
            {
                "time_ms": round(float(item["time"]) * 1000),
                "x": float(item["x"]) / width,
                "y": float(item["y"]) / height,
                "confidence": float(item.get("confidence", 0.0)),
                "width": float(item.get("width", 0.0)) / width,
                "height": float(item.get("height", 0.0)) / height,
            }
            for item in candidate.get(
                "replay_trajectory",
                candidate["overlay"]["trajectory"],
            )
        ]
        replay = {
            "candidate_id": f"python-{candidate['event_ms']}",
            "hoop_roi": hoop_roi,
            "frame_width": int(width),
            "frame_height": int(height),
            # This ratio is reconstructed from the crossing pair rather than
            # copied from the rounded UI candidate. It is a geometry input,
            # not a decision override.
            "horizontal_ratio": abs(
                float(candidate["below"]["x"]) - float(candidate["above"]["x"])
            ) / max(
                1.0,
                float(candidate["below"]["y"]) - float(candidate["above"]["y"]),
            ),
            "above": point(candidate["above"], width, height),
            "below": point(candidate["below"], width, height),
            "trajectory": trajectory,
            "net_history": [
                {
                    "time_ms": round(float(item["time"]) * 1000),
                    "measurement_valid": (
                        item.get("net_measurement_valid") is True
                        if explicit_net_validity
                        else any(
                            key.startswith("net_") and key != "net_measurement_valid"
                            for key in item
                        )
                    ),
                    # Export the same effective per-zone signal that Python
                    # feeds into _net_inside_motion_features. Exporting only
                    # one raw field here made Rust replay a different signal
                    # whenever orange/white/downward evidence was stronger.
                    "upper": multi_zone_signal(item, "upper"),
                    "lower": multi_zone_signal(item, "lower"),
                    "below": multi_zone_signal(item, "below"),
                    "lower_inside": _zone_signal_value(item, "lower"),
                    "below_inside": _zone_signal_value(item, "below"),
                    "upper_components": [
                        float(item.get("net_upper_motion_score", 0.0)),
                        float(item.get("net_upper_orange_score", 0.0)),
                        float(item.get("net_upper_white_motion_score", 0.0)),
                        float(item.get("net_upper_downward_motion_score", 0.0)),
                    ],
                    "lower_components": [
                        float(item.get("net_lower_motion_score", 0.0)),
                        float(item.get("net_lower_orange_score", 0.0)),
                        float(item.get("net_lower_white_motion_score", 0.0)),
                        float(item.get("net_lower_downward_motion_score", 0.0)),
                    ],
                    "below_components": [
                        float(item.get("net_below_motion_score", 0.0)),
                        float(item.get("net_below_orange_score", 0.0)),
                        float(item.get("net_below_white_motion_score", 0.0)),
                        float(item.get("net_below_downward_motion_score", 0.0)),
                    ],
                    "motion": float(item.get("net_motion_score", 0.0)),
                    "changed_ratio": float(item.get("net_changed_ratio", 0.0)),
                    # Preserve the Python fallback exactly. A missing
                    # net_whole_signal_score falls back to the legacy global
                    # motion field, not to the maximum zone signal; replacing
                    # it with a zone maximum changes net_score on replay.
                    "whole": float(item.get(
                        "net_whole_signal_score",
                        min(1.0, float(item.get("net_motion_score", 0.0)) / 18.0),
                    )),
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
        }
        replay["expected"]["net_score"] = float(
            candidate.get("signals", {}).get("net_score", candidate.get("net_score", 0.0))
        )
        if args.locked_decision:
            # Keep the old mode available for verdict-only regression tests,
            # but never use it as the default: these values are already the
            # Python result and would hide Rust algorithm differences.
            replay.update({
                "candidate_speed_per_rim": candidate.get("speed_per_rim"),
                "candidate_approach_span_per_rim": candidate.get("approach_span_per_rim"),
                "candidate_horizontal_ratio": replay["horizontal_ratio"],
                "candidate_complete_crossing": candidate.get("complete_crossing"),
                "candidate_ball_persistence": candidate.get("ball_persistence"),
                "candidate_rebound": candidate.get("rebound"),
                "candidate_lateral_exit": candidate.get("lateral_exit"),
                "candidate_post_crossing_lateral_recovery": candidate.get(
                    "post_crossing_lateral_recovery"
                ),
                "candidate_score": float(candidate.get("score", 0.0)),
                "candidate_net_score": float(
                    candidate.get("signals", {}).get("net_score", candidate.get("net_score", 0.0))
                ),
                "candidate_net_motion_score": float(candidate.get("net_motion_score", 0.0)),
                "candidate_net_changed_ratio": float(candidate.get("net_changed_ratio", 0.0)),
                "candidate_net_signal_available": bool(
                    candidate.get(
                        "net_signal_available",
                        candidate.get("signals", {}).get("net_signal_available", False),
                    )
                ),
                "candidate_net_no_motion": bool(
                    candidate.get(
                        "net_no_motion",
                        candidate.get("signals", {}).get("net_no_motion", False),
                    )
                ),
                "candidate_net_support": bool(
                    candidate.get(
                        "net_support",
                        candidate.get("signals", {}).get("net_support", False),
                    )
                ),
                "candidate_net_inside_motion_score": float(
                    candidate.get(
                        "net_inside_motion_score",
                        candidate.get("signals", {}).get("net_inside_motion_score", 0.0),
                    )
                ),
                "candidate_net_sequence_score": float(
                    candidate.get(
                        "net_sequence_score",
                        candidate.get("signals", {}).get("net_sequence_score", 0.0),
                    )
                ),
                "candidate_net_lower_peak": float(
                    candidate.get(
                        "net_lower_peak",
                        candidate.get("signals", {}).get("net_lower_peak", 0.0),
                    )
                ),
                "candidate_net_below_peak": float(
                    candidate.get(
                        "net_below_peak",
                        candidate.get("signals", {}).get("net_below_peak", 0.0),
                    )
                ),
            })
        replays.append(replay)
        replays[-1]["expected"].update({
            "net_motion_score": float(candidate.get("net_motion_score", 0.0)),
            "net_changed_ratio": float(candidate.get("net_changed_ratio", 0.0)),
            "net_inside_motion_score": float(
                candidate.get(
                    "net_inside_motion_score",
                    candidate.get("signals", {}).get("net_inside_motion_score", 0.0),
                )
            ),
            "net_sequence_score": float(
                candidate.get(
                    "net_sequence_score",
                    candidate.get("signals", {}).get("net_sequence_score", 0.0),
                )
            ),
            "net_lower_peak": float(
                candidate.get(
                    "net_lower_peak",
                    candidate.get("signals", {}).get("net_lower_peak", 0.0),
                )
            ),
            "net_below_peak": float(
                candidate.get(
                    "net_below_peak",
                    candidate.get("signals", {}).get("net_below_peak", 0.0),
                )
            ),
            "high_precision": bool(candidate.get("gates", {}).get("high_precision", False)),
            "automatic_goal": bool(candidate.get("gates", {}).get("automatic_goal", False)),
            "review": bool(candidate.get("gates", {}).get("review", False)),
            "recall_review": bool(candidate.get("gates", {}).get("recall_review", False)),
            "strict_low_speed": bool(candidate.get("gates", {}).get("strict_low_speed", False)),
            "high_speed_net": bool(candidate.get("gates", {}).get("high_speed_net", False)),
            "high_speed_drop": bool(candidate.get("gates", {}).get("high_speed_drop", False)),
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
