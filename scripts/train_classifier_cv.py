import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.classifier import (
    FEATURE_NAMES,
    fit_logistic,
    match_feature_vector,
    predict_proba,
)
from basketball_highlight.validation import binary_metrics
from evaluate_validation import matches_with_rim


def parse_case(value):
    parts = value.split(":", 3)
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("case must be NAME:DETECTIONS:LABELS:AUDIO")
    return parts


def load_goal_ids(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return set(int(item) for item in data.get("goal_ids", []))


def load_case(name, detections_path, labels_path, audio_path, dedupe_sec):
    detections = json.loads(Path(detections_path).read_text(encoding="utf-8"))
    matches = matches_with_rim(detections, dedupe_sec)
    goals = load_goal_ids(labels_path)
    audio_data = json.loads(Path(audio_path).read_text(encoding="utf-8"))
    audio_by_id = {
        int(item["candidate_id"]): item.get("audio", {})
        for item in audio_data.get("candidates", [])
    }
    features = np.asarray([
        match_feature_vector(match, audio_by_id.get(index, {}))
        for index, match in enumerate(matches, 1)
    ])
    labels = np.asarray([
        1.0 if index in goals else 0.0
        for index in range(1, len(matches) + 1)
    ])
    return {
        "name": name,
        "features": features,
        "labels": labels,
        "matches": matches,
        "goal_ids": goals,
    }


def metrics_for(labels, probabilities, threshold):
    predicted = {
        index + 1
        for index, probability in enumerate(probabilities)
        if probability >= threshold
    }
    actual = {index + 1 for index, label in enumerate(labels) if label > 0.5}
    result = binary_metrics(predicted, actual)
    result["threshold"] = round(float(threshold), 4)
    result["f1"] = round(
        2.0 * result["precision"] * result["recall"] /
        max(1e-9, result["precision"] + result["recall"]), 4,
    )
    return result


def choose_threshold(labels, probabilities, min_precision):
    thresholds = sorted(set([0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9] +
                            [round(float(value), 4) for value in probabilities]))
    results = [metrics_for(labels, probabilities, threshold) for threshold in thresholds]
    eligible = [item for item in results if item["true_positive"] and item["precision"] >= min_precision]
    if eligible:
        return max(eligible, key=lambda item: (item["recall"], item["precision"], item["threshold"]))
    return max(results, key=lambda item: (item["f1"], item["precision"], item["recall"]))


def main():
    parser = argparse.ArgumentParser(description="Leave-one-video-out logistic baseline.")
    parser.add_argument("--case", action="append", type=parse_case, required=True,
                        help="NAME:DETECTIONS:LABELS:AUDIO; repeat for each video")
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    parser.add_argument("--min-precision", type=float, default=0.90)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    cases = [load_case(*case, args.dedupe_sec) for case in args.case]
    if len(cases) < 2:
        raise ValueError("at least two videos are required for leave-one-video-out validation")
    folds = []
    for held_out_index, held_out in enumerate(cases):
        train_cases = [case for index, case in enumerate(cases) if index != held_out_index]
        train_features = np.concatenate([case["features"] for case in train_cases])
        train_labels = np.concatenate([case["labels"] for case in train_cases])
        model = fit_logistic(train_features, train_labels)
        train_probabilities = predict_proba(model, train_features)
        threshold_result = choose_threshold(
            train_labels, train_probabilities, args.min_precision,
        )
        test_probabilities = predict_proba(model, held_out["features"])
        test_metrics = metrics_for(
            held_out["labels"], test_probabilities, threshold_result["threshold"],
        )
        predictions = []
        for index, (match, label, probability) in enumerate(
            zip(held_out["matches"], held_out["labels"], test_probabilities), 1
        ):
            predictions.append({
                "candidate_id": index,
                "event_time": match["time"],
                "actual_goal": bool(label),
                "probability": round(float(probability), 5),
                "predicted_goal": bool(probability >= threshold_result["threshold"]),
            })
        folds.append({
            "held_out": held_out["name"],
            "train_cases": [case["name"] for case in train_cases],
            "feature_names": list(FEATURE_NAMES),
            "threshold_selection": threshold_result,
            "train_metrics": metrics_for(
                train_labels, train_probabilities, threshold_result["threshold"],
            ),
            "test_metrics": test_metrics,
            "predictions": predictions,
        })

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "model": "regularized_logistic",
        "validation": "leave_one_video_out",
        "dedupe_sec": args.dedupe_sec,
        "min_precision_for_threshold": args.min_precision,
        "folds": folds,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(folds, ensure_ascii=False, indent=2))
    print(f"output={output.resolve()}")


if __name__ == "__main__":
    main()
