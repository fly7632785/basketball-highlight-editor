import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.events import find_candidate_crossings
from basketball_highlight.ranking import dedupe_candidates


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
    parser.add_argument(
        "--rim-window-sec",
        type=float,
        default=30.0,
        help="篮筐漂移检测窗口;各窗口 rim 一致(固定机位)时回退全局估计,行为不变",
    )
    parser.add_argument(
        "--rim-band-seeds",
        action="store_true",
        help="筐带单次目击也发弱种子候选,交给 refine 密扫裁决;"
        "仅精化启用时由管线传入,快速模式(粗扫直出)不发种子",
    )
    return parser.parse_args()


def _hoops_from(hoops, confidence):
    used_confidence = confidence
    selected = [item for item in hoops if item["confidence"] >= used_confidence]
    if not selected and hoops:
        # The bundled shot model often finds the rim correctly with a low
        # confidence score. Prefer its best detections over failing the job.
        best_confidence = max(item["confidence"] for item in hoops)
        fallback = max(0.05, best_confidence * 0.5)
        used_confidence = fallback
        selected = [item for item in hoops if item["confidence"] >= fallback]
    if not selected:
        return None
    centers_x = [item["center"][0] for item in selected]
    centers_y = [item["center"][1] for item in selected]
    widths = [item["xyxy"][2] - item["xyxy"][0] for item in selected]
    heights = [item["xyxy"][3] - item["xyxy"][1] for item in selected]
    return {
        "center_x": round(statistics.median(centers_x), 2),
        "rim_y": round(statistics.median(centers_y), 2),
        "width": round(statistics.median(widths), 2),
        "height": round(statistics.median(heights), 2),
        "source": "median_hoop_detections",
        "confidence_threshold": round(used_confidence, 4),
    }


def estimate_rim(records, confidence):
    all_hoops = [
        detection
        for record in records
        for detection in record.get("detections", [])
        if detection["name"] == "hoop"
    ]
    rim = _hoops_from(all_hoops, confidence)
    if rim is None:
        raise ValueError(
            "No hoop detections found; check the ROI or provide a manual rim calibration."
        )
    return rim


def find_rim_band_seeds(records, rim, pair_candidates, dedupe_sec=2.0, max_seeds=100):
    """筐带单次目击的弱种子候选(--rim-band-seeds 时启用)。

    粗扫采样下,一次出手常常只留下单侧检测点(筐上或筐下各一帧),凑不齐
    find_candidate_crossings 要求的 above/below 对——小球、远景或集锦视频
    因此大量漏检(实测 36 秒集锦只出 2 个候选,而 refine 密扫能确认 7 个
    穿框)。把「球出现在筐带」本身作为候选交给 refine:refine 在候选
    ±window 内以 10fps 密扫重新判定穿框,串不出轨迹的种子会被丢弃,
    误报的代价只是多跑几个精化窗口。
    """
    width = max(1.0, float(rim["width"]))
    height = max(1.0, float(rim.get("height", 20)))
    center_x = float(rim["center_x"])
    rim_y = float(rim["rim_y"])
    x_min, x_max = center_x - width * 1.5, center_x + width * 1.5
    y_min, y_max = rim_y - height * 4.0, rim_y + height * 4.0
    anchors = [float(candidate["time"]) for candidate in pair_candidates]
    sightings = []
    for record in records:
        for detection in record.get("detections", []):
            if detection["name"] != "ball":
                continue
            x, y = detection["center"]
            if not (x_min <= x <= x_max and y_min <= y <= y_max):
                continue
            sightings.append({
                "time": float(record["time"]),
                "x_cross": int(round(x)),
                # 与配对候选的 above/below 同构(扁平 x/y/time):refine 的
                # 兜底轨迹路径直接读 above["x"] 做锚点,原始检测格式会崩。
                "above": {
                    "time": float(record["time"]),
                    "x": float(x),
                    "y": float(y),
                    "confidence": float(detection.get("confidence", 0.0)),
                },
                "below": None,
                "seed": "rim_band_sighting",
            })
    # 筐上目击(下落弧线,比筐下静态误检更像出手)优先,其次置信度。
    sightings.sort(key=lambda item: (
        0 if item["above"]["y"] < rim_y else 1,
        -float(item["above"]["confidence"]),
        item["time"],
    ))
    seeds = []
    for sighting in sightings:
        if len(seeds) >= max_seeds:
            break
        if any(abs(sighting["time"] - anchor) < dedupe_sec for anchor in anchors):
            continue
        # A later sighting above the rim cannot explain an earlier ball
        # below it: these can be adjacent shots, especially across a cut.
        if any(
            abs(sighting["time"] - seed["time"]) < dedupe_sec
            and not (
                sighting["time"] < seed["time"]
                and sighting["above"]["y"] >= rim_y
                and seed["above"]["y"] < rim_y
            )
            for seed in seeds
        ):
            continue
        seeds.append(sighting)
    return seeds


