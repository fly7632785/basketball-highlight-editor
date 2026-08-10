"""Conservative, evidence-only suggestions for human review."""


_PRIMARY_VALUES = {
    "pass_ball",
    "no_shot",
    "rim_out",
    "rebound",
    "net_no_motion",
    "uncertain",
}


def _number(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _flag(*values):
    for value in values:
        if isinstance(value, bool):
            if value:
                return True
        elif isinstance(value, str):
            if value.lower() in {"true", "yes", "rebound", "missed"}:
                return True
        elif value:
            return True
    return False


def _nested(candidate, section, key, default=None):
    value = candidate.get(section)
    if isinstance(value, dict):
        return value.get(key, default)
    return default


def _first(candidate, section, key, default=0.0):
    value = candidate.get(key)
    if value is not None:
        return value
    return _nested(candidate, section, key, default)


def suggest_review_reasons(candidate: dict) -> dict:
    """Suggest one conservative review reason without claiming ground truth.

    Only fields already present on a candidate are interpreted. Missing fields
    are treated as unknown rather than as negative evidence.
    """
    candidate = candidate if isinstance(candidate, dict) else {}
    gates = candidate.get("gates") if isinstance(candidate.get("gates"), dict) else {}
    signals = candidate.get("signals") if isinstance(candidate.get("signals"), dict) else {}
    trajectory = candidate.get("trajectory") if isinstance(candidate.get("trajectory"), dict) else {}
    prediction = candidate.get("prediction") if isinstance(candidate.get("prediction"), dict) else None
    verification = candidate.get("verification") if isinstance(candidate.get("verification"), dict) else {}

    rebound = _flag(
        candidate.get("rebound"),
        verification.get("rebound"),
        verification.get("rim_rebound"),
    )
    lateral_exit = _flag(candidate.get("lateral_exit"), verification.get("lateral_exit"))
    horizontal_ratio = _number(candidate.get("horizontal_ratio"), -1.0)
    net_motion_score = _number(candidate.get("net_motion_score"), -1.0)
    net_changed_ratio = _number(candidate.get("net_changed_ratio"), -1.0)
    net_score = _number(_first(candidate, "signals", "net_score", -1.0), -1.0)
    net_inside_score = _number(
        _first(candidate, "signals", "net_inside_motion_score", -1.0),
        -1.0,
    )
    net_sequence = _number(
        _first(candidate, "signals", "net_sequence_score", -1.0),
        -1.0,
    )
    net_below_peak = _number(
        _first(candidate, "signals", "net_below_peak", -1.0),
        -1.0,
    )
    positive_net = (
        (
            net_inside_score >= 0.35
            and net_sequence >= 0.80
            and net_below_peak >= 0.25
        )
        or
        net_score >= 0.55
        or net_motion_score >= 0.75
        or net_changed_ratio >= 0.129
    )
    weak_net = (
        (net_inside_score >= 0.0 and net_inside_score < 0.20)
        or (net_score >= 0.0 and net_score < 0.15)
    ) and (
        (net_motion_score < 0.0 or net_motion_score < 0.20)
        and (net_changed_ratio < 0.0 or net_changed_ratio < 0.05)
    )

    trajectory_score = _number(
        _first(candidate, "trajectory", "trajectory_score", -1.0), -1.0
    )
    downward_ratio = _number(
        _first(candidate, "trajectory", "downward_ratio", -1.0), -1.0
    )
    point_count = _number(
        _first(candidate, "trajectory", "point_count", -1.0), -1.0
    )
    prediction_score = _number(
        _first(candidate, "prediction", "predict_score", -1.0), -1.0
    )
    fit_r2 = _number(_first(candidate, "prediction", "fit_r2", -1.0), -1.0)
    weak_trajectory = (
        (point_count >= 0.0 and point_count < 4)
        or (trajectory_score >= 0.0 and trajectory_score < 0.45)
        or (prediction is None and (point_count >= 0.0 or trajectory_score >= 0.0))
        or (prediction_score >= 0.0 and prediction_score < 0.60)
        or (fit_r2 >= 0.0 and fit_r2 < 0.75)
    )
    valid_crossing = _flag(
        candidate.get("trajectory_cross"),
        verification.get("trajectory_cross"),
        candidate.get("crossing_valid"),
    )
    crossing_known_invalid = any(
        value is False
        for value in (
            candidate.get("trajectory_cross"),
            verification.get("trajectory_cross"),
            candidate.get("crossing_valid"),
        )
    )
    offset = _number(candidate.get("crossing_offset_per_rim"), -1.0)
    near_rim = 0.0 <= offset <= 1.5
    weak_descent = (
        (downward_ratio >= 0.0 and downward_ratio < 0.55)
        or (trajectory_score >= 0.0 and trajectory_score < 0.50)
    )

    tags = []
    if rebound:
        tags.append("rebound")
    if lateral_exit:
        tags.append("lateral_exit")
    if horizontal_ratio >= 0.65:
        tags.append("high_horizontal_ratio")
    if near_rim:
        tags.append("rim_proximity")
    if weak_trajectory:
        tags.append("weak_trajectory")
    if positive_net:
        tags.append("net_motion")
    elif weak_net:
        tags.append("net_no_motion")
    conflict = rebound and positive_net

    primary = "uncertain"
    confidence = "low"
    if conflict:
        tags.append("uncertain")
    elif rebound:
        primary, confidence = "rebound", "high"
    elif lateral_exit and horizontal_ratio >= 0.65 and not positive_net:
        primary, confidence = "pass_ball", "high"
    elif lateral_exit and near_rim and weak_descent and not positive_net:
        primary, confidence = "rim_out", "medium"
    elif weak_trajectory and (crossing_known_invalid or not valid_crossing) and not positive_net:
        primary, confidence = "no_shot", "medium"
    elif weak_net and valid_crossing and not positive_net:
        primary, confidence = "net_no_motion", "low"
    else:
        tags.append("uncertain")

    evidence = {
        "rebound": rebound,
        "lateral_exit": lateral_exit,
        "horizontal_ratio": None if horizontal_ratio < 0.0 else horizontal_ratio,
        "net_score": None if net_score < 0.0 else net_score,
        "net_inside_motion_score": None if net_inside_score < 0.0 else net_inside_score,
        "net_sequence_score": None if net_sequence < 0.0 else net_sequence,
        "net_below_peak": None if net_below_peak < 0.0 else net_below_peak,
        "net_motion_score": None if net_motion_score < 0.0 else net_motion_score,
        "net_changed_ratio": None if net_changed_ratio < 0.0 else net_changed_ratio,
        "positive_net": positive_net,
        "weak_trajectory": weak_trajectory,
        "valid_crossing": valid_crossing,
        "gates": dict(gates),
    }
    return {
        "primary": primary if primary in _PRIMARY_VALUES else "uncertain",
        "tags": list(dict.fromkeys(tags)),
        "confidence": confidence,
        "evidence": evidence,
    }
