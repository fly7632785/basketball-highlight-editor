import argparse
import hashlib
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.events import find_refined_crossings
from basketball_highlight.ranking import dedupe_candidates
from cache_io import read_json_cache, write_json_cache


DETECTION_CACHE_VERSION = "python-v2.5-white-net-region"
ALGORITHM_VERSION = "python-v2.10-white-net-trajectory"
REFINED_SCHEMA_VERSION = 3


def file_fingerprint(path):
    stat = path.stat()
    return {
        "path": str(path.resolve()),
        "size_bytes": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
    }


def parse_args():
    parser = argparse.ArgumentParser(description="Refine dynamic-rim candidates against the original video.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--coarse", required=True)
    parser.add_argument("--roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"), required=True)
    parser.add_argument("--net-roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"))
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
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps", "cuda"))
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def select_device(requested):
    if requested != "auto":
        return requested
    import torch

    if torch.cuda.is_available():
        return "cuda"
    return "mps" if torch.backends.mps.is_available() else "cpu"


def load_yolo_model(model_path):
    from ultralytics import YOLO

    return YOLO(str(model_path))


def load_scan_window():
    from refine_candidates import scan_window

    return scan_window


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


def _compatible_rims(left, right):
    width = max(1.0, float(left["width"]), float(right["width"]))
    height = max(1.0, float(left.get("height", 20)), float(right.get("height", 20)))
    width_ratio = float(left["width"]) / max(1.0, float(right["width"]))
    return (
        abs(float(left["center_x"]) - float(right["center_x"])) <= width * 0.5
        and abs(float(left["rim_y"]) - float(right["rim_y"])) <= height
        and 0.75 <= width_ratio <= 1.34
    )


def _net_compatible_rims(left, right):
    width = max(1.0, float(left["width"]), float(right["width"]))
    height = max(1.0, float(left.get("height", 20)), float(right.get("height", 20)))
    width_ratio = float(left["width"]) / max(1.0, float(right["width"]))
    # 篮网测量区宽约 4 倍筐宽,rim 估计小幅漂移(无人机悬停微动、
    # 局部估计抖动)不需要作废测量;原 0.18 倍筐宽(约 11px)过严,
    # 导致整段候选的篮网信号全部"未计算"。
    return (
        abs(float(left["center_x"]) - float(right["center_x"])) <= width * 0.40
        and abs(float(left["rim_y"]) - float(right["rim_y"])) <= max(6.0, height * 0.80)
        and 0.70 <= width_ratio <= 1.40
    )


def build_scan_windows(centers, window, rims=None):
    """Merge overlapping windows when they share the same physical hoop."""
    entries = sorted(
        (
            max(0.0, float(center) - window),
            float(center) + window,
            index,
        )
        for index, center in enumerate(centers)
    )
    groups = []
    for start, end, index in entries:
        rim = rims[index] if rims else None
        if (
            groups
            and start <= groups[-1]["end"]
            and (
                rim is None
                or groups[-1]["rim"] is None
                or _compatible_rims(groups[-1]["rim"], rim)
            )
        ):
            groups[-1]["indices"].append(index)
            groups[-1]["end"] = max(groups[-1]["end"], end)
            continue
        groups.append({
            "indices": [index],
            "start": start,
            "end": end,
            "rim": rim,
        })
    return groups


def _records_for_rim(records, scan_rim, decision_rim):
    if _net_compatible_rims(scan_rim, decision_rim):
        return records
    return [
        {**record, "net_measurement_valid": False}
        for record in records
    ]


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
    if len(hoops) < 3:
        return fallback
    centers_x = [item["center"][0] for item in hoops]
    widths = [item["xyxy"][2] - item["xyxy"][0] for item in hoops]
    heights = [item["xyxy"][3] - item["xyxy"][1] for item in hoops]
    raw_top_adjusted_y = [item["center"][1] - (item["xyxy"][3] - item["xyxy"][1]) * 0.28 for item in hoops]
    center_x = statistics.median(centers_x)
    rim_y = statistics.median(raw_top_adjusted_y)
    width = statistics.median(widths)
    center_mad = statistics.median(abs(value - center_x) for value in centers_x)
    rim_y_mad = statistics.median(abs(value - rim_y) for value in raw_top_adjusted_y)
    width_mad = statistics.median(abs(value - width) for value in widths)
    if (
        center_mad > max(4.0, fallback["width"] * 0.18)
        or rim_y_mad > max(4.0, fallback["height"] * 0.35)
        or width_mad > max(3.0, width * 0.22)
    ):
        return fallback
    return {
        "center_x": round(center_x, 2),
        "rim_y": round(rim_y, 2),
        "width": round(width, 2),
        "height": round(statistics.median(heights) * 0.45, 2),
        "source": "local_hoop_track",
        "detections": len(hoops),
    }


