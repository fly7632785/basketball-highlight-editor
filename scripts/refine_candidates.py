import argparse
import json
import sys
import time
from collections import deque
from pathlib import Path

import cv2
import numpy as np
import torch
from ultralytics import YOLO

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.events import find_refined_crossings


def parse_args():
    parser = argparse.ArgumentParser(description="Refine coarse events with native-frame YOLO scanning.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--coarse", required=True)
    parser.add_argument("--roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"), required=True)
    parser.add_argument("--window", type=float, default=1.5)
    parser.add_argument("--sample-fps", type=float, default=30)
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--conf", type=float, default=0.2)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps"))
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def select_device(requested):
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def _clamp01(value):
    return max(0.0, min(1.0, float(value)))


def _net_zones(rim, frame_width, frame_height):
    """Build the same upper/lower/below regions used by bball-highlights.

    These are auxiliary regions derived from the calibrated rim; they do not
    replace the ball detector and therefore remain usable when the ball is
    hidden by the net.
    """
    cx = float(rim["center_x"])
    cy = float(rim["rim_y"])
    rw = max(4.0, float(rim["width"]))
    rh = max(8.0, float(rim.get("height", 20)))

    def box(y0, y1, half_width):
        return (
            max(0, int(cx - half_width)),
            max(0, int(cy + y0)),
            min(frame_width, int(cx + half_width)),
            min(frame_height, int(cy + y1)),
        )

    return {
        "upper": box(0.15 * rh, 1.8 * rh, 1.5 * rw),
        "lower": box(1.8 * rh, 3.6 * rh, 1.0 * rw),
        "below": box(3.6 * rh, 5.2 * rh, max(1.25 * rw, 24.0)),
    }


def _zone_signal(frame, background_gray, bounds):
    x0, y0, x1, y1 = bounds
    if x1 <= x0 or y1 <= y0:
        return 0.0, 0.0, 0.0
    gray = cv2.cvtColor(frame[y0:y1, x0:x1], cv2.COLOR_BGR2GRAY)
    hsv = cv2.cvtColor(frame[y0:y1, x0:x1], cv2.COLOR_BGR2HSV)
    orange = cv2.inRange(hsv, (0, 45, 35), (25, 255, 255)) > 0
    if background_gray is None or background_gray.shape != gray.shape:
        return 0.0, 0.0, 0.0
    diff = cv2.absdiff(background_gray, gray)
    changed_ratio = float((diff > 25).mean())
    gray_motion = _clamp01(changed_ratio / 0.12)
    orange_motion = _clamp01(float((orange & (diff > 25)).mean()) / 0.035)
    return gray_motion, changed_ratio, orange_motion


