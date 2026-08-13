from basketball_highlight.review_reason import suggest_review_reasons


def test_rebound_is_primary_when_explicit_rebound_evidence_exists():
    result = suggest_review_reasons({
        "rebound": True,
        "lateral_exit": True,
        "horizontal_ratio": 0.8,
    })

    assert result["primary"] == "rebound"
    assert result["confidence"] == "high"
    assert "rebound" in result["tags"]


def test_lateral_exit_near_rim_without_downward_persistence_suggests_rim_out():
    result = suggest_review_reasons({
        "lateral_exit": True,
        "horizontal_ratio": 0.35,
        "crossing_offset_per_rim": 0.8,
        "trajectory": {"downward_ratio": 0.2, "trajectory_score": 0.3},
        "signals": {"net_score": 0.05},
    })

    assert result["primary"] == "rim_out"
    assert "lateral_exit" in result["tags"]


def test_high_horizontal_exit_without_positive_support_suggests_pass_ball():
    result = suggest_review_reasons({
        "horizontal_ratio": 0.75,
        "lateral_exit": True,
        "audio_support": False,
        "audio_score": 0.1,
        "net_motion_score": 0.05,
        "net_changed_ratio": 0.01,
    })

    assert result["primary"] == "pass_ball"
    assert result["confidence"] == "high"


def test_weak_trajectory_without_valid_crossing_suggests_no_shot():
    result = suggest_review_reasons({
        "trajectory": {"point_count": 2, "trajectory_score": 0.1},
        "prediction": None,
        "verification": {"trajectory_cross": False},
        "net_motion_score": 0.0,
        "audio_support": False,
    })

    assert result["primary"] == "no_shot"
    assert result["confidence"] == "medium"


def test_net_no_motion_is_only_a_low_confidence_suggestion():
    result = suggest_review_reasons({
        "verification": {"trajectory_cross": True},
        "trajectory_score": 0.65,
        "net_motion_score": 0.02,
        "net_changed_ratio": 0.01,
        "signals": {"net_score": 0.04},
    })

    assert result["primary"] == "net_no_motion"
    assert result["confidence"] == "low"
    assert "net_no_motion" in result["tags"]


def test_conflicting_positive_and_negative_signals_are_uncertain():
    result = suggest_review_reasons({
        "rebound": False,
        "lateral_exit": True,
        "horizontal_ratio": 0.72,
        "audio_support": True,
        "audio_score": 0.9,
        "signals": {"net_score": 0.9},
    })

    assert result["primary"] == "uncertain"
    assert result["confidence"] == "low"
    assert "uncertain" in result["tags"]


def test_empty_candidate_is_conservative():
    result = suggest_review_reasons({})

    assert result["primary"] == "uncertain"
    assert result["confidence"] == "low"
    assert isinstance(result["evidence"], dict)
