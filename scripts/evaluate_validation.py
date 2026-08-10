import argparse
import json
import math
from pathlib import Path

from basketball_highlight.features import normalize_geometry
from basketball_highlight.ranking import dedupe_candidates
from basketball_highlight.validation import binary_metrics
from export_review_queue import is_automatic_goal


POSITIVE_LABELS = {"goal", "miss_then_goal"}
CURRENT_ALGORITHM_VERSION = "python-v2.6-reviewable-crossing-recovery"
CURRENT_SCHEMA_VERSION = 3


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
        for event in _label_events(data)
        if event.get("label") in POSITIVE_LABELS and event.get("id") is not None
    }


def matches_with_rim(data, dedupe_sec):
    matches = []
    for result in data.get("results", []):
        for match in result.get("refined", []):
            if match.get("rim_source") == "box_center_fallback":
                rim = result.get("rim_legacy") or result.get("rim_original") or {}
            else:
                rim = result.get("rim_local") or result.get("rim_original") or {}
            enriched = dict(match)
            enriched["_rim"] = rim
            for key, value in normalize_geometry(match, rim).items():
                enriched.setdefault(key, value)
            matches.append(enriched)
    return dedupe_candidates(matches, dedupe_sec)


def _label_events(data):
    events = data.get("events", [])
    if isinstance(events, dict):
        return [dict(event, id=event.get("id", key)) for key, event in events.items()]
    return [event for event in events if isinstance(event, dict)]


def load_time_labels(label_path):
    data = json.loads(Path(label_path).read_text(encoding="utf-8"))
    goals = []
    for event in _label_events(data):
        event_time = event.get("event_time", event.get("time"))
        if event.get("label") not in POSITIVE_LABELS or event_time is None:
            continue
        goals.append({
            "time": float(event_time),
            "tolerance_seconds": float(
                event.get("tolerance_ms", data.get("default_tolerance_ms", 750))
            ) / 1000,
            "source_id": event.get("source_candidate_index", event.get("id")),
            "label": event.get("label"),
        })
    has_time_binding = data.get("label_binding") == "source_time" or any(
        event.get("event_time", event.get("time")) is not None
        for event in _label_events(data)
    )
    events = _label_events(data)
    unknown_count = sum(
        event.get("label") in {"unknown", "unreviewed", "needs_clarification"}
        for event in events
    )
    declared_count = data.get("candidate_count", data.get("reviewed_candidate_count"))
    reviewed_count = sum(
        event.get("label") not in {None, "unknown", "unreviewed", "needs_clarification"}
        for event in events
    )
    complete_annotation = data.get("complete_annotation") is True
    if data.get("complete_annotation") is None and declared_count is not None:
        complete_annotation = bool(
            unknown_count == 0 and reviewed_count >= int(declared_count)
        )
    return data, goals, has_time_binding, {
        "annotation_scope": data.get("annotation_scope", "candidate_review"),
        "complete_annotation": complete_annotation,
        "reviewed_count": reviewed_count,
        "unknown_count": unknown_count,
    }


def validate_detection(data, allow_legacy=False):
    schema_version = int(data.get("schema_version", 0) or 0)
    algorithm_version = data.get("algorithm_version")
    matches = [
        match
        for result in data.get("results", [])
        for match in result.get("refined", [])
        if isinstance(match, dict)
    ]
    missing_fields = sorted({
        field
        for field in ("verdict", "complete_crossing", "gates")
        if any(field not in match for match in matches)
    })
    current = (
        schema_version >= CURRENT_SCHEMA_VERSION
        and algorithm_version == CURRENT_ALGORITHM_VERSION
        and not missing_fields
    )
    if not current and not allow_legacy:
        raise ValueError(
            "LEGACY_DETECTION_ARTIFACT: 当前评估要求重新运行 v2.3 完整分析；"
            f"schema={schema_version}, algorithm={algorithm_version}, "
            f"missing={missing_fields}"
        )
    return {
        "current": current,
        "schema_version": schema_version,
        "algorithm_version": algorithm_version,
        "missing_fields": missing_fields,
    }


