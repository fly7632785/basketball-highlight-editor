"""Canonical source-time sampling used by every analysis adapter."""

from __future__ import annotations

import math


def round_time_ms(value: float) -> int:
    """Round a non-negative timestamp like Kotlin/Swift, not Python round()."""
    if not math.isfinite(value) or value < 0:
        raise ValueError("SAMPLE_TIME_INVALID")
    return math.floor(value + 0.5)


def nearest_frame_index(time_seconds: float, fps: float) -> int:
    """Return the nearest source frame using the cross-platform tie rule."""
    if not math.isfinite(time_seconds) or not math.isfinite(fps) or time_seconds < 0 or fps <= 0:
        raise ValueError("SAMPLE_PARAMETERS_INVALID")
    return math.floor(time_seconds * fps + 0.5)


def first_frame_index(time_seconds: float, fps: float) -> int:
    """Return the first source frame whose presentation time reaches a target."""
    if not math.isfinite(time_seconds) or not math.isfinite(fps) or time_seconds < 0 or fps <= 0:
        raise ValueError("SAMPLE_PARAMETERS_INVALID")
    return math.ceil(time_seconds * fps - 1e-9)


def canonical_sample_times(
    start_seconds: float,
    end_seconds: float,
    sample_fps: float,
) -> list[float]:
    """Return a half-open, drift-free sampling grid in source seconds.

    The grid is defined in time rather than by repeatedly adding a truncated
    frame interval. This is the contract shared with Android and iOS, which
    request the same timestamps from their native decoders.
    """
    if not all(math.isfinite(value) for value in (start_seconds, end_seconds, sample_fps)):
        raise ValueError("SAMPLE_PARAMETERS_INVALID")
    if start_seconds < 0 or end_seconds <= start_seconds or sample_fps <= 0:
        raise ValueError("SAMPLE_PARAMETERS_INVALID")

    start_ms = round_time_ms(start_seconds * 1000.0)
    end_ms = round_time_ms(end_seconds * 1000.0)
    duration_ms = end_ms - start_ms
    count = max(1, math.ceil(duration_ms * sample_fps / 1000.0 - 1e-9))
    times_ms = [
        start_ms + round_time_ms(index * 1000.0 / sample_fps)
        for index in range(count)
    ]
    return [time_ms / 1000.0 for time_ms in times_ms if time_ms < end_ms] or [start_ms / 1000.0]
