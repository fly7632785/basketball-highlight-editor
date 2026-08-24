"""Delayed post-crossing verdicts for candidate events.

The detector only proposes a crossing. This module waits for the short
post-crossing observation window before deciding whether the evidence is strong
enough to call ``made``. Uncertain events remain reviewable as ``ambiguous``.
"""


def _continuous_later_points(track, below, rim, verification_window):
    rim_width = max(1.0, float(rim.get("width", 20.0)))
    rim_height = max(1.0, float(rim.get("height", 20.0)))
    points = [below]
    previous = below
    for point in sorted(track, key=lambda item: item["time"]):
        if point["time"] <= below["time"]:
            continue
        if point["time"] > below["time"] + verification_window:
            break
        gap = point["time"] - previous["time"]
        if gap <= 0:
            continue
        if (
            previous["y"] - point["y"] > max(2.0, rim_height * 0.30)
            and abs(point["x"] - previous["x"]) > 1.5 * rim_width
        ):
            break
        distance = ((point["x"] - previous["x"]) ** 2 +
                    (point["y"] - previous["y"]) ** 2) ** 0.5
        gate = max(
            1.75 * rim_width,
            min(
                12.0 * rim_width,
                45.0 * rim_width * gap
                + 2.0 * max(previous.get("width", 0.0), point.get("width", 0.0),
                             previous.get("height", 0.0), point.get("height", 0.0)),
            ),
        )
        if distance > gate:
            break
        points.append(point)
        previous = point
    return points


def _post_crossing_evidence(track, below, rim, verification_window):
    end_time = below["time"] + verification_window
    later = _continuous_later_points(track, below, rim, verification_window)
    rim_y = float(rim["rim_y"])
    rim_height = float(rim.get("height", 20.0))
    rim_width = max(1.0, float(rim.get("width", 20.0)))
    below_depth = max(rim_width * 0.35, rim_height * 0.5)
    persistence_points = [
        point for point in later if point["y"] >= rim_y + below_depth
    ]
    previous_y = below["y"]
    rebound = False
    # 与 events.find_refined_crossings 一致:球已深入篮下之后的回升是
    # 落地反弹(进球的正常后续),只在篮筐附近平面内的回升才计为撞框
    # 反弹,避免把进球后的落地弹跳误判为 missed。
    rebound_zone_bottom = rim_y + max(2.5 * rim_height, 2.5 * rim_width)
    for point in later:
        if point["time"] <= below["time"]:
            continue
        if point["y"] >= rebound_zone_bottom:
            break
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
    deep_corridor_points = [
        point
        for point in persistence_points
        if abs(point["x"] - float(rim["center_x"])) <= half_width
    ]
    if lateral_exit and len(persistence_points) >= 3 and len(deep_corridor_points) == 1 and not rebound:
        lateral_exit = False
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
    # 方向性佐证与 net_support 同口径:此前额外要求时序分 >= 0.99,
    # 接近完美的激活顺序在真实素材上几乎不可达,导致"网动+完整穿框
    # 齐备"的进球永远停在 ambiguous。时序质量已由 0.80 门槛把关。
    net_directional_support = net_support
    complete_crossing = candidate.get("complete_crossing", True) is True
    post_crossing_lateral_recovery = candidate.get(
        "post_crossing_lateral_recovery",
        False,
    ) is True
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
        and (not net_evidence_present or net_directional_support)
    )
    strong_negative = (
        evidence["rebound"] or
        (evidence["lateral_exit"] and not post_crossing_lateral_recovery)
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
