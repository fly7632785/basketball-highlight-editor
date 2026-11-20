"""Synthetic rule tests and optional private-data integration regressions."""
import copy

import pytest

from basketball_highlight.rim_check import (
    _dedupe_balls,
    _local_net_response_ratio,
    _net_hold_frames,
    _passage_speed_ratio,
    apply_video_occlusion,
    assess_rim_crossing,
    keep_unless_seen,
)
from evaluate_outcomes import (
    align_labels,
    event_ms,
    indexed,
    load_baseline,
    metrics,
    replay,
)
from .test_rim_check import RIM, ball, late_fall


def test_duplicate_box_at_net_mouth_does_not_split_a_real_crossing():
    ys = [-1.2, -0.9, -0.6, -0.3, -0.02, 0.3, 0.6, 0.9, 1.2, 1.6]
    frames = [[ball(0, y)] for y in ys]
    frames[4].append(ball(0.03, 0.07, conf=0.6))
    original = copy.deepcopy(frames)
    check = assess_rim_crossing(frames, RIM)
    assert check["entry"] is True
    assert check["reached_net_bottom"] is True
    assert check["reason"] == "not_occluded"  # geometry recovered; video policy still applies
    assert frames == original


def test_deduplication_retains_distinct_simultaneous_balls():
    frames = [[{"x": 0, "y": 0, "conf": 0.8}, {"x": 0.5, "y": 0, "conf": 0.7}]]
    assert _dedupe_balls(frames) == frames


def test_speed_ratio_needs_two_short_strong_intervals_on_each_side():
    path = [{"i": i, "x": 0, "y": y, "conf": 0.9} for i, y in enumerate(
        [-0.9, -0.6, -0.3, 0.0, 0.4, 0.9])]
    assert _passage_speed_ratio(path, 3) == 1.5
    assert _passage_speed_ratio(path[:-1], 3) is None
    assert _passage_speed_ratio([{**p, "i": p["i"] * 4} for p in path], 12) is None
    assert _passage_speed_ratio([{**p, "conf": 0.3} for p in path], 3) is None


def thin_net_video(extra):
    # Exactly two hidden crossings keep the old video-wide occlusion rule off.
    return apply_video_occlusion(
        [late_fall(9, hidden={6, 7}) for _ in range(2)]
        + [late_fall(9) for _ in range(6)] + [extra]
    )[-1]


def passage(xs=0.0, acceleration=True, push=1.5, hidden=()):
    ys = [-1.2, -0.9, -0.6, -0.3, 0.0, 0.4, 0.9, 1.3, 1.8]
    if not acceleration:
        ys = [-1.2 + i * 0.3 for i in range(12)]
    frames = [[] for _ in range(30)] + [
        [] if i in hidden else [ball(xs, y)] for i, y in enumerate(ys)
    ]
    series = [None] + [1.0] * 34 + [push] * 30
    return assess_rim_crossing(frames, RIM, series)


def test_accelerating_passage_with_weak_relative_net_response_is_a_miss():
    check = thin_net_video(passage())
    assert check["passage_speed_ratio"] == 1.5
    assert check["net_response_ratio"] == 0.5
    assert check["reason"] == "net_unresponsive"
    assert keep_unless_seen(check, refined=True)["status"] == "rejected"


def test_small_net_response_alone_does_not_reject_a_make():
    assert thin_net_video(passage(acceleration=False))["status"] == "made"


def test_strong_net_response_keeps_a_central_accelerating_make():
    assert thin_net_video(passage(push=9))["status"] == "made"


def test_fully_visible_side_passage_is_not_rescued_by_large_net_motion():
    check = thin_net_video(passage(xs=-0.6, push=9))
    assert check["reason"] == "rim_bypass"
    assert check["net_response_ratio"] == 8


def test_hidden_rim_roller_is_not_rejected_by_the_side_passage_rule():
    check = thin_net_video(passage(xs=0.6, acceleration=False, push=9, hidden={4}))
    assert check["hidden_frames"] >= 1
    assert check["status"] == "made"