def main(args):
    video = Path(args.video).resolve()
    model_path = Path(args.model).resolve()
    video_fingerprint = file_fingerprint(video)
    model_fingerprint = file_fingerprint(model_path)
    coarse_data = json.loads(Path(args.coarse).read_text(encoding="utf-8"))
    device = args.device
    model = None
    scan_window = None
    started = time.perf_counter()
    results = []
    if args.cache_dir:
        args.cache_dir.mkdir(parents=True, exist_ok=True)

    candidates = coarse_data["candidates"]
    print("progress=0.0", flush=True)
    records_by_index = {}
    rims_by_index = {}
    cache_paths_by_index = {}
    legacy_cache_paths_by_index = {}
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
                "algorithm_version": DETECTION_CACHE_VERSION,
                "schema_version": REFINED_SCHEMA_VERSION,
                "video": video_fingerprint,
                "model": model_fingerprint,
                "roi": args.roi,
                "time": round(float(coarse["time"]), 4),
                "window": args.window,
                "sample_fps": args.sample_fps,
                "scale": args.scale,
                "conf": args.conf,
                "batch": args.batch,
                "rim": rim,
                "net_roi": args.net_roi,
                "signal_version": 4,
            }, sort_keys=True).encode()
            # 文件名截断到 24 位避免 Windows MAX_PATH 超限(见 scan_video)。
            cache_path = args.cache_dir / (
                hashlib.sha256(cache_key).hexdigest()[:24] + ".json"
            )
            legacy_cache_paths_by_index[index] = []
        cache_paths_by_index[index] = cache_path
        candidate_cache_paths = [cache_path, *legacy_cache_paths_by_index.get(index, [])]
        cached = None
        cache_source = None
        for candidate_cache_path in candidate_cache_paths:
            if candidate_cache_path and candidate_cache_path.exists():
                cached = read_json_cache(candidate_cache_path, lambda value: isinstance(value, list))
                if cached is not None:
                    cache_source = candidate_cache_path
                    break
        if cached is not None:
            records_by_index[index] = cached
            cache_hits += 1
            if cache_source != cache_path and cache_path:
                write_json_cache(cache_path, cached)
            continue
        if index not in records_by_index:
            missing_indices.append(index)

    missing_centers = [float(candidates[index]["time"]) for index in missing_indices]
    missing_rims = [rims_by_index[index][0] for index in missing_indices]
    scan_groups = build_scan_windows(missing_centers, args.window, missing_rims)
    if scan_groups:
        device = select_device(args.device)
    for group_index, group in enumerate(scan_groups, 1):
        if model is None:
            model = load_yolo_model(model_path)
            scan_window = load_scan_window()
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
            net_roi=args.net_roi,
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
                write_json_cache(cache_path, records)
        scan_progress = 0.5 * group_index / max(1, len(scan_groups))
        print(f"progress={scan_progress:.4f}", flush=True)

    for index, coarse in enumerate(candidates):
        rim, legacy_rim = rims_by_index[index]
        records = records_by_index[index]
        local_rim = estimate_local_rim(records, rim)
        local_records = _records_for_rim(records, rim, local_rim)
        local_matches = find_refined_crossings(local_records, local_rim)
        if local_matches:
            tagged_matches = [
                {**match, "rim_source": "local_track"}
                for match in local_matches
            ]
        else:
            legacy_records = _records_for_rim(records, rim, legacy_rim)
            tagged_matches = [
                {**match, "rim_source": "box_center_fallback"}
                for match in find_refined_crossings(legacy_records, legacy_rim)
            ]
        merged = dedupe_candidates(tagged_matches, 2.0)
        matches = [match for match in merged if match.get("score", 0.0) >= args.min_score]
        results.append({
            "index": index + 1,
            "coarse": coarse,
            "rim_original": rim,
            "rim_local": local_rim,
            "rim_legacy": legacy_rim,
            "refined": matches,
            "sampled_frames": len(records),
            "ball_frames": sum(
                any(
                    str(detection.get("name", "")).lower() == "ball"
                    for detection in record.get("detections", [])
                )
                for record in records
            ),
        })
        refine_progress = 0.5 + 0.5 * (index + 1) / max(1, len(candidates))
        print(f"progress={refine_progress:.4f}", flush=True)
        print(f"{index:03d} coarse={coarse['time']:.2f}s refined={len(matches)}", flush=True)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "schema_version": REFINED_SCHEMA_VERSION,
        "algorithm_version": ALGORITHM_VERSION,
        "video": str(video),
        "video_fingerprint": video_fingerprint,
        "model": str(model_path),
        "model_fingerprint": model_fingerprint,
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
