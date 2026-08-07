"""Helpers for deriving a usable ball-detection ROI from hoop detections."""

from __future__ import annotations

from statistics import median
from typing import Any, Iterable


def _clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def expand_hoop_bbox_to_roi(
    bbox: Iterable[float],
    frame_width: int,
    frame_height: int,
    *,
    min_width_ratio: float = 0.14,
    min_height_ratio: float = 0.28,
    max_width_ratio: float = 0.65,
    max_height_ratio: float = 0.75,
) -> dict[str, int]:
    """Expand a tight hoop box into the surrounding ball-search region.

    The detector needs substantially more context than the rim box itself:
    the ball must be visible before entering the hoop and after crossing it.
    """
    values = [float(value) for value in bbox]
    if len(values) != 4 or frame_width <= 0 or frame_height <= 0:
        raise ValueError("ROI_INPUT_INVALID")
    x1, y1, x2, y2 = values
    if x2 <= x1 or y2 <= y1:
        raise ValueError("ROI_INPUT_INVALID")

    rim_width = max(4.0, x2 - x1)
    rim_height = max(4.0, y2 - y1)
    center_x = (x1 + x2) / 2.0
    center_y = (y1 + y2) / 2.0

    roi_width = max(rim_width * 12.0, frame_width * min_width_ratio)
    roi_height = max(rim_height * 20.0, frame_height * min_height_ratio)
    roi_width = min(roi_width, frame_width * max_width_ratio)
    roi_height = min(roi_height, frame_height * max_height_ratio)

    # Bias the region upwards because the approach trajectory is usually above
    # the rim; retain enough space below for the net and falling ball.
    top_extent = max(rim_height * 8.0, roi_height * 0.44)
    bottom_extent = max(rim_height * 12.0, roi_height * 0.56)
    total_height = top_extent + bottom_extent
    if total_height > frame_height * max_height_ratio:
        scale = (frame_height * max_height_ratio) / total_height
        top_extent *= scale
        bottom_extent *= scale

    left = _clamp(center_x - roi_width / 2.0, 0.0, float(frame_width - 1))
    right = _clamp(center_x + roi_width / 2.0, 1.0, float(frame_width))
    top = _clamp(center_y - top_extent, 0.0, float(frame_height - 1))
    bottom = _clamp(center_y + bottom_extent, 1.0, float(frame_height))

    return {
        "x1": int(round(left)),
        "y1": int(round(top)),
        "x2": int(round(max(left + 1.0, right))),
        "y2": int(round(max(top + 1.0, bottom))),
    }


def select_stable_hoop(
    detections: Iterable[dict[str, Any]],
    frame_width: int,
    frame_height: int,
    *,
    min_confidence: float = 0.05,
    min_samples: int = 2,
) -> dict[str, Any] | None:
    """Select the most stable hoop cluster from sampled full-frame detections."""
    candidates: list[dict[str, Any]] = []
    for detection in detections:
        bbox = detection.get("bbox") or detection.get("xyxy")
        if not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
            continue
        confidence = float(detection.get("confidence", 0.0))
        if confidence < min_confidence:
            continue
        x1, y1, x2, y2 = (float(value) for value in bbox)
        if x2 <= x1 or y2 <= y1:
            continue
        candidates.append(
            {
                "bbox": [x1, y1, x2, y2],
                "confidence": confidence,
                "center": ((x1 + x2) / 2.0, (y1 + y2) / 2.0),
                "area": (x2 - x1) * (y2 - y1),
            }
        )

    if len(candidates) < min_samples:
        return None

    cluster_radius = max(60.0, frame_width * 0.10)
    clusters: list[list[dict[str, Any]]] = []
    for candidate in candidates:
        best_cluster = None
        best_distance = None
        for cluster in clusters:
            center_x = median(item["center"][0] for item in cluster)
            center_y = median(item["center"][1] for item in cluster)
            distance = (
                (candidate["center"][0] - center_x) ** 2
                + (candidate["center"][1] - center_y) ** 2
            ) ** 0.5
            if distance <= cluster_radius and (
                best_distance is None or distance < best_distance
            ):
                best_cluster = cluster
                best_distance = distance
        if best_cluster is None:
            clusters.append([candidate])
        else:
            best_cluster.append(candidate)

    clusters = [cluster for cluster in clusters if len(cluster) >= min_samples]
    if not clusters:
        return None

    def cluster_key(cluster: list[dict[str, Any]]) -> tuple[float, float, float]:
        return (
            float(len(cluster)),
            median(item["confidence"] for item in cluster),
            median(item["area"] for item in cluster),
        )

    selected = max(clusters, key=cluster_key)
    bbox = [
        median(item["bbox"][index] for item in selected)
        for index in range(4)
    ]
    confidence = median(item["confidence"] for item in selected)
    roi = expand_hoop_bbox_to_roi(bbox, frame_width, frame_height)
    return {
        "hoop_bbox": [round(value, 2) for value in bbox],
        "roi": roi,
        "confidence": round(confidence, 3),
        "samples": len(selected),
        "stability": round(min(1.0, len(selected) / max(1, len(candidates))), 3),
    }
