#!/usr/bin/env python3
"""Compare Ultralytics PT and native-style ONNX inference on the same frame.

This deliberately compares detector output only. It does not claim pipeline
equivalence: tracking, net signals and candidate scoring are validated by the
separate replay tools.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
from ultralytics import YOLO


def letterbox(image: np.ndarray, size: int) -> tuple[np.ndarray, float, int, int]:
    height, width = image.shape[:2]
    scale = min(size / width, size / height)
    resized_width = max(1, round(width * scale))
    resized_height = max(1, round(height * scale))
    resized = cv2.resize(image, (resized_width, resized_height), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), 114, dtype=np.uint8)
    offset_x = (size - resized_width) // 2
    offset_y = (size - resized_height) // 2
    canvas[offset_y:offset_y + resized_height, offset_x:offset_x + resized_width] = resized
    return canvas, scale, offset_x, offset_y


def preprocess(image: np.ndarray, size: int) -> tuple[np.ndarray, float, int, int]:
    canvas, scale, offset_x, offset_y = letterbox(image, size)
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)
    tensor = rgb.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
    return tensor, scale, offset_x, offset_y


def decode(output: np.ndarray, image_shape: tuple[int, int], size: int, scale: float,
           offset_x: int, offset_y: int, conf: float) -> list[dict]:
    values = np.asarray(output)
    if values.ndim == 3:
        values = values[0]
    if values.shape[0] <= 6 and values.shape[1] >= 5:
        values = values.T
    if values.shape[0] < 5:
        raise ValueError(f"unexpected ONNX output shape: {output.shape}")
    boxes = values[:, :4]
    scores = values[:, 4:]
    class_ids = np.argmax(scores, axis=1)
    confidences = scores[np.arange(scores.shape[0]), class_ids]
    keep = confidences >= conf
    boxes = boxes[keep]
    confidences = confidences[keep]
    class_ids = class_ids[keep]
    if not len(boxes):
        return []

    # Ultralytics uses class-aware NMS. Keep the implementation local so this
    # diagnostic tool uses the same xyxy IoU convention as the Rust runtime.
    xyxy = np.empty_like(boxes, dtype=np.float32)
    xyxy[:, 0] = boxes[:, 0] - boxes[:, 2] / 2
    xyxy[:, 1] = boxes[:, 1] - boxes[:, 3] / 2
    xyxy[:, 2] = boxes[:, 0] + boxes[:, 2] / 2
    xyxy[:, 3] = boxes[:, 1] + boxes[:, 3] / 2
    indices = []
    for index in np.argsort(-confidences):
        if all(
            class_ids[index] != class_ids[kept]
            or iou_xyxy(xyxy[index], xyxy[kept]) < 0.7
            for kept in indices
        ):
            indices.append(int(index))
        if len(indices) == 300:
            break
    height, width = image_shape
    result = []
    for index in indices[:300]:
        left, top, right, bottom = xyxy[index]
        result.append({
            "class_id": int(class_ids[index]),
            "confidence": round(float(confidences[index]), 6),
            "xyxy": [
                round(float((left - offset_x) / scale), 3),
                round(float((top - offset_y) / scale), 3),
                round(float((right - offset_x) / scale), 3),
                round(float((bottom - offset_y) / scale), 3),
            ],
        })
    return result


def iou_xyxy(left: np.ndarray, right: np.ndarray) -> float:
    x1 = max(float(left[0]), float(right[0]))
    y1 = max(float(left[1]), float(right[1]))
    x2 = min(float(left[2]), float(right[2]))
    y2 = min(float(left[3]), float(right[3]))
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    left_area = max(0.0, float(left[2] - left[0])) * max(0.0, float(left[3] - left[1]))
    right_area = max(0.0, float(right[2] - right[0])) * max(0.0, float(right[3] - right[1]))
    return intersection / max(1e-6, left_area + right_area - intersection)


def load_frame(args: argparse.Namespace) -> tuple[np.ndarray, str]:
    if args.image:
        image = cv2.imread(str(args.image), cv2.IMREAD_COLOR)
        source = str(args.image)
    else:
        cap = cv2.VideoCapture(str(args.video))
        if not cap.isOpened():
            raise ValueError(f"VIDEO_OPEN_FAILED: {args.video}")
        cap.set(cv2.CAP_PROP_POS_MSEC, args.time_ms)
        ok, image = cap.read()
        cap.release()
        if not ok:
            raise ValueError(f"FRAME_READ_FAILED: {args.video}@{args.time_ms}ms")
        source = f"{args.video}@{args.time_ms}ms"
    if image is None or image.size == 0:
        raise ValueError("IMAGE_READ_FAILED")
    if args.roi:
        x1, y1, x2, y2 = args.roi
        image = image[y1:y2, x1:x2]
    if args.scale != 1:
        image = cv2.resize(image, None, fx=args.scale, fy=args.scale, interpolation=cv2.INTER_CUBIC)
    return image, source


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--image", type=Path)
    source.add_argument("--video", type=Path)
    parser.add_argument("--time-ms", type=float, default=0.0)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"))
    parser.add_argument("--scale", type=float, default=1.0)
    parser.add_argument("--model-size", type=int, default=640)
    parser.add_argument("--conf", type=float, default=0.2)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    image, source_name = load_frame(args)
    tensor, scale, offset_x, offset_y = preprocess(image, args.model_size)

    pt = YOLO(str(args.model))
    pt_result = pt.predict(
        image, imgsz=args.model_size, conf=args.conf, iou=0.7,
        agnostic_nms=False, max_det=300, device="cpu", verbose=False,
        rect=False,
    )[0]
    pt_detections = []
    for box in pt_result.boxes:
        pt_detections.append({
            "class_id": int(box.cls[0]),
            "confidence": round(float(box.conf[0]), 6),
            "xyxy": [round(float(value), 3) for value in box.xyxy[0].tolist()],
        })
    session = ort.InferenceSession(str(args.model.with_suffix(".onnx")), providers=["CPUExecutionProvider"])
    output = session.run(None, {session.get_inputs()[0].name: tensor})[0]
    onnx_detections = decode(output, image.shape[:2], args.model_size, scale, offset_x, offset_y, args.conf)

    report = {
        "source": source_name,
        "input": {
            "shape": list(tensor.shape),
            "sha256": hashlib.sha256(tensor.tobytes()).hexdigest(),
            "letterbox_scale": scale,
            "pad": [offset_x, offset_y],
        },
        "pt": {"model": str(args.model), "detections": pt_detections},
        "onnx": {"model": str(args.model.with_suffix(".onnx")), "raw_shape": list(output.shape), "detections": onnx_detections},
        "limits": {"pt_and_onnx_should_match_after_square_preprocessing": True},
    }
    rendered = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
