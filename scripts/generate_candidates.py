import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.events import find_candidate_crossings


def parse_args():
    parser = argparse.ArgumentParser(description="Generate initial candidate events from a detection log.")
    parser.add_argument("--detections", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--hoop-conf",
        type=float,
        default=0.08,
        help="篮筐检测最低置信度；专用模型通常在 0.08~0.20 之间",
    )
    parser.add_argument("--margin", type=float, default=16)
    parser.add_argument("--max-gap-sec", type=float, default=2.5)
    parser.add_argument("--min-descent-px", type=float, default=20)
    return parser.parse_args()


def estimate_rim(records, confidence):
    all_hoops = [
        detection
        for record in records
        for detection in record.get("detections", [])
        if detection["name"] == "hoop"
    ]
    used_confidence = confidence
    hoops = [item for item in all_hoops if item["confidence"] >= used_confidence]
    if not hoops and all_hoops:
        # The bundled shot model often finds the rim correctly with a low
        # confidence score. Prefer its best detections over failing the job.
        best_confidence = max(item["confidence"] for item in all_hoops)
        fallback = max(0.05, best_confidence * 0.5)
        used_confidence = fallback
        hoops = [item for item in all_hoops if item["confidence"] >= fallback]
    if not hoops:
        raise ValueError(
            "No hoop detections found; check the ROI or provide a manual rim calibration."
        )

    centers_x = [item["center"][0] for item in hoops]
    centers_y = [item["center"][1] for item in hoops]
    widths = [item["xyxy"][2] - item["xyxy"][0] for item in hoops]
    heights = [item["xyxy"][3] - item["xyxy"][1] for item in hoops]
    return {
        "center_x": round(statistics.median(centers_x), 2),
        "rim_y": round(statistics.median(centers_y), 2),
        "width": round(statistics.median(widths), 2),
        "height": round(statistics.median(heights), 2),
        "source": "median_hoop_detections",
        "confidence_threshold": round(used_confidence, 4),
    }


def main(args):
    detections_path = Path(args.detections)
    data = json.loads(detections_path.read_text(encoding="utf-8"))
    rim = estimate_rim(data["records"], args.hoop_conf)
    candidates = find_candidate_crossings(
        data["records"], rim,
        max_gap_sec=args.max_gap_sec,
        margin=args.margin,
        min_descent_px=args.min_descent_px,
    )
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": data["video"],
        "model": data["model"],
        "rim": rim,
        "candidates": candidates,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"rim={rim}")
    print(f"candidates={len(candidates)}")
    for candidate in candidates:
        print(f"{candidate['time']:.2f}s x_cross={candidate['x_cross']}")


if __name__ == "__main__":
    main(parse_args())
