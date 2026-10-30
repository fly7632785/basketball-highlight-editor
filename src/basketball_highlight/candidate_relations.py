"""Review-only relations between candidate anchors; never merge human labels."""
import math
from .rim_check import WINDOW_BEFORE_S


def _time_ms(candidate):
    return int(round(candidate.get("event_time_ms", candidate.get("event_ms", candidate["time"] * 1000))))


def _crossing_ms(candidate, check, fps):
    cross_frame = check.get("cross_frame")
    if cross_frame is None:
        return None
    first_frame = max(0, round((_time_ms(candidate) / 1000 - WINDOW_BEFORE_S) * fps))
    return (first_frame + cross_frame) * 1000 / fps


def candidate_relations(candidates, checks, fps, coarse_candidates=None):
    """Annotate exact repeated crossings and possible rebound continuations.

    Every ID remains in the caller's candidate list. A possible relation is
    review advice, never a not-shot label. Close timestamps alone do not
    establish duplication, and a newly supported make is not suppressed.
    """
    if not math.isfinite(fps) or fps <= 0:
        raise ValueError("CANDIDATE_RELATION_FPS_INVALID")
    relations = []
    ordered = sorted(candidates, key=_time_ms)
    for previous, current in zip(ordered, ordered[1:]):
        a, b = checks[previous["id"]], checks[current["id"]]
        gap = (_time_ms(current) - _time_ms(previous)) / 1000
        if gap <= 0 or gap > 2.5 or b.get("status") == "made":
            continue
        ta, tb = _crossing_ms(previous, a, fps), _crossing_ms(current, b, fps)
        if (
            ta is not None and tb is not None
            and abs(ta - tb) <= 2000 / fps
            and abs(a.get("x_cross", 100) - b.get("x_cross", -100)) <= 0.15
        ):
            relations.append({
                "candidate_id": current["id"], "related_to": previous["id"],
                "kind": "same_observed_crossing", "confidence": "strong",
                "crossing_time_ms": round(tb), "machine_only": True,
            })
            continue
        # A separate supported central entry may be a tip-in even when the
        # short observation window has not yet proved its exit. Preserve it.
        if (b.get("entry") is True and b.get("ball_approached") is True
                and abs(b.get("x_cross", 100)) <= 0.5):
            continue
        if coarse_candidates is None or current.get("anchor_source") != "existing_coarse_fallback":
            continue
        ca = coarse_candidates[previous["coarse_index"]]
        cb = coarse_candidates[current["coarse_index"]]
        start = ca.get("above", {}).get("time")
        end = ca.get("below", {}).get("time")
        new_above = cb.get("above", {}).get("time")
        if None not in (start, end, new_above) and start <= new_above <= end:
            relations.append({
                "candidate_id": current["id"], "related_to": previous["id"],
                "kind": "overlapping_coarse_ball_path", "confidence": "possible",
                "machine_only": True,
            })
    return relations