def _rims_compatible(left, right):
    width = max(1.0, float(left["width"]), float(right["width"]))
    height = max(1.0, float(left.get("height", 20)), float(right.get("height", 20)))
    return (
        abs(float(left["center_x"]) - float(right["center_x"])) <= width * 0.5
        and abs(float(left["rim_y"]) - float(right["rim_y"])) <= height
    )


def estimate_rims_windowed(records, confidence, window_sec):
    """按时间窗口检测篮筐位置漂移。

    固定机位:各窗口 rim 互相一致,不产生漂移窗口,等价于全局估计,行为不变。
    移动机位(无人机等):篮筐在画面中漂移,全局中位数对大多数时刻都是错的;
    每个漂移窗口用自己的局部 rim 判定穿框,找回被全局 rim 漏掉的进球。
    返回 (global_rim, [(window_start, window_end, local_rim)])。
    """
    hoop_items = [
        (float(record["time"]), item)
        for record in records
        for item in record.get("detections", [])
        if item["name"] == "hoop"
    ]
    global_rim = estimate_rim(records, confidence)
    if not hoop_items:
        return global_rim, []

    end_time = max(time for time, _ in hoop_items)
    step = max(5.0, window_sec / 2.0)
    windows = []
    start = 0.0
    while start < end_time:
        window_end = min(end_time + 1.0, start + window_sec)
        hoops = [item for time, item in hoop_items if start <= time < window_end]
        if len(hoops) >= 3:
            local_rim = _hoops_from(hoops, confidence)
            if local_rim is not None and not _rims_compatible(local_rim, global_rim):
                windows.append((start, window_end, local_rim))
        start += step
    return global_rim, windows


def main(args):
    detections_path = Path(args.detections)
    data = json.loads(detections_path.read_text(encoding="utf-8"))
    rim, drift_windows = estimate_rims_windowed(
        data["records"], args.hoop_conf, args.rim_window_sec
    )
    candidates = [
        {**candidate, "rim": rim, "rim_source": "global"}
        for candidate in find_candidate_crossings(
            data["records"], rim,
            max_gap_sec=args.max_gap_sec,
            margin=args.margin,
            min_descent_px=args.min_descent_px,
        )
    ]
    rim_mode = "global"
    if drift_windows:
        rim_mode = "windowed"
        # 漂移窗口内用局部 rim 补充穿框搜索;上下文多带两倍轨迹间隔,
        # 避免窗口边界切断正在下落的球轨迹。
        context = max(2.0, args.max_gap_sec * 2.0)
        for window_start, window_end, local_rim in drift_windows:
            sliced = [
                record
                for record in data["records"]
                if window_start - context
                <= float(record["time"])
                < window_end + context
            ]
            candidates.extend(
                {
                    **candidate,
                    "rim": local_rim,
                    "rim_source": "local_window",
                }
                for candidate in find_candidate_crossings(
                    sliced, local_rim,
                    max_gap_sec=args.max_gap_sec,
                    margin=args.margin,
                    min_descent_px=args.min_descent_px,
                )
            )
        candidates = dedupe_candidates(candidates, 0.8)
    seeds = []
    if args.rim_band_seeds:
        seeds = find_rim_band_seeds(data["records"], rim, candidates)
        candidates = candidates + seeds
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": data["video"],
        "model": data["model"],
        "rim": rim,
        "rim_mode": rim_mode,
        "candidates": candidates,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"rim={rim} mode={rim_mode} drift_windows={len(drift_windows)}")
    print(f"candidates={len(candidates)}")
    if args.rim_band_seeds:
        print(f"seeds={len(seeds)}")
    for candidate in candidates:
        print(f"{candidate['time']:.2f}s x_cross={candidate['x_cross']}")


if __name__ == "__main__":
    main(parse_args())
