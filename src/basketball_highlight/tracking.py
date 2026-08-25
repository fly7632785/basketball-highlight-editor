from __future__ import annotations

import math
from collections.abc import Iterable, Mapping
from typing import Any


def link_ball_detections(
    records: Iterable[Mapping[str, Any]],
    *,
    anchor: Mapping[str, Any],
    rim_width: float,
    start_time: float | None = None,
    end_time: float | None = None,
    max_gap_seconds: float = 0.6,
) -> list[dict[str, float]]:
    """Link one ball per sampled frame around a known candidate point.

    Association starts from ``anchor`` and runs independently backward and
    forward. Distances are measured relative to the detected rim width so the
    same motion has the same gate at different source resolutions.
    """
    anchor_point = {
        "time": float(anchor["time"]),
        "x": float(anchor["x"]),
        "y": float(anchor["y"]),
    }
    frame_candidates: dict[float, list[dict[str, float]]] = {}
    for record in records:
        try:
            record_time = float(record["time"])
        except (KeyError, TypeError, ValueError):
            continue
        if start_time is not None and record_time < start_time:
            continue
        if end_time is not None and record_time > end_time:
            continue
        for detection in record.get("detections", []):
            if not isinstance(detection, Mapping):
                continue
            center = detection.get("center")
            if (
                str(detection.get("name", "")).lower() != "ball"
                or not isinstance(center, list)
                or len(center) < 2
            ):
                continue
            try:
                point = {
                    "time": record_time,
                    "x": float(center[0]),
                    "y": float(center[1]),
                }
            except (TypeError, ValueError):
                continue
            frame_candidates.setdefault(record_time, []).append(point)

    width = max(1.0, float(rim_width))

    def extend(times: Iterable[float]) -> list[dict[str, float]]:
        linked: list[dict[str, float]] = []
        previous = anchor_point
        for frame_time in times:
            gap = abs(frame_time - previous["time"])
            if gap <= 1e-6:
                continue
            if gap > max_gap_seconds:
                break
            gate = width * (0.75 + 8.0 * gap)

            def rank(point: Mapping[str, float]) -> tuple[float, float, float]:
                distance = math.hypot(
                    point["x"] - previous["x"],
                    point["y"] - previous["y"],
                )
                return distance, point["x"], point["y"]

            nearest = min(frame_candidates[frame_time], key=rank)
            if rank(nearest)[0] > gate:
                continue
            linked.append(nearest)
            previous = nearest
        return linked

    earlier_times = sorted(
        (time for time in frame_candidates if time < anchor_point["time"]),
        reverse=True,
    )
    later_times = sorted(
        time for time in frame_candidates if time > anchor_point["time"]
    )
    before = list(reversed(extend(earlier_times)))
    after = extend(later_times)
    return [*before, anchor_point, *after]
