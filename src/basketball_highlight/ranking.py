def candidate_priority(candidate):
    verdict_rank = {"made": 3, "ambiguous": 2, "missed": 1}.get(
        candidate.get("verdict"),
        0,
    )
    gates = candidate.get("gates") if isinstance(candidate.get("gates"), dict) else {}
    source_rank = {
        "local_track": 2,
        "box_center_fallback": 1,
    }.get(candidate.get("rim_source"), 0)
    return (
        verdict_rank,
        candidate.get("complete_crossing") is True,
        gates.get("prediction_review") is not True,
        source_rank,
        float(candidate.get("score", 0.0)),
    )


def dedupe_candidates(candidates, dedupe_seconds):
    ordered = sorted(candidates, key=lambda item: float(item["time"]))
    if not ordered:
        return []
    deduped = []
    cluster_start = float(ordered[0]["time"])
    winner = ordered[0]
    for candidate in ordered[1:]:
        candidate_time = float(candidate["time"])
        if candidate_time - cluster_start <= dedupe_seconds:
            if candidate_priority(candidate) > candidate_priority(winner):
                winner = candidate
            continue
        deduped.append(winner)
        cluster_start = candidate_time
        winner = candidate
    deduped.append(winner)
    return deduped
