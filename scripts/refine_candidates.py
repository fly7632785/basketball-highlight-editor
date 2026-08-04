import argparse
import json
import sys
import time
from pathlib import Path

import cv2
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
    parser.add_argument("--device", default="auto", choices=("auto", "cpu", "mps"))
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def select_device(requested):
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def scan_window(model, video, roi, center_time, window, sample_fps, scale, conf, device):
    x1, y1, x2, y2 = roi
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise RuntimeError(f"Unable to open video: {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    start_time = max(0, center_time - window)
    end_time = min(total_frames / fps, center_time + window)
    start_frame = int(start_time * fps)
    stride = max(1, round(fps / sample_fps))
    cap.set(cv2.CAP_PROP_POS_FRAMES, start_frame)
    records = []
    frame_index = start_frame

    while frame_index / fps <= end_time:
        ok, frame = cap.read()
        if not ok:
            break
        if (frame_index - start_frame) % stride:
            frame_index += 1
            continue
        crop = frame[y1:y2, x1:x2]
        if crop.size == 0:
            raise ValueError(f"ROI is outside the video frame: {roi}")
        if scale != 1:
            crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        result = model.predict(crop, device=device, conf=conf, imgsz=640, verbose=False)[0]
        detections = []
        for box in result.boxes:
            class_index = int(box.cls[0])
            if result.names[class_index] != "ball":
                continue
            bx1, by1, bx2, by2 = box.xyxy[0].tolist()
            coords = [
                x1 + bx1 / scale,
                y1 + by1 / scale,
                x1 + bx2 / scale,
                y1 + by2 / scale,
            ]
            detections.append({
                "name": "ball",
                "confidence": round(float(box.conf[0]), 4),
                "center": [
                    round((coords[0] + coords[2]) / 2, 2),
                    round((coords[1] + coords[3]) / 2, 2),
                ],
                "xyxy": [round(value, 2) for value in coords],
            })
        records.append({"frame": frame_index, "time": round(frame_index / fps, 4), "detections": detections})
        frame_index += 1
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
            args.sample_fps, args.scale, args.conf, device,
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
        "results": refined,
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"kept={sum(bool(item['refined']) for item in refined)} / {len(refined)}")
    print(f"elapsed_seconds={round(time.perf_counter() - started, 3)}")
    print(f"output={output}")


if __name__ == "__main__":
    main(parse_args())
