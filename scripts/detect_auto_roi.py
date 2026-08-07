#!/usr/bin/env python3
"""Detect a stable hoop in a short full-frame scan and derive a ball ROI."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import cv2
import torch
from ultralytics import YOLO

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from basketball_highlight.roi import select_stable_hoop


HOOP_NAMES = {"hoop", "rim", "basketball hoop", "basketball_hoop"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Suggest an automatic basketball ROI.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--sample-fps", type=float, default=1.0)
    parser.add_argument("--duration", type=float, default=20.0)
    parser.add_argument("--max-samples", type=int, default=12)
    parser.add_argument("--conf", type=float, default=0.05)
    parser.add_argument("--imgsz", type=int, default=1280)
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
    if args.sample_fps <= 0 or args.duration <= 0 or args.max_samples <= 0:
        raise ValueError("AUTO_ROI_PARAMETERS_INVALID")

    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise ValueError(f"VIDEO_OPEN_FAILED: {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    if width <= 0 or height <= 0:
        cap.release()
        raise ValueError("VIDEO_DIMENSION_INVALID")

    model = YOLO(str(model_path))
    device = select_device(args.device)
    stride = max(1, round(fps / args.sample_fps))
    max_frame = min(int(args.duration * fps), int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0))
    detections = []
    frame_index = 0
    samples = 0
    while frame_index < max_frame and samples < args.max_samples:
        if not cap.grab():
            break
        if frame_index % stride == 0:
            ok, frame = cap.retrieve()
            if not ok:
                break
            results = model.predict(
                frame,
                device=device,
                conf=args.conf,
                imgsz=args.imgsz,
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
                            "time": round(frame_index / fps, 3),
                            "bbox": bbox,
                            "confidence": round(float(box.conf[0]), 4),
                            "name": str(name),
                        }
                    )
            samples += 1
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
        "message": "" if selected else "未在采样帧中稳定检测到篮筐",
    }
    if selected:
        result.update(selected)
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