def test_missing_or_sparse_motion_does_not_invent_a_negative_response():
    check = passage()
    check["net_motion"] = check["net_response_ratio"] = None
    assert thin_net_video(check)["status"] == "made"


def test_precise_anchor_precedes_rounded_time_and_ids_are_unique():
    assert event_ms({"event_time_ms": 1005, "event_ms": 1004, "time": 1}) == 1005
    assert event_ms({"event_ms": 1004, "time": 1}) == 1004
    with pytest.raises(ValueError, match="DUPLICATE_ID"):
        indexed([{"id": "a"}, {"id": "a"}], "id")


def test_evaluation_requires_explicit_truth_and_matching_millisecond_anchor():
    candidates = [{"id": "a", "time": 1, "event_time_ms": 1005}]
    labels = [{"candidate_id": "a", "event_time_ms": 1005, "is_shot": True, "human_outcome": "made"}]
    assert align_labels(candidates, labels)[0]["event_time_ms"] == 1005
    with pytest.raises(ValueError, match="EVENT_TIME"):
        align_labels(candidates, [{**labels[0], "event_time_ms": 1010}])
    with pytest.raises(ValueError, match="EXPLICIT_TRUTH"):
        align_labels(candidates, [{**labels[0], "human_outcome": "unknown"}])
    with pytest.raises(ValueError, match="LABEL_ID"):
        align_labels(candidates + [{"id": "b", "time": 2}], labels)


def test_unknowns_remain_in_the_denominator_without_becoming_binary_errors():
    rows = [
        {"human_outcome": "made", "check": {"status": "made"}},
        {"human_outcome": "missed", "check": {"status": "made"}},
        {"human_outcome": "made", "check": {"status": "unsure"}},
        {"human_outcome": "missed", "check": {"status": "skipped"}},
    ]
    result = metrics(rows, "check")
    assert result["binary_accuracy"] == 0.5
    assert result["coverage"] == 0.5
    assert result["correct_definite_share"] == 0.25
    assert result["made_precision"] == 0.5
    assert result["missed_precision"] is None
    assert result["false_positive"] == 1
    assert result["false_negative"] == 0
    assert result["abstention"] == 2


def test_replay_accepts_legacy_refined_rim_without_mutating_the_candidate():
    candidate = {"id": "a", "time": 1, "anchor_source": "refined", "overlay": {"rim": RIM}}
    original = copy.deepcopy(candidate)
    result, _ = replay([candidate], {"results": [{"status": "rejected", "frames": [[]] * 16}]})
    assert result["a"]["status"] == "unsure"
    assert candidate == original

def test_non_shots_are_separate_from_binary_outcome_truth():
    candidates = [{"id": "a", "time": 1}, {"id": "b", "time": 2}]
    labels = [{"candidate_id": "a", "event_time_ms": 1000, "is_shot": True, "shot_outcome": "made"},
              {"candidate_id": "b", "event_time_ms": 2000, "is_shot": False, "shot_outcome": None}]
    with pytest.raises(ValueError, match="EXPLICIT_SHOT"):
        align_labels(candidates, labels)
    aligned = align_labels(candidates, labels, allow_non_shots=True)
    rows = [{**aligned[0], "check": {"status": "made"}},
            {**aligned[1], "check": {"status": "made"}}]
    result = metrics(rows, "check")
    assert result["reviewed_candidates"] == 2 and result["n"] == 1
    assert result["binary_accuracy"] == 1
    assert result["non_shot_predictions"] == {"made": 1, "missed": 0, "unknown": 0}
    assert result["automatic_made_precision_all_reviewed"] == 0.5


def test_finite_ball_width_and_weak_net_response_reject_an_edge_passage():
    check = passage(xs=-0.45, acceleration=False, push=1.5)
    assert check["opening_clearance"] < 0
    result = thin_net_video(check)
    assert result["reason"] == "edge_without_net_response"


def test_edge_passage_with_strong_net_response_stays_a_possible_make():
    assert thin_net_video(passage(xs=-0.45, acceleration=False, push=9))["status"] == "made"


def test_mild_acceleration_with_weak_net_response_is_not_accepted():
    check = passage()
    check["passage_speed_ratio"] = 1.1
    assert thin_net_video(check)["reason"] == "net_unresponsive"


