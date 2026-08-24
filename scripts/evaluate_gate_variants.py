import argparse
import json
from pathlib import Path

from basketball_highlight.events import calibrated_gates, normalized_calibrated_gates
from basketball_highlight.validation import binary_metrics
from evaluate_validation import load_goal_ids, matches_with_rim


def parse_case(value):
    parts = value.split(":", 2)
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("case must be NAME:DETECTIONS:LABELS")
    return parts


def evaluate(matches, goals, gate):
    predicted = {
        index for index, match in enumerate(matches, 1)
        if gate(match).get("automatic_goal")
    }
    return binary_metrics(predicted, goals)


def main():
    parser = argparse.ArgumentParser(description="Compare absolute and rim-normalized automatic gates.")
    parser.add_argument("--case", action="append", type=parse_case, required=True)
    parser.add_argument("--reference-rim-width", type=float, default=30.54)
    parser.add_argument("--dedupe-sec", type=float, default=2.0)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    cases = []
    for name, detection_path, label_path in args.case:
        data = json.loads(Path(detection_path).read_text(encoding="utf-8"))
        matches = matches_with_rim(data, args.dedupe_sec)
        goals = load_goal_ids(label_path)
        cases.append({
            "name": name,
            "candidate_count": len(matches),
            "goal_count": len(goals),
            "gates": {
                "absolute": evaluate(matches, goals, calibrated_gates),
                "rim_normalized": evaluate(
                    matches, goals,
                    lambda match: normalized_calibrated_gates(match, args.reference_rim_width),
                ),
            },
        })
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "reference_rim_width": args.reference_rim_width,
        "dedupe_sec": args.dedupe_sec,
        "cases": cases,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(cases, ensure_ascii=False, indent=2))
    print(f"output={output.resolve()}")


if __name__ == "__main__":
    main()
