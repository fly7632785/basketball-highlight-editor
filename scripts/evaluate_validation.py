import argparse
import json
import math
from pathlib import Path

from basketball_highlight.features import normalize_geometry
from basketball_highlight.validation import binary_metrics
from export_review_queue import is_automatic_goal, unique_matches


def parse_case(value):
    parts = value.split(":", 2)
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("case must be NAME:DETECTIONS:LABELS")
    return parts


def load_goal_ids(label_path):
    data = json.loads(Path(label_path).read_text(encoding="utf-8"))
    if "goal_ids" in data:
        return set(int(item) for item in data["goal_ids"])
    return {
        int(event["id"])
        for event in data.get("events", [])
        if event.get("label") == "goal"
    }


def matches_with_rim(data, dedupe_sec):
    matches = []
    for result in data.get("results", []):
        rim = result.get("rim_local") or result.get("rim_original") or {}
        for match in result.get("refined", []):
            enriched = dict(match)
            enriched["_rim"] = rim
            enriched.update(normalize_geometry(match, rim))
            matches.append(enriched)
    matches.sort(key=lambda item: float(item["time"]))
    unique = []
    for match in matches:
        if not unique or float(match["time"]) - float(unique[-1]["time"]) > dedupe_sec:
            unique.append(match)
        elif float(match.get("score", 0.0)) > float(unique[-1].get("score", 0.0)):
            unique[-1] = match
    return unique


def summarize_case(name, detection_path, label_path, dedupe_sec):
    detection_data = json.loads(Path(detection_path).read_text(encoding="utf-8"))
    matches = matches_with_rim(detection_data, dedupe_sec)
    goal_ids = load_goal_ids(label_path)
    predicted_ids = {
        index for index, match in enumerate(matches, 1)
        if is_automatic_goal(match)
    }
    candidate_ids = set(range(1, len(matches) + 1))
    verdict_counts = {}
    for match in matches:
        verdict = match.get("verdict", "unclassified")
        verdict_counts[verdict] = verdict_counts.get(verdict, 0) + 1

    def error_details(ids):
        return [
            {
                "id": index,
                "time": match.get("time"),
                "verdict": match.get("verdict", "unclassified"),
                "confidence": match.get("confidence"),
                "score": match.get("score"),
                "gates": match.get("gates", {}),
                "verification": match.get("verification", {}),
            }
            for index, match in enumerate(matches, 1)
            if index in ids
        ]
    metrics = binary_metrics(predicted_ids, goal_ids)
    normalized = []
    for match in matches:
        normalized.append(normalize_geometry(match, match.get("_rim", {})))

    def mean(field):
        values = [float(item[field]) for item in normalized]
        return sum(values) / len(values) if values else 0.0

    def std(field):
        values = [float(item[field]) for item in normalized]
        if not values:
            return 0.0
        average = sum(values) / len(values)
        return math.sqrt(sum((value - average) ** 2 for value in values) / len(values))

    return {
        "name": name,
        "detection_path": str(Path(detection_path).resolve()),
        "label_path": str(Path(label_path).resolve()),
        "candidate_count": len(matches),
        "goal_count": len(goal_ids),
        "candidate_metrics": binary_metrics(candidate_ids, goal_ids),
        "automatic_goal_ids": sorted(predicted_ids),
        "verdict_counts": verdict_counts,
        "elapsed_seconds": detection_data.get("elapsed_seconds"),
        "cache_hits": detection_data.get("cache_hits"),
        "metrics": metrics,
        "errors": {
            "false_positive_ids": sorted(predicted_ids - goal_ids),
            "false_negative_ids": sorted(goal_ids - predicted_ids),
            "false_positive_details": error_details(predicted_ids - goal_ids),
            "false_negative_details": error_details(goal_ids - predicted_ids),
        },
        "rim_scale": {
            "width_mean_px": mean("rim_width_px"),
            "width_std_px": std("rim_width_px"),
            "speed_per_rim_mean": mean("speed_per_rim"),
            "span_per_rim_mean": mean("approach_span_per_rim"),
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Evaluate basketball detection across labelled videos.")
    parser.add_argument("--case", action="append", type=parse_case, required=True,
                        help="NAME:DETECTIONS:LABELS; repeat for each video")
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    report = {
        "dedupe_sec": args.dedupe_sec,
        "case_count": len(args.case),
        "generalization_ready": len(args.case) >= 3,
        "cases": [summarize_case(name, detections, labels, args.dedupe_sec)
                  for name, detections, labels in args.case],
    }
    Path(args.output).write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
