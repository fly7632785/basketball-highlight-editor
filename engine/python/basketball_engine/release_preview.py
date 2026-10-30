"""Cheap release-area stills from existing BHE ball evidence and video proxy.

No person detector, tracking model, or additional ball inference is used here.
All geometry is approximate; the user supplies the shooter's identity.
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path

from .adapters.analysis import PipelineCancelled
from basketball_highlight.tracking import link_ball_detections
from .protocol import ProtocolError

METHOD = "ball_release_preview_v1"


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return default


def source_fingerprint(source):
    stat = source.stat()
    return {"name": source.name, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def cached_context(store, video, source):
    """Reuse only a proxy bound to this source and its recorded trim offset."""
    for job in store.list_jobs(
        store.project()["id"],
        job_type="analysis",
        video_id=video["id"],
        descending=True,
    ):
        checkpoint = read_json_string(job.get("checkpoint_json"))
        params = checkpoint.get("analysis_parameters") or {}
        stat = source.stat()
        if (
            params.get("source_path") != str(source)
            or params.get("source_size_bytes") != stat.st_size
            or params.get("source_mtime_ns") != stat.st_mtime_ns
        ):
            continue
        proxy = Path(checkpoint.get("proxy_video") or "")
        if proxy.is_file() and proxy.resolve().is_relative_to(
            (store.root / "artifacts").resolve()
        ):
            return {
                "proxy": proxy,
                "offset_ms": int(params.get("analysis_start_ms") or 0),
                "coarse": read_json(checkpoint.get("coarse_detections"), {}),
            }
    return {"proxy": source, "offset_ms": 0, "coarse": {}}


def read_json_string(value):
    try:
        result = json.loads(value or "{}")
        return result if isinstance(result, dict) else {}
    except (TypeError, ValueError):
        return {}


def ball_points(candidate, coarse, scale):
    evidence = read_json_string(candidate.get("evidence_json"))
    overlay = evidence.get("overlay") or {}
    points = list(overlay.get("trajectory") or [])
    event = candidate["event_time_ms"] / 1000
    if coarse.get("records"):
        # Extend the existing trajectory towards release using cached detections.
        # Association is anchored at this shot; it does not scan another frame.
        near = [p for p in points if isinstance(p, dict) and p.get("time") is not None]
        anchor = min(near, key=lambda p: abs(float(p["time"]) - event), default=None)
        if anchor:
            anchor = {
                "time": anchor["time"],
                "x": anchor["x"] / scale[0],
                "y": anchor["y"] / scale[1],
            }
            rim_width = float((overlay.get("rim") or {}).get("width") or 40) / scale[0]
        else:
            anchor = evidence.get("above")
            rim_width = float((coarse.get("rim") or {}).get("width") or 30)
        if isinstance(anchor, dict):
            chain = link_ball_detections(
                coarse["records"],
                anchor=anchor,
                rim_width=rim_width,
                start_time=event - 3.5,
                end_time=event + 0.2,
            )
            if len(chain) > len(points):
                points = [
                    {**p, "x": p["x"] * scale[0], "y": p["y"] * scale[1]} for p in chain
                ]
    clean = {}
    for point in points:
        try:
            t, x, y = (float(point[k]) for k in ("time", "x", "y"))
            if all(math.isfinite(v) for v in (t, x, y)) and event - 3.5 <= t <= event:
                clean[t] = {"time": t, "x": x, "y": y}
        except (KeyError, TypeError, ValueError):
            continue
    return [clean[t] for t in sorted(clean)]


def estimate_release(candidate, points, width, height):
    """Find a sustained upward launch, or explicitly fall back to a wide view."""
    event = candidate["event_time_ms"] / 1000
    # A post-rim bounce is a new motion segment, not the original release.
    for index in range(2, len(points)):
        a, b, c = points[index - 2 : index + 1]
        dt1, dt2 = b["time"] - a["time"], c["time"] - b["time"]
        if not (0 < dt1 <= 0.5 and 0 < dt2 <= 0.5):
            continue
        vy1, vy2 = (b["y"] - a["y"]) / dt1, (c["y"] - b["y"]) / dt2
        if vy1 > height * 0.1 and vy2 < -height * 0.05 and vy1 - vy2 > height * 0.3:
            points = points[:index]
            break
    rim = (read_json_string(candidate.get("evidence_json")).get("overlay") or {}).get(
        "rim"
    ) or {}
    band = max(height * 0.38, float(rim.get("rim_y", height * 0.35)) + height * 0.05)
    band = min(height * 0.68, band)
    runs, run = [], []
    for left, right in zip(points, points[1:]):
        dt = right["time"] - left["time"]
        rising = (
            0.015 <= dt <= 0.5
            and (right["y"] - left["y"]) / dt < -height * 0.08
            and abs(right["x"] - left["x"]) / dt < width * 1.5
        )
        if rising:
            if not run:
                run.append(left)
            run.append(right)
        elif run:
            runs.append(run)
            run = []
    if run:
        runs.append(run)
    runs = [
        r
        for r in runs
        if len(r) >= 3
        and r[0]["time"] < event - 0.15
        and r[0]["y"] - r[-1]["y"] > height * 0.035
    ]
    point, reason = None, "upward_ball_motion_estimate"
    if runs:
        launch = max(runs, key=lambda r: r[0]["y"] - r[-1]["y"])
        point = dict(launch[0])
        for left, right in zip(launch, launch[1:]):
            if left["y"] >= band >= right["y"]:
                fraction = (left["y"] - band) / (left["y"] - right["y"])
                point = {
                    key: left[key] + (right[key] - left[key]) * fraction
                    for key in ("time", "x", "y")
                }
                break
    # A crop around the rim often sees only the descending flight. A bounded
    # quadratic back-projection can recover an approximate earlier launch view.
    if (
        len(points) >= 5
        and points[-1]["time"] - points[0]["time"] >= 0.3
        and (point is None or point["y"] < band)
    ):
        import numpy as np

        ts = np.array([p["time"] - event for p in points])
        ys = np.array([p["y"] for p in points])
        xs = np.array([p["x"] for p in points])
        design = np.column_stack((ts * ts, ts, np.ones_like(ts)))
        a, b, c = np.linalg.lstsq(design, ys, rcond=None)[0]
        fit = design @ np.array([a, b, c])
        total = float(np.sum((ys - ys.mean()) ** 2))
        r2 = 1 - float(np.sum((ys - fit) ** 2)) / total if total > 1 else 0
        discriminant = b * b - 4 * a * (c - band)
        if height * 0.03 < a < height * 5 and r2 >= 0.8 and discriminant > 0:
            launch_t = float((-b - math.sqrt(discriminant)) / (2 * a))
            mx, bx = np.linalg.lstsq(
                np.column_stack((ts, np.ones_like(ts))), xs, rcond=None
            )[0]
            launch_x = float(mx * launch_t + bx)
            back = points[0]["time"] - (event + launch_t)
            if (
                0.25 <= -launch_t <= 2.8
                and -0.15 <= back <= 1.6
                and 0 <= launch_x <= width
            ):
                point = {"time": event + launch_t, "x": launch_x, "y": band}
                reason = "existing_ball_flight_backprojection"
    if point is None:
        return {
            "time_ms": max(0, candidate["event_time_ms"] - 1300),
            "bbox": None,
            "reason": "release_not_visible_in_existing_ball_track",
        }
    time_ms = round(point["time"] * 1000)
    cx, cy = point["x"], point["y"]
    # Keep a generous area below the rising ball: a region, not a person box.
    box_width, box_height = width * 0.38, height * 0.76
    left = max(0, min(width - box_width, cx - box_width / 2))
    top = max(0, min(height - box_height, cy - height * 0.27))
    return {
        "time_ms": time_ms,
        "bbox": [left, top, left + box_width, top + box_height],
        "reason": reason,
    }


def render_release_previews(
    video,
    source,
    candidates,
    directory,
    generation,
    *,
    proxy=None,
    offset_ms=0,
    coarse=None,
    cancel=None,
    progress=None,
    on_candidate=None,
):
    """Read a few sorted frames from the existing proxy, with bounded memory."""
    import cv2

    source = Path(source)
    proxy = Path(proxy or source)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    capture = cv2.VideoCapture(str(proxy))
    if not capture.isOpened():
        raise ProtocolError("SHOOTER_FRAME_MISSING", "无法读取现有分析代理或源视频")
    fps = capture.get(cv2.CAP_PROP_FPS) or 5
    count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    pw, ph = (
        int(capture.get(prop))
        for prop in (cv2.CAP_PROP_FRAME_WIDTH, cv2.CAP_PROP_FRAME_HEIGHT)
    )
    sw, sh = int(video["width"]), int(video["height"])
    if min(count, pw, ph, sw, sh) <= 0:
        capture.release()
        raise ProtocolError("SHOOTER_FRAME_MISSING", "分析代理的画面尺寸或帧数无效")
    scale = sw / pw, sh / ph
    coarse = coarse or {}
    # Old artifacts can refer to an original-resolution scan. Never apply the
    # proxy scale to those coordinates without verifying their input video.
    if coarse.get("video") and Path(coarse["video"]).resolve() != proxy.resolve():
        coarse = {}
    fingerprint = source_fingerprint(source)
    items, requests, expected, done = [], {}, {}, {}
    for candidate in candidates:
        points = ball_points(candidate, coarse, scale)
        release = estimate_release(candidate, points, sw, sh)
        release_time = max(
            offset_ms,
            min(round(offset_ms + (count - 1) * 1000 / fps), release["time_ms"]),
        )
        token = hashlib.sha256(candidate["id"].encode()).hexdigest()[:20]
        item = {
            "candidate_id": candidate["id"],
            "video_id": candidate["video_id"],
            "event_time_ms": candidate["event_time_ms"],
            "generation": generation,
            "method": METHOD,
            "source_fingerprint": fingerprint,
            "release_time_ms": release_time,
            "release_uncertain": True,
            "reason": release["reason"],
            "frames": [],
            "image_source": "analysis_proxy"
            if proxy.resolve() != source.resolve()
            else "source_stills",
            "proxy_frame_size": [pw, ph],
            "proxy_fps": fps,
            "proxy_offset_ms": offset_ms,
        }
        indices = sorted(
            {
                min(
                    count - 1,
                    max(0, round((release_time - offset_ms) * fps / 1000) + delta),
                )
                for delta in (-1, 0, 1)
            }
        )
        expected[token], done[token] = len(indices), 0
        items.append(item)
        for frame_index in indices:
            requests.setdefault(frame_index, []).append((token, item, release["bbox"]))
    read_position = -1
    try:
        for ordinal, frame_index in enumerate(sorted(requests)):
            if cancel and cancel.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            if read_position < 0 or frame_index - read_position > max(24, fps * 3):
                capture.set(cv2.CAP_PROP_POS_FRAMES, frame_index)
            else:
                for _ in range(frame_index - read_position - 1):
                    capture.grab()
            ok, frame = capture.read()
            read_position = frame_index
            if not ok:
                raise ProtocolError(
                    "SHOOTER_FRAME_MISSING", "现有代理的出手画面读取失败"
                )
            time_ms = offset_ms + round(frame_index * 1000 / fps)
            for token, item, bbox in requests[frame_index]:
                context = frame.copy()
                focus = None
                if bbox:
                    x1, y1, x2, y2 = [
                        round(v / scale[i % 2]) for i, v in enumerate(bbox)
                    ]
                    x1, y1, x2, y2 = max(0, x1), max(0, y1), min(pw, x2), min(ph, y2)
                    if x2 > x1 and y2 > y1:
                        crop = frame[y1:y2, x1:x2].copy()
                        cv2.rectangle(context, (x1, y1), (x2, y2), (235, 165, 55), 2)
                        crop_path = directory / f"{token}_{time_ms}_release.jpg"
                        if not cv2.imwrite(
                            str(crop_path), crop, [cv2.IMWRITE_JPEG_QUALITY, 85]
                        ):
                            raise OSError("Could not save release area")
                        focus = {
                            "bbox": bbox,
                            "crop_path": str(crop_path),
                            "kind": "approximate_release_area",
                        }
                context_path = directory / f"{token}_{time_ms}_context.jpg"
                if pw > 1280:
                    context = cv2.resize(context, (1280, round(ph * 1280 / pw)))
                if not cv2.imwrite(
                    str(context_path), context, [cv2.IMWRITE_JPEG_QUALITY, 83]
                ):
                    raise OSError("Could not save release context")
                item["frames"].append(
                    {
                        "time_ms": time_ms,
                        "context_path": str(context_path),
                        "focus_region": focus,
                    }
                )
                done[token] += 1
                if on_candidate and done[token] == expected[token]:
                    on_candidate(item)
            if progress:
                progress((ordinal + 1) / max(1, len(requests)))
    finally:
        capture.release()
    if source_fingerprint(source) != fingerprint:
        raise ProtocolError("VIDEO_SOURCE_CHANGED", "生成出手画面时原视频发生变化")
    return items