def test_new_net_push_after_an_earlier_disturbance_preserves_a_make():
    frames = [[] for _ in range(30)] + [
        [ball(0, y)] for y in [-1.2, -0.9, -0.6, -0.3, 0, 0.4, 0.9, 1.3, 1.8]
    ]
    series = [None] + [3.0] * 28 + [1.0] * 6 + [4.0] * 25
    check = assess_rim_crossing(frames, RIM, series)
    assert check["net_response_ratio"] < 2
    assert check["net_local_response_ratio"] == 3
    assert thin_net_video(check)["status"] == "made"


def test_sustained_motion_without_a_new_net_push_stays_a_miss():
    check = passage(push=4)
    check["net_response_ratio"] = 0.5
    check["net_local_response_ratio"] = 0.5
    assert thin_net_video(check)["reason"] == "net_unresponsive"


def test_recent_net_response_requires_samples_on_both_sides():
    series = [None] + [1.0] * 34 + [4.0] * 30
    assert _local_net_response_ratio(series, 34) == 3
    series[29:32] = [None] * 3
    assert _local_net_response_ratio(series, 34) is None
    assert _local_net_response_ratio([None] + [1.0] * 34 + [4.0] * 4, 34) is None


def test_net_hold_needs_consecutive_strong_detections_after_crossing():
    path = [{"i": 10+i, "x": 0.1, "y": 0.3+i*0.01, "conf": 0.9} for i in range(6)]
    assert _net_hold_frames(path, 10) == 6
    assert _net_hold_frames([{**p, "i": p["i"]*2} for p in path], 20) == 1
    assert _net_hold_frames([{**p, "conf": 0.2} for p in path], 10) == 0
    assert _net_hold_frames(path, 20) == 0


def test_long_front_hold_with_no_new_net_push_rejects_a_carried_ball():
    check = passage(push=9)
    check.update(net_response_ratio=4, net_local_response_ratio=0.2, net_hold_frames=6)
    assert thin_net_video(check)["reason"] == "held_ball_in_front"
    check["net_hold_frames"] = 5
    assert thin_net_video(check)["status"] == "made"


def test_true_net_slowdown_and_central_partial_approach_remain_possible_makes():
    check = passage(push=9)
    check.update(net_hold_frames=7, ball_approached=False)
    assert thin_net_video(check)["status"] == "made"


def test_edge_hold_without_an_approach_is_not_rescued_by_background_motion():
    check = passage(xs=-0.45, push=9)
    check.update(net_hold_frames=4, ball_approached=False)
    assert check["opening_overlap"] < 0.75
    assert thin_net_video(check)["reason"] == "held_ball_in_front"


def test_net_captured_lateral_exit_requires_finite_ball_overlap_and_two_responses():
    check = passage(push=9)
    check.update(status="rejected", reason="exit_off_center", x_exit=1.2,
                 opening_overlap=0.9, track_points=16)
    assert thin_net_video(check)["net_lateral_capture"] is True
    for extra in [{"opening_overlap":0.6}, {"ball_approached":False}, {"net_local_response_ratio":None}]:
        assert thin_net_video({**check, **extra})["status"] == "rejected"




def test_frozen_adapter_relative_imports_use_the_engine_package(tmp_path):
    rim = tmp_path / "src/basketball_highlight/rim_check.py"
    adapter = tmp_path / "engine/python/basketball_engine/adapters/analysis.py"
    rim.parent.mkdir(parents=True)
    adapter.parent.mkdir(parents=True)
    rim.write_text("RIM_CHECK_VERSION = 'rim-dense-v2'\n" +
                   "def assess_rim_crossing(*args): return {'status': 'made'}\n" +
                   "def apply_video_occlusion(value): return value\n" +
                   "def keep_unless_seen(value, refined): return value\n" +
                   "def skipped_result(*args): return {'status': 'skipped'}\n")
    adapter.write_text("from ..diagnostics import log_failed_command\n")
    baseline = load_baseline(tmp_path)
    assert callable(baseline.log_failed_command)
    assert baseline.assess_rim_crossing([]) == {"status": "made"}
