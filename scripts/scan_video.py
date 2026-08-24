import argparse
import hashlib
import json
import math
import time
from pathlib import Path

from cache_io import read_json_cache, write_json_cache


def parse_args():
    parser = argparse.ArgumentParser(description="Scan a basketball video with an existing YOLO model.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"), required=True)
    parser.add_argument("--sample-fps", type=float, default=5)
    parser.add_argument("--duration", type=float,
                        help="Optional duration limit in seconds, useful for benchmarks.")
    parser.add_argument("--time-offset", type=float, default=0.0,
                        help="Source timestamp offset for a clipped proxy.")
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--conf", type=float, default=0.15)
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps", "cuda"))
    parser.add_argument("--cache-dir", type=Path,
                        help="Optional directory for reusable coarse detection logs.")
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


def open_video(video):
    import cv2

    return cv2.VideoCapture(str(video))


def scan_video(args):
    video = Path(args.video)
    model_path = Path(args.model)
    output = Path(args.output)
    x1, y1, x2, y2 = args.roi
    if not video.is_file():
        raise ValueError(f"VIDEO_NOT_FOUND: {video}")
    if not model_path.is_file():
        raise ValueError(f"MODEL_NOT_FOUND: {model_path}")
    if (
        len(args.roi) != 4
        or x1 < 0
        or y1 < 0
        or x2 <= x1
        or y2 <= y1
        or not math.isfinite(args.sample_fps)
        or args.sample_fps <= 0
        or args.duration is not None and (
            not math.isfinite(args.duration) or args.duration <= 0
        )
        or not math.isfinite(args.time_offset)
        or args.scale <= 0
        or args.batch <= 0
        or not math.isfinite(args.conf)
        or not 0 < args.conf < 1
    ):
        raise ValueError("SCAN_PARAMETERS_INVALID")
    device = args.device

    cache_path = None
    cache_key = None
    if args.cache_dir:
        cache_key = hashlib.sha256(json.dumps({
            "video": str(video.resolve()),
            "video_size": video.stat().st_size,
            "video_mtime_ns": video.stat().st_mtime_ns,
            "model": str(model_path.resolve()),
            "model_size": model_path.stat().st_size,
            "model_mtime_ns": model_path.stat().st_mtime_ns,
            "roi": args.roi,
            "sample_fps": args.sample_fps,
            "duration": args.duration,
            "time_offset": args.time_offset,
            "scale": args.scale,
            "batch": args.batch,
            "conf": args.conf,
        }, sort_keys=True).encode()).hexdigest()
        args.cache_dir.mkdir(parents=True, exist_ok=True)
        # 文件名只取哈希前 24 位(96bit,缓存键足够防碰撞):完整 64 位
        # 哈希 + 长项目目录名会超过 Windows MAX_PATH(260)导致
        # FileNotFoundError。cache_key 元数据仍保留完整哈希。
        cache_path = args.cache_dir / f"{cache_key[:24]}.json"
        if cache_path.exists():
            cached = read_json_cache(
                cache_path,
                lambda value: isinstance(value, dict) and isinstance(value.get("records"), list),
            )
            if cached is not None:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(cached, ensure_ascii=False), encoding="utf-8")
                print(f"cache_hit={cache_path}")
                print("progress=1.0", flush=True)
                print(f"output={output}")
                return

    device = select_device(args.device)
    import cv2

    model = load_yolo_model(model_path)
    cap = open_video(video)
    if not cap.isOpened():
        raise RuntimeError(f"Unable to open video: {video}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    max_frames = None if args.duration is None else max(0, int(args.duration * fps))
    stride = max(1, round(fps / args.sample_fps))
    records = []
    frame_index = 0
    started = time.perf_counter()

    pending_crops = []
    pending_meta = []
    last_progress_report = started
    progress_total = max_frames or frame_count

    def flush_batch():
        if not pending_crops:
            return
        predictions = model.predict(
            pending_crops,
            device=device,
            conf=args.conf,
            imgsz=640,
            batch=args.batch,
            verbose=False,
        )
        for meta, result in zip(pending_meta, predictions):
            detections = []
            for box in result.boxes:
                class_index = int(box.cls[0])
                confidence = float(box.conf[0])
                bx1, by1, bx2, by2 = box.xyxy[0].tolist()
                coords = [
                    x1 + bx1 / args.scale,
                    y1 + by1 / args.scale,
                    x1 + bx2 / args.scale,
                    y1 + by2 / args.scale,
                ]
                detections.append({
                    "name": result.names[class_index],
                    "confidence": round(confidence, 4),
                    "xyxy": [round(value, 2) for value in coords],
                    "center": [
                        round((coords[0] + coords[2]) / 2, 2),
                        round((coords[1] + coords[3]) / 2, 2),
                    ],
                })
            records.append({**meta, "detections": detections})
        pending_crops.clear()
        pending_meta.clear()

    while True:
        if max_frames is not None and frame_index >= max_frames:
            break
        ok = cap.grab()
        if not ok:
            break
        if frame_index % stride:
            frame_index += 1
            continue
        ok, frame = cap.retrieve()
        if not ok:
            break

        crop = frame[y1:y2, x1:x2]
        if crop.size == 0:
            raise ValueError(f"ROI is outside the video frame: {(x1, y1, x2, y2)}")
        if args.scale != 1:
            crop = cv2.resize(crop, None, fx=args.scale, fy=args.scale, interpolation=cv2.INTER_CUBIC)

        pending_crops.append(crop)
        pending_meta.append({
            "frame": frame_index,
                    "time": round(frame_index / fps + args.time_offset, 4),
        })
        if len(pending_crops) >= args.batch:
            flush_batch()
        now = time.perf_counter()
        if now - last_progress_report >= 0.5:
            progress = frame_index / max(1, progress_total)
            print(f"progress={min(1.0, progress):.4f}", flush=True)
            last_progress_report = now
        frame_index += 1

    flush_batch()
    cap.release()
    print("progress=1.0", flush=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": str(video),
        "model": str(model_path),
        "device": device,
        "fps": fps,
        "frame_count": frame_count,
        "sample_fps": args.sample_fps,
        "duration_limit": args.duration,
        "roi": [x1, y1, x2, y2],
        "scale": args.scale,
        "batch": args.batch,
        "records": records,
        "cache_key": cache_key,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }, ensure_ascii=False), encoding="utf-8")
    if cache_path:
        write_json_cache(cache_path, json.loads(output.read_text(encoding="utf-8")))


if __name__ == "__main__":
    scan_video(parse_args())
