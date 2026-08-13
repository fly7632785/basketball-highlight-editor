import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.events import calibrated_gates
from export_review_queue import unique_matches


def audio_status(audio):
    value = audio.get("rms_db_delta")
    if value is None:
        return "unknown"
    value = float(value)
    if value >= 3.0:
        return "strong_spike"
    if value >= 1.0:
        return "weak_spike"
    return "no_spike"


def parse_args():
    parser = argparse.ArgumentParser(description="Build an automated error-analysis queue.")
    parser.add_argument("--detections", required=True)
    parser.add_argument("--labels", required=True)
    parser.add_argument("--audio")
    parser.add_argument("--output", required=True)
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    return parser.parse_args()


def load_goal_ids(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return set(int(item) for item in data.get("goal_ids", []))


def build_rows(detections_path, labels_path, audio_path, dedupe_sec):
    detections = json.loads(Path(detections_path).read_text(encoding="utf-8"))
    matches = unique_matches(detections, dedupe_sec)
    goal_ids = load_goal_ids(labels_path)
    audio_by_id = {}
    if audio_path:
        audio_data = json.loads(Path(audio_path).read_text(encoding="utf-8"))
        audio_by_id = {
            int(item["candidate_id"]): item.get("audio", {})
            for item in audio_data.get("candidates", [])
        }
    rows = []
    for candidate_id, match in enumerate(matches, 1):
        actual_goal = candidate_id in goal_ids
        automatic_goal = bool(calibrated_gates(match).get("automatic_goal"))
        if actual_goal == automatic_goal:
            continue
        prediction = match.get("prediction") or {}
        audio = audio_by_id.get(candidate_id, {})
        rows.append({
            "candidate_id": candidate_id,
            "event_time": match["time"],
            "error_class": "false_positive" if automatic_goal else "false_negative",
            "visual_cause": "",
            "trajectory_status": (
                "prediction_review_hit" if match.get("gates", {}).get("prediction_review")
                else "prediction_available_low" if prediction else "no_prediction"
            ),
            "audio_status": audio_status(audio),
            "audio_rms_db_delta": audio.get("rms_db_delta", ""),
            "audio_rms_ratio": audio.get("rms_ratio", ""),
            "automatic_goal": automatic_goal,
            "actual_goal": actual_goal,
            "notes": "人工补充：擦筐/传球/反弹/遮挡/轨迹断裂/重复/其他",
        })
    return rows


def main(args):
    rows = build_rows(args.detections, args.labels, args.audio, args.dedupe_sec)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()) if rows else ["candidate_id"])
        writer.writeheader()
        writer.writerows(rows)
    print(json.dumps({
        "error_count": len(rows),
        "by_error_class": dict(Counter(row["error_class"] for row in rows)),
        "by_trajectory_status": dict(Counter(row["trajectory_status"] for row in rows)),
        "by_audio_status": dict(Counter(row["audio_status"] for row in rows)),
        "output": str(output.resolve()),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main(parse_args())
