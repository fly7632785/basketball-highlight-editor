"""Delayed post-crossing verdicts for candidate events.

The detector only proposes a crossing. This module waits for the short
post-crossing observation window before deciding whether the evidence is strong
enough to call ``made``. Uncertain events remain reviewable as ``ambiguous``.
"""


def _later_points(track, start_time, end_time):
    return [
        point
        for point in track
        if start_time <= point["time"] <= end_time
    ]


def _post_crossing_evidence(track, below, rim, verification_window):
    end_time = below["time"] + verification_window
    later = _later_points(track, below["time"], end_time)
    rim_y = float(rim["rim_y"])
    rim_height = float(rim.get("height", 20.0))
    persistence_points = [
        point for point in later if point["y"] >= rim_y + 10.0
    ]
    previous_y = below["y"]
    rebound = False
    for point in later:
        if point["time"] <= below["time"]:
            continue
        if point["y"] < previous_y - max(8.0, rim_height * 0.18):
            rebound = True
            break
        previous_y = point["y"]

    half_width = max(1.0, float(rim.get("width", 20.0)) / 2.0)
    lateral_exit = any(
        abs(point["x"] - float(rim["center_x"])) > max(3.0 * half_width, 45.0)
        and point["y"] < rim_y + 80.0
        for point in later
    )
    return {
        "verification_window_s": verification_window,
        "decision_time": round(end_time, 3),
        "ball_persistence": round(min(1.0, len(persistence_points) / 3.0), 3),
        "post_crossing_points": len(later),
        "rebound": rebound,
        "lateral_exit": lateral_exit,
    }


def resolve_verdict(
    candidate,
    track,
    rim,
    verification_window=0.8,
):
    """Resolve one candidate after observing its short post-crossing window.

    ``made`` is intentionally conservative. ``missed`` requires strong
    counter-evidence; everything else remains ``ambiguous`` for human review.
    """
    evidence = _post_crossing_evidence(
        track,
        candidate["below"],
        rim,
        verification_window,
    )
    gates = candidate.get("gates", {})
    signals = candidate.get("signals", {})
    net_score = float(signals.get("net_score", 0.0))
    audio_score = float(signals.get("audio_score", 0.0))
    persistence = evidence["ball_persistence"]
    strong_positive = (
        persistence >= 0.67
        and (
            gates.get("high_precision") is True
            or gates.get("prediction_review") is True
            or net_score >= 0.55
            or audio_score >= 0.65
            or float(candidate.get("score", 0.0)) >= 0.72
        )
    )
    strong_negative = evidence["rebound"] or evidence["lateral_exit"]
    if strong_negative:
        verdict = "missed"
    elif strong_positive:
        verdict = "made"
    else:
        verdict = "ambiguous"

    return {
        "state": "confirmed",
        "verdict": verdict,
        "trajectory_cross": True,
        "net_swish": net_score >= 0.55,
        "audio_support": audio_score >= 0.65,
        "rim_rebound": evidence["rebound"],
        "lateral_exit": evidence["lateral_exit"],
        "event_time_source": "rim_crossing_interpolated",
        **evidence,
    }
