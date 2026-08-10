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
    rim_width = max(1.0, float(rim.get("width", 20.0)))
    below_depth = max(rim_width * 0.35, rim_height * 0.5)
    persistence_points = [
        point for point in later if point["y"] >= rim_y + below_depth
    ]
    previous_y = below["y"]
    rebound = False
    for point in later:
        if point["time"] <= below["time"]:
            continue
        if point["y"] < previous_y - max(rim_width * 0.25, rim_height * 0.18):
            rebound = True
            break
        previous_y = point["y"]

    half_width = max(1.0, float(rim.get("width", 20.0)) / 2.0)
    lateral_exit = any(
        abs(point["x"] - float(rim["center_x"])) > 3.0 * half_width
        and point["y"] <= rim_y + max(4.0 * rim_height, 4.0 * rim_width)
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
    net_inside_score = float(signals.get("net_inside_motion_score", net_score))
    net_sequence = float(signals.get("net_sequence_score", 1.0))
    net_evidence_present = bool(signals.get("net_signal_available", False))
    net_no_motion = bool(signals.get("net_no_motion", False))
    net_support = (
        net_inside_score >= 0.35
        and net_sequence >= 0.80
        and float(signals.get("net_below_peak", 0.0)) >= 0.25
    )
    complete_crossing = candidate.get("complete_crossing", True) is True
    prediction_review = gates.get("prediction_review") is True
    persistence = evidence["ball_persistence"]
    if net_evidence_present:
        positive_gate = net_support
    else:
        positive_gate = (
            gates.get("high_precision") is True or
            net_score >= 0.55 or
            float(candidate.get("score", 0.0)) >= 0.72
        )
    strong_positive = (
        persistence >= 0.67
        and complete_crossing
        and positive_gate
    )
    strong_negative = (
        evidence["rebound"] or
        evidence["lateral_exit"] or
        (net_evidence_present and net_no_motion) or
        not complete_crossing and not prediction_review
    )
    if strong_negative:
        verdict = "missed"
    elif strong_positive:
        verdict = "made"
    else:
        verdict = "ambiguous"

    return {
        "state": "confirmed",
        "verdict": verdict,
        "trajectory_cross": complete_crossing,
        "complete_crossing": complete_crossing,
        "net_swish": net_support,
        "net_inside_motion_score": round(net_inside_score, 3),
        "net_sequence_score": round(net_sequence, 3),
        "net_support": net_support,
        "net_signal_available": net_evidence_present,
        "net_no_motion": net_no_motion,
        "rim_rebound": evidence["rebound"],
        "lateral_exit": evidence["lateral_exit"],
        "event_time_source": "rim_crossing_interpolated",
        **evidence,
    }
