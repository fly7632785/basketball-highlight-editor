import argparse
import hashlib
import json
import statistics
import sys
import time
from pathlib import Path

import torch
from ultralytics import YOLO

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.events import find_refined_crossings
from refine_candidates import scan_window


def parse_args():
    parser = argparse.ArgumentParser(description="Refine dynamic-rim candidates against the original video.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--coarse", required=True)
    parser.add_argument("--roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"), required=True)
    parser.add_argument("--proxy-scale", type=float, default=2.0)
    parser.add_argument("--window", type=float, default=2.5)
    parser.add_argument("--sample-fps", type=float, default=30)
    parser.add_argument("--scale", type=int, default=2)
    parser.add_argument("--conf", type=float, default=0.10)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--cache-dir", type=Path,
                        help="Optional directory for per-window detection caches.")
    parser.add_argument("--min-score", type=float, default=0.0,
                        help="Keep only crossings at or above this multi-signal score.")
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps"))
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def select_device(requested):
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def scale_rim(rim, factor, correct_plane=True):
    raw_height = rim.get("height", 20)
    return {
        "center_x": rim["center_x"] * factor,
        # The YOLO hoop box is taller than the physical rim and its center is
        # below the rim plane. Calibrate the geometric plane from the box top
        # rather than treating the box center as the rim line.
        "rim_y": ((rim["rim_y"] - raw_height * 0.28) if correct_plane else rim["rim_y"]) * factor,
        "width": rim["width"] * factor,
        "height": raw_height * factor * (0.45 if correct_plane else 1.0),
        "source": "hoop_box_plane" if correct_plane else "hoop_box_center",
    }


def merge_scan_windows(centers, window):
    """Merge overlapping candidate windows for one sequential video pass."""
    groups = []
    for index, center in sorted(enumerate(centers), key=lambda item: item[1]):
        start = max(0.0, float(center) - window)
        end = float(center) + window
        if not groups or start > groups[-1]["end"]:
            groups.append({"indices": [index], "start": start, "end": end})
        else:
            groups[-1]["indices"].append(index)
            groups[-1]["end"] = max(groups[-1]["end"], end)
    return groups


def estimate_local_rim(records, fallback):
    candidates = [
        item
        for record in records
        for item in record.get("detections", [])
        if item.get("name") == "hoop" and item.get("confidence", 0.0) >= 0.35
    ]
    hoops = []
    for item in candidates:
        cx, cy = item["center"]
        width = item["xyxy"][2] - item["xyxy"][0]
        height = item["xyxy"][3] - item["xyxy"][1]
        if abs(cx - fallback["center_x"]) > 220 or abs(cy - fallback["rim_y"]) > 180:
            continue
        if not 0.45 * fallback["width"] <= width <= 1.9 * fallback["width"]:
            continue
        if not 0.45 * fallback["height"] <= height * 0.45 <= 1.9 * fallback["height"]:
            continue
        hoops.append(item)
    if not hoops:
        return fallback
    centers_x = [item["center"][0] for item in hoops]
    widths = [item["xyxy"][2] - item["xyxy"][0] for item in hoops]
    heights = [item["xyxy"][3] - item["xyxy"][1] for item in hoops]
    raw_top_adjusted_y = [item["center"][1] - (item["xyxy"][3] - item["xyxy"][1]) * 0.28 for item in hoops]
    return {
        "center_x": round(statistics.median(centers_x), 2),
        "rim_y": round(statistics.median(raw_top_adjusted_y), 2),
        "width": round(statistics.median(widths), 2),
        "height": round(statistics.median(heights) * 0.45, 2),
        "source": "local_hoop_track",
        "detections": len(hoops),
    }


