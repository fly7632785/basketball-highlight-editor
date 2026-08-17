import argparse
import json
import math
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
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps", "cuda"))
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def validate_args(args):
    x1, y1, x2, y2 = args.roi
    if (
        not Path(args.video).is_file()
        or not Path(args.model).is_file()
        or not Path(args.coarse).is_file()
        or x1 < 0
        or y1 < 0
        or x2 <= x1
        or y2 <= y1
        or not math.isfinite(args.window)
        or args.window <= 0
        or not math.isfinite(args.sample_fps)
        or args.sample_fps <= 0
        or args.scale <= 0
        or args.batch <= 0
        or not math.isfinite(args.conf)
        or not 0 < args.conf < 1
    ):
        raise ValueError("REFINE_PARAMETERS_INVALID")
    if args.net_roi is not None:
        nx1, ny1, nx2, ny2 = args.net_roi
        if nx1 < 0 or ny1 < 0 or nx2 <= nx1 or ny2 <= ny1:
            raise ValueError("REFINE_NET_ROI_INVALID")


def select_device(requested):
    if requested != "auto":
        return requested
    if torch.cuda.is_available():
        return "cuda"
    return "mps" if torch.backends.mps.is_available() else "cpu"


def _clamp01(value):
    return max(0.0, min(1.0, float(value)))


def _net_zones(rim, frame_width, frame_height, net_roi=None):
    """Build the same upper/lower/below regions used by bball-highlights.

    These are auxiliary regions derived from the calibrated rim; they do not
    replace the ball detector and therefore remain usable when the ball is
    hidden by the net.
    """
    if net_roi:
        x1, y1, x2, y2 = [int(value) for value in net_roi]
        x1, x2 = sorted((max(0, x1), min(frame_width, x2)))
        y1, y2 = sorted((max(0, y1), min(frame_height, y2)))
        if x2 > x1 and y2 > y1:
            height = y2 - y1
            def net_box(start, end):
                return (x1, y1 + int(height * start), x2, y1 + int(height * end))
            return {
                "upper": net_box(0.0, 0.42),
                "lower": net_box(0.28, 0.74),
                "below": net_box(0.58, 1.0),
            }
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


def _zone_signal(gray, hsv, background_gray, previous_gray=None):
    if gray.size == 0 or hsv.size == 0:
        return 0.0, 0.0, 0.0, 0.0, 0.0
    orange = cv2.inRange(hsv, (0, 45, 35), (25, 255, 255)) > 0
    if background_gray is None or background_gray.shape != gray.shape:
        return 0.0, 0.0, 0.0, 0.0, 0.0
    diff = cv2.absdiff(background_gray, gray)
    changed_ratio = float((diff > 25).mean())
    gray_motion = _clamp01(changed_ratio / 0.12)
    orange_motion = _clamp01(float((orange & (diff > 25)).mean()) / 0.035)
    white = cv2.inRange(hsv, (0, 0, 145), (180, 90, 255)) > 0
    white_motion = _clamp01(float((white & (diff > 18)).mean()) / 0.020)
    downward_motion = 0.0
    if previous_gray is not None and previous_gray.shape == gray.shape:
        flow = cv2.calcOpticalFlowFarneback(
            previous_gray, gray, None, 0.5, 2, 15, 2, 5, 1.2, 0,
        )
        magnitude = cv2.magnitude(flow[..., 0], flow[..., 1])
        moving_white = white & (magnitude > 0.35)
        white_motion = max(
            white_motion,
            _clamp01(float(moving_white.mean()) / 0.015),
        )
        downward_motion = _clamp01(
            float((moving_white & (flow[..., 1] > 0.12)).mean()) / 0.012,
        )
    return gray_motion, changed_ratio, orange_motion, white_motion, downward_motion


