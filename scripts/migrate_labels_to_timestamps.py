import argparse
import json
from pathlib import Path

from evaluate_validation import matches_with_rim


def _existing_time_events(labels):
    raw_events = labels.get("events", [])
    if isinstance(raw_events, dict):
        raw_events = [
            dict(event, id=event.get("id", key))
            for key, event in raw_events.items()
        ]
    events = []
    for event in raw_events:
        if not isinstance(event, dict):
            continue
        event_time = event.get("event_time", event.get("time"))
        label = event.get("label")
        if event_time is None or label is None:
            continue
        if label in {"unreviewed", "needs_clarification"}:
            label = "unknown"
        events.append({
            "event_time": round(float(event_time), 4),
            "label": label,
            "source_candidate_index": event.get(
                "source_candidate_index", event.get("id")
            ),
            "tolerance_ms": int(event.get("tolerance_ms", 750)),
        })
    if not events:
        for label, key in (("goal", "goals"), ("non_goal", "non_goals")):
            for event_time in labels.get(key, []):
                events.append({
                    "event_time": round(float(event_time), 4),
                    "label": label,
                    "source_candidate_index": None,
                    "tolerance_ms": 750,
                })
    return events


def migrate_labels(detection_path, label_path, dedupe_sec=2.0):
    detections = json.loads(Path(detection_path).read_text(encoding="utf-8"))
    labels = json.loads(Path(label_path).read_text(encoding="utf-8"))
    existing_events = _existing_time_events(labels)
    if existing_events:
        events = existing_events
    else:
        matches = matches_with_rim(detections, dedupe_sec)
        goal_ids = {int(value) for value in labels.get("goal_ids", [])}
        label_ids = {
            "non_goal": {
                int(value)
                for key in ("non_goal_ids", "non_goal_or_no_shot_ids")
                for value in labels.get(key, [])
            },
            "no_shot": {int(value) for value in labels.get("no_shot_ids", [])},
            "unknown": {int(value) for value in labels.get("unreviewed_ids", [])},
        }
        referenced = goal_ids | set().union(*label_ids.values())
        invalid = sorted(
            index for index in referenced if index < 1 or index > len(matches)
        )
        if invalid:
            raise ValueError(f"LABEL_INDEX_OUT_OF_RANGE: {invalid}")
        events = []
        for index, match in enumerate(matches, 1):
            if index in goal_ids:
                label = "goal"
            else:
                label = next(
                    (name for name, ids in label_ids.items() if index in ids),
                    None,
                )
            if label is None:
                continue
            events.append({
                "event_time": round(float(match["time"]), 4),
                "label": label,
                "source_candidate_index": index,
                "tolerance_ms": 750,
            })
    unknown_count = sum(event["label"] == "unknown" for event in events)
    reviewed_count = len(events) - unknown_count
    declared_count = int(
        labels.get(
            "candidate_count",
            labels.get("reviewed_candidate_count", len(events)),
        )
    )
    complete_annotation = bool(
        events
        and unknown_count == 0
        and reviewed_count >= declared_count
    )
    return {
        "source_video": labels.get(
            "source_video", labels.get("video", detections.get("video"))
        ),
        "detection_source": str(detection_path),
        "source_label": str(label_path),
        "version": 2,
        "label_binding": "source_time",
        "annotation_scope": labels.get("annotation_scope", "candidate_review"),
        "candidate_count": declared_count,
        "reviewed_candidate_count": reviewed_count,
        "unknown_count": unknown_count,
        "complete_annotation": complete_annotation,
        "source_fingerprint": detections.get("video_fingerprint"),
        "default_tolerance_ms": 750,
        "events": events,
    }


def main():
    parser = argparse.ArgumentParser(description="Migrate candidate-index labels to source timestamps.")
    parser.add_argument("--detections", required=True)
    parser.add_argument("--labels", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    args = parser.parse_args()
    migrated = migrate_labels(args.detections, args.labels, args.dedupe_sec)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(migrated, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"events={len(migrated['events'])}")
    print(f"output={output}")


if __name__ == "__main__":
    main()
