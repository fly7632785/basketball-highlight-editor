"""Re-check final candidates frame by frame on a tight crop around the rim.

Input JSON: ``{"candidates": [{"time": seconds, "rim": {center_x, rim_y,
width, height}}]}`` in source-video coordinates. Output JSON keeps the same
order with one ``rim_check`` result per candidate.
"""
import argparse
import json
import math
import sys
import time
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.net_motion import motion_box, net_motion_series, prepare  # noqa: E402
from basketball_highlight.inference import (  # noqa: E402
    current_device,
    load_detector,
    select_device as resolve_device,
)
from basketball_highlight.rim_check import (  # noqa: E402
    MIN_RIM_WIDTH_PX,
    RIM_CHECK_VERSION,
    WINDOW_AFTER_S,
    WINDOW_BEFORE_S,
    apply_video_occlusion,
    assess_rim_crossing,
    skipped_result,
    tight_crop_box,
)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--conf", type=float, default=0.05)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps", "cuda", "dml"))
    return parser.parse_args()


# CPU 上一次推理 16 张比 4-12 张慢约 5 倍(M1 Pro 实测);GPU 上 16 张最快。
CPU_BATCH = 8
# DirectML 的 dynamic shape 路径在小批量上会退化(实测 batch=2 比 batch=1 慢 4 倍),
# 所以 DML 固定单张;真正的批量合并交给 ORT 内部,这里不攒批。
DML_BATCH = 1


def select_device(requested):
    """解析推理设备;`auto` 会按 cuda > dml > mps > cpu 选,详见 inference.py。"""
    return resolve_device(requested)


def load_yolo_model(model_path):
    """按当前设备加载检测器:DirectML 走 ORT,其余走 ultralytics。"""
    return load_detector(model_path)


def valid_rim(rim):
    try:
        values = [float(rim[key]) for key in ("center_x", "rim_y", "width")]
        return all(math.isfinite(value) for value in values) and values[2] > 0
    except (KeyError, TypeError, ValueError):
        return False


def build_jobs(candidates, fps, total_frames, frame_width, frame_height):
    jobs = []
    results = [None] * len(candidates)
    for index, candidate in enumerate(candidates):
        rim = candidate.get("rim")
        if not valid_rim(rim):
            results[index] = skipped_result("no_rim")
            continue
        if float(rim["width"]) < MIN_RIM_WIDTH_PX:
            results[index] = skipped_result("small_rim", rim["width"])
            continue
        event = float(candidate["time"])
        first = max(0, int(round((event - WINDOW_BEFORE_S) * fps)))
        last = min(total_frames - 1, int(round((event + WINDOW_AFTER_S) * fps)))
        if last < first:
            results[index] = skipped_result("no_frames", rim["width"])
            continue
        jobs.append({
            "index": index,
            "rim": rim,
            "first": first,
            "last": last,
            "box": tight_crop_box(rim, frame_width, frame_height),
            "motion_box": motion_box(rim, frame_width, frame_height),
            "frames": [[] for _ in range(last - first + 1)],
            "grays": [],
        })
    return jobs, results


def group_jobs(jobs):
    groups = []
    for job in sorted(jobs, key=lambda item: item["first"]):
        if groups and job["first"] <= groups[-1]["last"] + 1:
            groups[-1]["jobs"].append(job)
            groups[-1]["last"] = max(groups[-1]["last"], job["last"])
        else:
            groups.append({"first": job["first"], "last": job["last"], "jobs": [job]})
    return groups


def run_batch(model, pending, device, conf, batch):
    predictions = model.predict(
        [crop for crop, _, _ in pending],
        imgsz=640,
        conf=conf,
        iou=0.7,
        rect=False,
        device=device,
        batch=batch,
        verbose=False,
    )
    for (_, job, offset), result in zip(pending, predictions):
        x0, y0 = job["box"][0], job["box"][1]
        detections = job["frames"][offset]
        for box in result.boxes:
            name = result.names[int(box.cls[0])]
            if name not in {"ball", "hoop"}:
                continue
            bx1, by1, bx2, by2 = box.xyxy[0].tolist()
            detections.append({
                "name": name,
                "confidence": round(float(box.conf[0]), 4),
                "xyxy": [round(x0 + bx1, 2), round(y0 + by1, 2), round(x0 + bx2, 2), round(y0 + by2, 2)],
            })
    pending.clear()


def main(args):
    started = time.perf_counter()
    candidates = json.loads(Path(args.candidates).read_text(encoding="utf-8"))["candidates"]
    cap = cv2.VideoCapture(str(args.video))
    if not cap.isOpened():
        raise RuntimeError(f"Unable to open video: {args.video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    frame_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    frame_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    jobs, results = build_jobs(candidates, fps, total_frames, frame_width, frame_height)
    groups = group_jobs(jobs)
    print("progress=0.0", flush=True)
    device = None
    model = None
    if groups:
        device = select_device(args.device)
        model = load_yolo_model(args.model)
        # 实际后端可能回落(onnx 缺失 / DML 不可用),以模型为准。
        device = current_device()
    batch = args.batch
    if device == "cpu":
        batch = min(args.batch, CPU_BATCH)
    elif device == "dml":
        batch = DML_BATCH
    pending = []
    for group_number, group in enumerate(groups, 1):
        cap.set(cv2.CAP_PROP_POS_FRAMES, group["first"])
        for frame_index in range(group["first"], group["last"] + 1):
            ok, frame = cap.read()
            if not ok:
                break
            for job in group["jobs"]:
                if job["first"] <= frame_index <= job["last"]:
                    x1, y1, x2, y2 = job["box"]
                    pending.append((frame[y1:y2, x1:x2], job, frame_index - job["first"]))
                    x1, y1, x2, y2 = job["motion_box"]
                    job["grays"].append(prepare(frame[y1:y2, x1:x2]))
            if len(pending) >= batch:
                run_batch(model, pending, device, args.conf, batch)
        if pending:
            run_batch(model, pending, device, args.conf, batch)
        for job in group["jobs"]:
            job["net_motion_series"] = net_motion_series(
                job.pop("grays"), job["frames"], job["rim"], job["motion_box"][:2],
            )
        print(f"progress={group_number / len(groups):.4f}", flush=True)
    cap.release()
    for job in jobs:
        # Keep the raw detections so the engine can re-judge cached runs.
        results[job["index"]] = {
            **assess_rim_crossing(job["frames"], job["rim"], job["net_motion_series"]),
            "frames": job["frames"],
            "net_motion_series": job["net_motion_series"],
        }
    results = apply_video_occlusion(results)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    temporary.write_text(json.dumps({
        "version": RIM_CHECK_VERSION,
        "video": str(args.video),
        "device": device,
        "results": results,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }, ensure_ascii=False), encoding="utf-8")
    temporary.replace(output)
    counts = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    print(f"rim_check={json.dumps(counts, sort_keys=True)}", flush=True)


if __name__ == "__main__":
    main(parse_args())