def scan_window(
    model, video, roi, center_time, window, sample_fps, scale, conf, device,
    rim=None, batch=8, start_time_override=None, end_time_override=None,
):
    x1, y1, x2, y2 = roi
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise RuntimeError(f"Unable to open video: {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    start_time = max(0.0, center_time - window) if start_time_override is None else max(0.0, start_time_override)
    end_time = min(total_frames / fps, center_time + window) if end_time_override is None else min(total_frames / fps, end_time_override)
    start_frame = int(start_time * fps)
    stride = max(1, round(fps / sample_fps))
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    records = []
    frame_index = start_frame
    previous_net = None
    zones = _net_zones(rim, int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or x2),
                       int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or y2)) if rim else {}
    zone_history = {name: deque(maxlen=15) for name in zones}
    if rim:
        net_x1 = max(x1, int(rim["center_x"] - 2.0 * rim["width"]))
        net_x2 = min(x2, int(rim["center_x"] + 2.0 * rim["width"]))
        net_y1 = max(y1, int(rim["rim_y"]))
        net_y2 = min(y2, int(rim["rim_y"] + 3.5 * rim.get("height", 20)))
    else:
        net_x1 = net_x2 = net_y1 = net_y2 = 0

    pending_crops = []
    pending_meta = []

    def flush_batch():
        if not pending_crops:
            return
        predictions = model.predict(
            pending_crops,
            device=device,
            conf=conf,
            imgsz=640,
            batch=batch,
            verbose=False,
        )
        for meta, result in zip(pending_meta, predictions):
            detections = []
            for box in result.boxes:
                class_index = int(box.cls[0])
                name = result.names[class_index]
                if name not in {"ball", "hoop"}:
                    continue
                bx1, by1, bx2, by2 = box.xyxy[0].tolist()
                coords = [
                    x1 + bx1 / scale,
                    y1 + by1 / scale,
                    x1 + bx2 / scale,
                    y1 + by2 / scale,
                ]
                detections.append({
                    "name": name,
                    "confidence": round(float(box.conf[0]), 4),
                    "center": [
                        round((coords[0] + coords[2]) / 2, 2),
                        round((coords[1] + coords[3]) / 2, 2),
                    ],
                    "xyxy": [round(value, 2) for value in coords],
                })
            records.append({**meta, "detections": detections})
        pending_crops.clear()
        pending_meta.clear()

    while frame_index / fps <= end_time:
        ok = cap.grab()
        if not ok:
            break
        if (frame_index - start_frame) % stride:
            frame_index += 1
            continue
        ok, frame = cap.retrieve()
        if not ok:
            break
        crop = frame[y1:y2, x1:x2]
        if crop.size == 0:
            raise ValueError(f"ROI is outside the video frame: {roi}")
        net_motion_score = 0.0
        net_changed_ratio = 0.0
        zone_values = {
            "net_upper_motion_score": 0.0,
            "net_lower_motion_score": 0.0,
            "net_below_motion_score": 0.0,
            "net_upper_orange_score": 0.0,
            "net_lower_orange_score": 0.0,
            "net_below_orange_score": 0.0,
            "net_whole_signal_score": 0.0,
        }
        if rim and net_x2 > net_x1 and net_y2 > net_y1:
            net = cv2.cvtColor(frame[net_y1:net_y2, net_x1:net_x2], cv2.COLOR_BGR2GRAY)
            if previous_net is not None and previous_net.shape == net.shape:
                diff = cv2.absdiff(previous_net, net)
                net_motion_score = float(diff.mean())
                net_changed_ratio = float((diff > 15).mean())
            previous_net = net
            signals = []
            for zone_name, bounds in zones.items():
                x0, y0, xz1, yz1 = bounds
                current_gray = cv2.cvtColor(frame[y0:yz1, x0:xz1], cv2.COLOR_BGR2GRAY) if xz1 > x0 and yz1 > y0 else None
                history = zone_history[zone_name]
                background = None
                if len(history) >= 5:
                    background = cv2.medianBlur(
                        np.median(np.stack(history), axis=0).astype("uint8"), 3,
                    )
                gray_motion, changed_ratio, orange_motion = _zone_signal(
                    frame, background, bounds,
                )
                if current_gray is not None:
                    history.append(current_gray)
                zone_values[f"net_{zone_name}_motion_score"] = round(gray_motion, 4)
                zone_values[f"net_{zone_name}_changed_ratio"] = round(changed_ratio, 4)
                zone_values[f"net_{zone_name}_orange_score"] = round(orange_motion, 4)
                signals.append(gray_motion)
                signals.append(orange_motion)
            zone_values["net_whole_signal_score"] = round(
                _clamp01(max(signals, default=0.0)), 4,
            )
        if scale != 1:
            crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        pending_crops.append(crop)
        pending_meta.append({
            "frame": frame_index,
            "time": round(frame_index / fps, 4),
            "net_motion_score": round(net_motion_score, 3),
            "net_changed_ratio": round(net_changed_ratio, 4),
            **zone_values,
        })
        if len(pending_crops) >= batch:
            flush_batch()
        frame_index += 1
    flush_batch()
    cap.release()
    return records


def main(args):
    video = Path(args.video)
    coarse_data = json.loads(Path(args.coarse).read_text(encoding="utf-8"))
    roi = args.roi
    device = select_device(args.device)
    model = YOLO(str(args.model))
    started = time.perf_counter()
    refined = []
    for index, coarse in enumerate(coarse_data["candidates"], 1):
        records = scan_window(
            model, video, roi, float(coarse["time"]), args.window,
            args.sample_fps, args.scale, args.conf, device, coarse_data["rim"], args.batch,
        )
        matches = find_refined_crossings(records, coarse_data["rim"])
        refined.append({
            "index": index,
            "coarse": coarse,
            "refined": matches,
            "sampled_frames": len(records),
            "ball_frames": sum(bool(record["detections"]) for record in records),
        })
        print(f"{index:02d} coarse={coarse['time']:.2f}s refined={len(matches)}")

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": str(video),
        "model": str(args.model),
        "device": device,
        "roi": roi,
        "window": args.window,
        "sample_fps": args.sample_fps,
        "batch": args.batch,
        "results": refined,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"kept={sum(bool(item['refined']) for item in refined)} / {len(refined)}")
    print(f"elapsed_seconds={round(time.perf_counter() - started, 3)}")
    print(f"output={output}")


if __name__ == "__main__":
    main(parse_args())
