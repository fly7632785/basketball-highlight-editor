from basketball_highlight.verdict import resolve_verdict


RIM = {"center_x": 490, "rim_y": 325, "width": 20, "height": 20}


def _candidate(**overrides):
    value = {
        "time": 1.25,
        "score": 0.75,
        "above": {"time": 1.1, "x": 490, "y": 300},
        "below": {"time": 1.4, "x": 491, "y": 345},
        "gates": {"high_precision": True},
        "signals": {"net_score": 0.0},
    }
    value.update(overrides)
    return value


def test_resolve_verdict_marks_persistent_clean_crossing_as_made():
    track = [
        {"time": 1.1, "x": 490, "y": 300},
        {"time": 1.4, "x": 491, "y": 345},
        {"time": 1.55, "x": 492, "y": 365},
        {"time": 1.7, "x": 493, "y": 390},
    ]

    result = resolve_verdict(_candidate(), track, RIM)

    assert result["verdict"] == "made"
    assert result["ball_persistence"] == 1.0
    assert result["rim_rebound"] is False


def test_resolve_verdict_marks_rebound_as_missed():
    track = [
        {"time": 1.1, "x": 490, "y": 300},
        {"time": 1.4, "x": 491, "y": 345},
        {"time": 1.55, "x": 492, "y": 370},
        {"time": 1.7, "x": 492, "y": 350},
    ]

    result = resolve_verdict(_candidate(), track, RIM)

    assert result["verdict"] == "missed"
    assert result["rim_rebound"] is True


def test_resolve_verdict_keeps_weak_evidence_ambiguous():
    track = [
        {"time": 1.1, "x": 490, "y": 300},
        {"time": 1.4, "x": 491, "y": 345},
    ]

    result = resolve_verdict(
        _candidate(score=0.3, gates={"high_precision": False}),
        track,
        RIM,
    )

    assert result["verdict"] == "ambiguous"


def test_resolve_verdict_rejects_reliable_zero_net_motion():
    track = [
        {"time": 1.1, "x": 490, "y": 300},
        {"time": 1.4, "x": 491, "y": 345},
        {"time": 1.55, "x": 492, "y": 365},
        {"time": 1.7, "x": 493, "y": 390},
    ]
    candidate = _candidate(
        signals={
            "net_score": 0.0,
            "net_signal_available": True,
            "net_no_motion": True,
        },
    )

    result = resolve_verdict(candidate, track, RIM)

    assert result["verdict"] == "missed"
    assert result["net_no_motion"] is True
