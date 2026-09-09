#!/usr/bin/env python3
"""Compare the Python decision output with a Rust decision-replay binary."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from export_cross_platform_replay import main as export_replay


NUMERIC_TOLERANCE = 0.01
EVENT_TOLERANCE_MS = 300

FIELDS = (
    "complete_crossing",
    "ball_persistence",
    "rebound",
    "lateral_exit",
    "post_crossing_lateral_recovery",
    "net_signal_available",
    "net_support",
    "net_no_motion",
    "net_score",
    "net_motion_score",
    "net_changed_ratio",
    "net_inside_motion_score",
    "net_sequence_score",
    "net_lower_peak",
    "net_below_peak",
    "strict_low_speed",
    "high_speed_net",
    "high_speed_drop",
    "high_precision",
    "automatic_goal",
    "review",
    "recall_review",
    "verdict",
    "auto_export_eligible",
)


def run_rust(binary: Path, payload: dict) -> dict:
    process = subprocess.run(
        [str(binary), "--decision-replay"],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        raise RuntimeError(process.stderr.strip() or "Rust decision replay failed")
    return json.loads(process.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--rust-binary", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--locked-decision",
        action="store_true",
        help="仅用于旧版 verdict 回归；默认计算 Rust 的全部派生字段",
    )
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="bhe-replay-") as directory:
        replay_path = Path(directory) / "replay.json"
        export_replay([
            "--input", str(args.input),
            "--output", str(replay_path),
            *( ["--locked-decision"] if args.locked_decision else [] ),
        ])
        source = json.loads(replay_path.read_text(encoding="utf-8"))

    rows = []
    for replay in source["replays"]:
        rust = run_rust(args.rust_binary, replay)
        expected = replay["expected"]
        mismatches = {}
        for field in FIELDS:
            python_value = expected.get(field)
            rust_value = rust.get(field)
            if isinstance(python_value, (int, float)) and isinstance(rust_value, (int, float)):
                if not math.isclose(
                    float(python_value),
                    float(rust_value),
                    abs_tol=NUMERIC_TOLERANCE,
                ):
                    mismatches[field] = {
                        "python": python_value,
                        "rust": rust_value,
                        "allowed_abs_delta": NUMERIC_TOLERANCE,
                    }
            elif python_value != rust_value:
                mismatches[field] = {"python": python_value, "rust": rust_value}
        event_delta_ms = abs(
            int(expected.get("event_ms", 0)) - int(rust.get("event_ms", 0))
        )
        if event_delta_ms > EVENT_TOLERANCE_MS:
            mismatches["event_ms"] = {
                "python": expected.get("event_ms"),
                "rust": rust.get("event_ms"),
                "allowed_delta_ms": EVENT_TOLERANCE_MS,
            }
        rows.append({
            "candidate_id": replay["candidate_id"],
            "event_ms": {
                "python": expected.get("event_ms"),
                "rust": rust.get("event_ms"),
            },
            "event_delta_ms": event_delta_ms,
            "mismatches": mismatches,
        })

    mismatch_counts = Counter(
        field
        for row in rows
        for field in row["mismatches"]
    )
    event_deltas = sorted(row["event_delta_ms"] for row in rows)
    matched = sum(not row["mismatches"] for row in rows)
    report = {
        "schema_version": "bhe-decision-replay-report-v1",
        "algorithm_version": source["algorithm_version"],
        "total": len(rows),
        "matched": matched,
        "match_rate": matched / len(rows) if rows else 1.0,
        "summary": {
            "event_tolerance_ms": EVENT_TOLERANCE_MS,
            "numeric_tolerance": NUMERIC_TOLERANCE,
            "event_delta_ms": {
                "max": max(event_deltas, default=0),
                "mean": sum(event_deltas) / len(event_deltas) if event_deltas else 0,
                "p95": event_deltas[min(len(event_deltas) - 1, math.ceil(len(event_deltas) * 0.95) - 1)] if event_deltas else 0,
            },
            "mismatch_counts": dict(sorted(mismatch_counts.items())),
        },
        "rows": rows,
    }
    rendered = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered)
    return 0 if report["matched"] == report["total"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