def scan_window(
    model, video, roi, center_time, window, sample_fps, scale, conf, device,
    rim=None, batch=8, start_time_override=None, end_time_override=None,
    net_roi=None,
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
    zones = _net_zones(
        rim,
        int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or x2),
        int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or y2),
        net_roi=net_roi,
    ) if rim else {}
    zone_history = {name: deque(maxlen=15) for name in zones}
    previous_zone_gray = {name: None for name in zones}
    if net_roi:
        net_x1, net_y1, net_x2, net_y2 = [int(value) for value in net_roi]
        net_x1 = max(x1, net_x1)
        net_x2 = min(x2, net_x2)
        net_y1 = max(y1, net_y1)
        net_y2 = min(y2, net_y2)
    elif rim:
        net_x1 = max(x1, int(rim["center_x"] - 2.0 * rim["width"]))
        net_x2 = min(x2, int(rim["center_x"] + 2.0 * rim["width"]))
        net_y1 = max(y1, int(rim["rim_y"]))
        net_y2 = min(y2, int(rim["rim_y"] + 3.5 * rim.get("height", 20)))
    else:
        net_x1 = net_x2 = net_y1 = net_y2 = 0
    signal_bounds = [*zones.values()]
    if net_x2 > net_x1 and net_y2 > net_y1:
        signal_bounds.append((net_x1, net_y1, net_x2, net_y2))
    if signal_bounds:
        signal_x1 = min(bounds[0] for bounds in signal_bounds)
        signal_y1 = min(bounds[1] for bounds in signal_bounds)
        signal_x2 = max(bounds[2] for bounds in signal_bounds)
        signal_y2 = max(bounds[3] for bounds in signal_bounds)
    else:
        signal_x1 = signal_x2 = signal_y1 = signal_y2 = 0

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
            "net_measurement_valid": False,
            "net_upper_motion_score": 0.0,
            "net_lower_motion_score": 0.0,
            "net_below_motion_score": 0.0,
            "net_upper_orange_score": 0.0,
            "net_lower_orange_score": 0.0,
            "net_below_orange_score": 0.0,
            "net_whole_signal_score": 0.0,
        }
        if rim and net_x2 > net_x1 and net_y2 > net_y1:
            signal_frame = frame[signal_y1:signal_y2, signal_x1:signal_x2]
            signal_gray = cv2.cvtColor(signal_frame, cv2.COLOR_BGR2GRAY)
            signal_hsv = cv2.cvtColor(signal_frame, cv2.COLOR_BGR2HSV)
            net = signal_gray[
                net_y1 - signal_y1:net_y2 - signal_y1,
                net_x1 - signal_x1:net_x2 - signal_x1,
            ]
            if previous_net is not None and previous_net.shape == net.shape:
                diff = cv2.absdiff(previous_net, net)
                net_motion_score = float(diff.mean())
                net_changed_ratio = float((diff > 15).mean())
            previous_net = net
            signals = []
            zone_measurements_valid = True
            for zone_name, bounds in zones.items():
                x0, y0, xz1, yz1 = bounds
                current_gray = signal_gray[
                    y0 - signal_y1:yz1 - signal_y1,
                    x0 - signal_x1:xz1 - signal_x1,
                ]
                current_hsv = signal_hsv[
                    y0 - signal_y1:yz1 - signal_y1,
                    x0 - signal_x1:xz1 - signal_x1,
                ]
                history = zone_history[zone_name]
                background = None
                if len(history) >= 5:
                    background = cv2.medianBlur(
                        np.median(np.stack(history), axis=0).astype("uint8"), 3,
                    )
                else:
                    zone_measurements_valid = False
                gray_motion, changed_ratio, orange_motion, white_motion, downward_motion = _zone_signal(
                    current_gray, current_hsv, background, previous_zone_gray[zone_name],
                )
                if current_gray.size > 0:
                    history.append(current_gray)
                zone_values[f"net_{zone_name}_motion_score"] = round(gray_motion, 4)
                zone_values[f"net_{zone_name}_changed_ratio"] = round(changed_ratio, 4)
                zone_values[f"net_{zone_name}_orange_score"] = round(orange_motion, 4)
                zone_values[f"net_{zone_name}_white_motion_score"] = round(white_motion, 4)
                zone_values[f"net_{zone_name}_downward_motion_score"] = round(downward_motion, 4)
                previous_zone_gray[zone_name] = current_gray.copy()
                signals.append(max(gray_motion, white_motion, downward_motion))
                signals.append(orange_motion)
            zone_values["net_measurement_valid"] = zone_measurements_valid
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
    validate_args(args)
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