def time_metrics(predictions, truths):
    ordered_predictions = sorted(
        enumerate(predictions),
        key=lambda item: float(item[1]["time"]),
    )
    ordered_truths = sorted(
        enumerate(truths),
        key=lambda item: float(item[1]["time"]),
    )
    rows = len(ordered_predictions) + 1
    columns = len(ordered_truths) + 1
    dp = [[(0, 0.0, ()) for _ in range(columns)] for _ in range(rows)]

    def better(left, right):
        if left[0] != right[0]:
            return left if left[0] > right[0] else right
        return left if left[1] <= right[1] else right

    for prediction_offset in range(1, rows):
        for truth_offset in range(1, columns):
            best = better(
                dp[prediction_offset - 1][truth_offset],
                dp[prediction_offset][truth_offset - 1],
            )
            prediction_index, prediction = ordered_predictions[prediction_offset - 1]
            truth_index, truth = ordered_truths[truth_offset - 1]
            distance = abs(float(prediction["time"]) - float(truth["time"]))
            if distance <= float(truth["tolerance_seconds"]):
                previous = dp[prediction_offset - 1][truth_offset - 1]
                matched = (
                    previous[0] + 1,
                    previous[1] + distance,
                    (*previous[2], (prediction_index, truth_index)),
                )
                best = better(best, matched)
            dp[prediction_offset][truth_offset] = best

    matched_pairs = dp[-1][-1][2]
    matched_predictions = {pair[0] for pair in matched_pairs}
    matched_truths = {pair[1] for pair in matched_pairs}
    tp = len(matched_predictions)
    fp = len(predictions) - tp
    fn = len(truths) - tp
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "true_positive": tp,
        "false_positive": fp,
        "false_negative": fn,
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "f1": round(f1, 4),
        "matched_prediction_indices": sorted(index + 1 for index in matched_predictions),
        "matched_truth_indices": sorted(index + 1 for index in matched_truths),
        "false_positive_predictions": [
            {
                "candidate_id": prediction.get("_candidate_id", index + 1),
                "time": prediction.get("time"),
                "verdict": prediction.get("verdict", "unclassified"),
                "confidence": prediction.get("confidence"),
                "score": prediction.get("score"),
            }
            for index, prediction in enumerate(predictions)
            if index not in matched_predictions
        ],
        "false_negative_truths": [
            truth for index, truth in enumerate(truths) if index not in matched_truths
        ],
    }


def summarize_case(name, detection_path, label_path, dedupe_sec, allow_legacy=False):
    detection_data = json.loads(Path(detection_path).read_text(encoding="utf-8"))
    artifact = validate_detection(detection_data, allow_legacy=allow_legacy)
    matches = matches_with_rim(detection_data, dedupe_sec)
    label_data, goal_events, has_time_binding, annotation = load_time_labels(label_path)
    detection_fingerprint = detection_data.get("video_fingerprint")
    label_fingerprint = label_data.get("source_fingerprint")
    source_match = True
    if isinstance(detection_fingerprint, dict) and isinstance(label_fingerprint, dict):
        source_match = all(
            detection_fingerprint.get(key) == label_fingerprint.get(key)
            for key in ("size_bytes", "mtime_ns")
        )
        if not source_match:
            raise ValueError("SOURCE_MISMATCH: 检测结果与标注不是同一份源视频")
    legacy_labels = not has_time_binding
    goal_ids = load_goal_ids(label_path) if legacy_labels else set()
    predicted_ids = {
        index
        for index, match in enumerate(matches, 1)
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
    if legacy_labels:
        metrics = binary_metrics(predicted_ids, goal_ids)
        candidate_metrics = binary_metrics(candidate_ids, goal_ids)
    else:
        predicted_matches = [
            dict(match, _candidate_id=index)
            for index, match in enumerate(matches, 1)
            if index in predicted_ids
        ]
        candidate_matches = [
            dict(match, _candidate_id=index)
            for index, match in enumerate(matches, 1)
        ]
        metrics = time_metrics(predicted_matches, goal_events)
        candidate_metrics = time_metrics(candidate_matches, goal_events)
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
        "source_fingerprint": detection_fingerprint,
        "source_match": source_match,
        "candidate_count": len(matches),
        "goal_count": len(goal_ids) if legacy_labels else len(goal_events),
        "label_binding": "candidate_index_legacy" if legacy_labels else "source_time",
        "metrics_valid": bool(
            not legacy_labels
            and annotation["complete_annotation"]
            and artifact["current"]
            and source_match
        ),
        "recall_valid": bool(
            not legacy_labels
            and annotation["complete_annotation"]
            and annotation["annotation_scope"] == "full_video"
            and artifact["current"]
            and source_match
        ),
        "annotation": annotation,
        "artifact": artifact,
        "candidate_metrics": candidate_metrics,
        "automatic_goal_ids": sorted(predicted_ids),
        "verdict_counts": verdict_counts,
        "elapsed_seconds": detection_data.get("elapsed_seconds"),
        "cache_hits": detection_data.get("cache_hits"),
        "metrics": metrics,
        "errors": ({
            "false_positive_ids": sorted(predicted_ids - goal_ids),
            "false_negative_ids": sorted(goal_ids - predicted_ids),
            "false_positive_details": error_details(predicted_ids - goal_ids),
            "false_negative_details": error_details(goal_ids - predicted_ids),
        } if legacy_labels else {
            "false_positive_details": metrics["false_positive_predictions"],
            "false_negative_details": metrics["false_negative_truths"],
        }),
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
    parser.add_argument("--allow-legacy", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    report = {
        "dedupe_sec": args.dedupe_sec,
        "case_count": len(args.case),
        "generalization_ready": False,
        "cases": [summarize_case(
            name,
            detections,
            labels,
            args.dedupe_sec,
            allow_legacy=args.allow_legacy,
        )
                  for name, detections, labels in args.case],
    }
    source_keys = {
        json.dumps(case.get("source_fingerprint"), sort_keys=True)
        if case.get("source_fingerprint")
        else case["detection_path"]
        for case in report["cases"]
    }
    report["generalization_ready"] = bool(
        len(report["cases"]) >= 3
        and len(source_keys) >= 3
        and all(case["metrics_valid"] for case in report["cases"])
    )
    Path(args.output).write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8",
    )
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
