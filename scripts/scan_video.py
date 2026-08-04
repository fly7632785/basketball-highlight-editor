import argparse
import json
import time
from pathlib import Path

import cv2
import torch
from ultralytics import YOLO


def parse_args():
    parser = argparse.ArgumentParser(description="Scan a basketball video with an existing YOLO model.")
    parser.add_argument("--video", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--roi", nargs=4, type=int, metavar=("X1", "Y1", "X2", "Y2"), required=True)
    parser.add_argument("--sample-fps", type=float, default=5)
    parser.add_argument("--scale", type=int, default=4)
    parser.add_argument("--conf", type=float, default=0.15)
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps"))
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def select_device(requested):
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def scan_video(args):
    video = Path(args.video)
    model_path = Path(args.model)
    output = Path(args.output)
    x1, y1, x2, y2 = args.roi
    device = select_device(args.device)

    model = YOLO(str(model_path))
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise RuntimeError(f"Unable to open video: {video}")

    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    stride = max(1, round(fps / args.sample_fps))
    records = []
    frame_index = 0
    started = time.perf_counter()

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if frame_index % stride:
            frame_index += 1
            continue

        crop = frame[y1:y2, x1:x2]
        if crop.size == 0:
            raise ValueError(f"ROI is outside the video frame: {(x1, y1, x2, y2)}")
        if args.scale != 1:
            crop = cv2.resize(crop, None, fx=args.scale, fy=args.scale, interpolation=cv2.INTER_CUBIC)

        result = model.predict(crop, device=device, conf=args.conf, imgsz=640, verbose=False)[0]
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

        records.append({
            "frame": frame_index,
            "time": round(frame_index / fps, 4),
            "detections": detections,
        })
        frame_index += 1

    cap.release()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "video": str(video),
        "model": str(model_path),
        "device": device,
        "fps": fps,
        "frame_count": frame_count,
        "sample_fps": args.sample_fps,
        "roi": [x1, y1, x2, y2],
        "scale": args.scale,
        "records": records,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    scan_video(parse_args())
