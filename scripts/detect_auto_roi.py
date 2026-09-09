#!/usr/bin/env python3
"""Detect a stable hoop in a short full-frame scan and derive a ball ROI."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sys

import cv2
import torch
from ultralytics import YOLO

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.roi import hoop_bbox_to_rim_roi, select_stable_hoop
from basketball_highlight.sampling import canonical_sample_times, first_frame_index


HOOP_NAMES = {"hoop", "rim", "basketball hoop", "basketball_hoop"}
AUTO_ROI_DURATION_SECONDS = 20.0
AUTO_ROI_SAMPLE_FPS = 1.0
AUTO_ROI_MAX_SAMPLES = 12


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
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps"))
    return parser.parse_args()


def select_device(requested: str) -> str:
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def _is_hoop(name: object) -> bool:
    return str(name).strip().lower().replace("-", " ") in HOOP_NAMES


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

    model = YOLO(str(model_path))
    device = select_device(args.device)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    end_seconds = min(start_seconds + args.duration, total_frames / fps)
    sample_times = canonical_sample_times(start_seconds, end_seconds, args.sample_fps)
    target_frames = [min(total_frames - 1, first_frame_index(time, fps)) for time in sample_times]
    start_frame = target_frames[0]
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    detections = []
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
        # 攒够稳定中位数所需的检测即可提前结束。
        if len(detections) >= 5:
            break
        frame_index += 1
    cap.release()

    selected = select_stable_hoop(
        detections,
        width,
        height,
        min_confidence=args.conf,
        min_samples=2,
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
