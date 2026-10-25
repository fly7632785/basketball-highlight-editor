#!/usr/bin/env python3
"""Detect a stable hoop in a short full-frame scan and derive a ball ROI."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.inference import (
    current_device,
    load_detector,
    select_device as resolve_device,
)
from basketball_highlight.roi import hoop_bbox_to_rim_roi, select_stable_hoop
from basketball_highlight.sampling import canonical_sample_times, first_frame_index


HOOP_NAMES = {"hoop", "rim", "basketball hoop", "basketball_hoop"}
AUTO_ROI_DURATION_SECONDS = 20.0
AUTO_ROI_SAMPLE_FPS = 1.0
AUTO_ROI_MAX_SAMPLES = 12
# Zoomed check of each hoop cluster: a square of this many box sizes around
# the cluster, at native resolution, re-detected at the model input size.
VERIFY_CROP_BOX_SIZES = 5.0
VERIFY_MIN_CROP_PX = 96.0
VERIFY_FRAMES = 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Suggest an automatic basketball ROI.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--sample-fps", type=float, default=AUTO_ROI_SAMPLE_FPS)
    parser.add_argument("--duration", type=float, default=AUTO_ROI_DURATION_SECONDS)
    parser.add_argument(
        "--start",
        type=float,
        default=0.0,
        help="采样起始秒;配合分析范围使用,避免从片头热身画面采样",
    )
    parser.add_argument("--max-samples", type=int, default=AUTO_ROI_MAX_SAMPLES)
    parser.add_argument("--conf", type=float, default=0.05)
    # Keep automatic ROI on the same input contract as coarse/refine and the
    # bundled mobile ONNX model. PT and ONNX can now be compared without an
    # unrecorded 1280-vs-640 preprocessing change.
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps", "cuda", "dml"))
    return parser.parse_args()


def select_device(requested: str) -> str:
    """解析推理设备;`auto` 会按 cuda > dml > mps > cpu 选,详见 inference.py。"""
    return resolve_device(requested)


def load_yolo_model(model_path: Path):
    """按当前设备加载检测器:DirectML 走 ORT,其余走 ultralytics。"""
    return load_detector(model_path)


def _is_hoop(name: object) -> bool:
    return str(name).strip().lower().replace("-", " ") in HOOP_NAMES


def zoom_verifier(model, frames, device: str, imgsz: int, conf: float):
    """Return the best hoop confidence near the centre of a zoomed crop."""

    def verify(bbox: list[float]) -> float:
        x1, y1, x2, y2 = bbox
        center_x = (x1 + x2) / 2.0
        center_y = (y1 + y2) / 2.0
        best = 0.0
        for frame in frames[:VERIFY_FRAMES]:
            height, width = frame.shape[:2]
            side = min(
                max(VERIFY_MIN_CROP_PX, VERIFY_CROP_BOX_SIZES * max(x2 - x1, y2 - y1)),
                width,
                height,
            )
            left = int(round(min(max(center_x - side / 2.0, 0.0), width - side)))
            top = int(round(min(max(center_y - side / 2.0, 0.0), height - side)))
            crop = frame[top : top + int(side), left : left + int(side)]
            results = model.predict(
                crop, device=device, conf=conf, imgsz=imgsz, rect=False, verbose=False
            )
            if not results:
                continue
            for box in results[0].boxes:
                if not _is_hoop(results[0].names[int(box.cls[0])]):
                    continue
                bx1, by1, bx2, by2 = (float(value) for value in box.xyxy[0].tolist())
                # Only a hoop centred inside this cluster's box confirms it;
                # a neighbouring hoop inside the crop must not.
                if (
                    x1 - left <= (bx1 + bx2) / 2.0 <= x2 - left
                    and y1 - top <= (by1 + by2) / 2.0 <= y2 - top
                ):
                    best = max(best, float(box.conf[0]))
        return best

    return verify


def detect(args: argparse.Namespace) -> dict:
    video = Path(args.video).expanduser().resolve()
    model_path = Path(args.model).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    if not video.is_file():
        raise ValueError(f"VIDEO_NOT_FOUND: {video}")
    if not model_path.is_file():
        raise ValueError(f"MODEL_NOT_FOUND: {model_path}")
    if (
        args.sample_fps <= 0
        or args.duration <= 0
        or args.max_samples <= 0
        or not math.isfinite(args.start)
        or args.start < 0
        or args.imgsz < 320
        or args.imgsz % 32 != 0
    ):
        raise ValueError("AUTO_ROI_PARAMETERS_INVALID")

    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise ValueError(f"VIDEO_OPEN_FAILED: {video}")
    start_seconds = args.start
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    if width <= 0 or height <= 0:
        cap.release()
        raise ValueError("VIDEO_DIMENSION_INVALID")

    device = select_device(args.device)
    model = load_yolo_model(model_path)
    # 实际后端可能回落(onnx 缺失 / DML 不可用),以模型为准。
    device = current_device()
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    end_seconds = min(start_seconds + args.duration, total_frames / fps)
    sample_times = canonical_sample_times(start_seconds, end_seconds, args.sample_fps)
    target_frames = [min(total_frames - 1, first_frame_index(time, fps)) for time in sample_times]
    start_frame = target_frames[0]
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    detections = []
    frames = []
    frame_index = start_frame
    sample_index = 0
    samples = 0
    while sample_index < len(target_frames) and samples < args.max_samples:
        if not cap.grab():
            break
        if frame_index < target_frames[sample_index]:
            frame_index += 1
            continue
        while sample_index < len(target_frames) and target_frames[sample_index] < frame_index:
            sample_index += 1
        if sample_index >= len(target_frames):
            break
        ok, frame = cap.retrieve()
        if not ok:
            break
        if len(frames) < VERIFY_FRAMES:
            frames.append(frame)
        results = model.predict(
            frame,
            device=device,
            conf=args.conf,
            iou=0.7,
            agnostic_nms=False,
            max_det=300,
            imgsz=args.imgsz,
            # Match the static square ONNX input used by mobile.
            rect=False,
            verbose=False,
        )
        if results:
            for box in results[0].boxes:
                class_id = int(box.cls[0])
                name = results[0].names[class_id]
                if not _is_hoop(name):
                    continue
                bbox = [round(float(value), 2) for value in box.xyxy[0].tolist()]
                detections.append(
                    {
                        "frame": frame_index,
                        "time": sample_times[sample_index],
                        "bbox": bbox,
                        "confidence": round(float(box.conf[0]), 4),
                        "name": str(name),
                    }
                )
        samples += 1
        sample_index += 1
        frame_index += 1
    cap.release()

    selected = select_stable_hoop(
        detections,
        width,
        height,
        min_confidence=args.conf,
        min_samples=2,
        verify=zoom_verifier(model, frames, device, args.imgsz, args.conf),
    )
    result = {
        "success": selected is not None,
        "source": "auto_hoop_model",
        "video": str(video),
        "model": str(model_path),
        "device": device,
        "frame_width": width,
        "frame_height": height,
        "sample_fps": args.sample_fps,
        "sample_count": samples,
        "detection_count": len(detections),
        "model_input_size": args.imgsz,
        "message": "" if selected else "未在采样帧中稳定检测到篮筐",
    }
    if selected:
        result.update(selected)
        result["rim_roi"] = hoop_bbox_to_rim_roi(
            selected["hoop_bbox"], width, height,
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    return result


if __name__ == "__main__":
    try:
        detect(parse_args())
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
