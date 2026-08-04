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
    parser.add_argument("--hoop-conf", type=float, default=0.3)
    parser.add_argument("--margin", type=float, default=16)
    return parser.parse_args()


def estimate_rim(records, confidence):
    hoops = [
        detection
        for record in records
        for detection in record.get("detections", [])
        if detection["name"] == "hoop" and detection["confidence"] >= confidence
    ]
    if not hoops:
        raise ValueError("No hoop detections found; provide a manual rim calibration instead.")

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
    }


def main(args):
    detections_path = Path(args.detections)
    data = json.loads(detections_path.read_text(encoding="utf-8"))
    rim = estimate_rim(data["records"], args.hoop_conf)
    candidates = find_candidate_crossings(data["records"], rim, margin=args.margin)
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