def main(args):
    video = Path(args.video)
    coarse_data = json.loads(Path(args.coarse).read_text(encoding="utf-8"))
    device = select_device(args.device)
    model = YOLO(str(args.model))
    started = time.perf_counter()
    results = []
    if args.cache_dir:
        args.cache_dir.mkdir(parents=True, exist_ok=True)

    candidates = coarse_data["candidates"]
    records_by_index = {}
    rims_by_index = {}
    cache_paths_by_index = {}
    missing_indices = []
    cache_hits = 0
    for index, coarse in enumerate(candidates):
        proxy_rim = coarse.get("rim", coarse_data.get("rim"))
        if not proxy_rim:
            raise ValueError("Coarse candidate is missing rim calibration")
        rim = scale_rim(proxy_rim, args.proxy_scale)
        rims_by_index[index] = (rim, scale_rim(proxy_rim, args.proxy_scale, correct_plane=False))
        cache_path = None
        if args.cache_dir:
            cache_key = json.dumps({
                "video": str(video.resolve()),
                "model": str(Path(args.model).resolve()),
                "roi": args.roi,
                "time": round(float(coarse["time"]), 4),
                "window": args.window,
                "sample_fps": args.sample_fps,
                "scale": args.scale,
                "conf": args.conf,
                "scan_version": 2,
            }, sort_keys=True).encode()
            cache_path = args.cache_dir / (hashlib.sha256(cache_key).hexdigest() + ".json")
        cache_paths_by_index[index] = cache_path
        if cache_path and cache_path.exists():
            records_by_index[index] = json.loads(cache_path.read_text(encoding="utf-8"))
            cache_hits += 1
        else:
            missing_indices.append(index)

    missing_centers = [float(candidates[index]["time"]) for index in missing_indices]
    scan_groups = merge_scan_windows(missing_centers, args.window)
    for group in scan_groups:
        group_indices = [missing_indices[item] for item in group["indices"]]
        group_rim = rims_by_index[group_indices[0]][0]
        merged_records = scan_window(
            model,
            video,
            args.roi,
            (group["start"] + group["end"]) / 2.0,
            0.0,
            args.sample_fps,
            args.scale,
            args.conf,
            device,
            group_rim,
            args.batch,
            start_time_override=group["start"],
            end_time_override=group["end"],
        )
        for index in group_indices:
            center = float(candidates[index]["time"])
            records = [
                record for record in merged_records
                if center - args.window <= record["time"] <= center + args.window
            ]
            records_by_index[index] = records
            cache_path = cache_paths_by_index[index]
            if cache_path:
                cache_path.write_text(json.dumps(records, ensure_ascii=False), encoding="utf-8")

    for index, coarse in enumerate(candidates):
        rim, legacy_rim = rims_by_index[index]
        records = records_by_index[index]
        local_rim = estimate_local_rim(records, rim)
        local_matches = find_refined_crossings(records, local_rim)
        legacy_matches = find_refined_crossings(records, legacy_rim)
        tagged_matches = (
            [(match, "local_track") for match in local_matches] +
            [(match, "box_center_fallback") for match in legacy_matches]
        )
        merged = []
        for match, source in sorted(tagged_matches, key=lambda item: item[0]["time"]):
            match = dict(match)
            match["rim_source"] = source
            if merged and match["time"] - merged[-1]["time"] <= 1.0:
                if match["score"] > merged[-1]["score"]:
                    merged[-1] = match
            else:
                merged.append(match)
        matches = [match for match in merged if match.get("score", 0.0) >= args.min_score]
        results.append({
            "index": index + 1,
            "coarse": coarse,
            "rim_original": rim,
            "rim_local": local_rim,
            "rim_legacy": legacy_rim,
            "refined": matches,
            "sampled_frames": len(records),
            "ball_frames": sum(bool(record["detections"]) for record in records),
        })
        print(f"{index:03d} coarse={coarse['time']:.2f}s refined={len(matches)}", flush=True)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": str(video),
        "model": str(args.model),
        "device": device,
        "roi": args.roi,
        "proxy_scale": args.proxy_scale,
        "window": args.window,
        "sample_fps": args.sample_fps,
        "min_score": args.min_score,
        "batch": args.batch,
        "cache_dir": str(args.cache_dir) if args.cache_dir else None,
        "cache_hits": cache_hits,
        "scan_groups": len(scan_groups),
        "results": results,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"kept={sum(bool(item['refined']) for item in results)} / {len(results)}")
    print(f"output={output}")


if __name__ == "__main__":
    main(parse_args())
