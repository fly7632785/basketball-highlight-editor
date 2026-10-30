import copy
from basketball_highlight.candidate_relations import candidate_relations


def candidate(cid, time, source="existing_coarse_fallback", index=0):
    return {"id": cid, "time": time, "event_time_ms": round(time*1000),
            "anchor_source": source, "coarse_index": index}


def test_same_absolute_crossing_is_linked_without_removing_an_anchor():
    cs = [candidate("a", 10), candidate("b", 10.8, index=1)]
    checks = {"a": {"status": "rejected", "cross_frame": 54, "x_cross": -1.2},
              "b": {"status": "rejected", "cross_frame": 30, "x_cross": -1.2}}
    original = copy.deepcopy(cs)
    result = candidate_relations(cs, checks, 30)
    assert result[0]["kind"] == "same_observed_crossing"
    assert result[0]["related_to"] == "a" and result[0]["candidate_id"] == "b"
    assert cs == original and len(cs) == 2


def test_nearby_tip_in_make_is_not_linked_as_duplicate():
    cs = [candidate("a", 10), candidate("b", 11.8, "existing_refined", 1)]
    checks = {"a": {"status": "rejected", "cross_frame": 54, "x_cross": 0},
              "b": {"status": "made", "cross_frame": 28, "x_cross": 0}}
    assert candidate_relations(cs, checks, 30) == []


def test_time_proximity_alone_does_not_establish_a_duplicate():
    cs = [candidate("a", 10), candidate("b", 10.9, index=1)]
    assert candidate_relations(cs, {"a": {"status": "unsure"}, "b": {"status": "rejected"}}, 30) == []


def test_overlapping_coarse_path_is_advice_not_human_truth():
    cs = [candidate("a", 10), candidate("b", 11, index=1)]
    coarse = [{"above": {"time": 9}, "below": {"time": 10.6}},
              {"above": {"time": 10.3}, "below": {"time": 11.7}}]
    checks = {"a": {"status": "unsure"}, "b": {"status": "rejected"}}
    result = candidate_relations(cs, checks, 30, coarse)
    assert result[0]["kind"] == "overlapping_coarse_ball_path"
    assert result[0]["confidence"] == "possible" and result[0]["machine_only"] is True
    assert "human_outcome" not in result[0]


def test_distinct_tip_in_entry_without_a_complete_exit_is_not_linked_as_a_rebound():
    cs = [candidate("a", 10), candidate("b", 10.9, index=1)]
    coarse = [{"above": {"time": 9}, "below": {"time": 10.6}},
              {"above": {"time": 10.3}, "below": {"time": 11.7}}]
    checks = {"a": {"status": "unsure", "cross_frame": 52, "x_cross": 0.55},
              "b": {"status": "unsure", "reason": "no_exit", "cross_frame": 51,
                    "x_cross": 0.085, "entry": True, "ball_approached": True}}
    assert candidate_relations(cs, checks, 30, coarse) == []
