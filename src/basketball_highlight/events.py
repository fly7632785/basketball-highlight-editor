from statistics import median

from .features import normalize_geometry
from .geometry import crossing_x_at_y, is_rim_crossing
from .trajectory import prediction_score
from .verdict import resolve_verdict


def _point(record, item):
    return {
        "time": record["time"],
        "x": item["center"][0],
        "y": item["center"][1],
        "confidence": item["confidence"],
        "width": max(1.0, item.get("xyxy", [0, 0, 20, 20])[2] - item.get("xyxy", [0, 0, 20, 20])[0]),
        "height": max(1.0, item.get("xyxy", [0, 0, 20, 20])[3] - item.get("xyxy", [0, 0, 20, 20])[1]),
    }


def _ball_detections(record, min_conf=0.0):
    return [
        _point(record, item)
        for item in record.get("detections", [])
        if item["name"] == "ball" and item["confidence"] >= min_conf
    ]


def _flatten_balls(records, min_conf=0.0):
    balls = []
    for record in records:
        detections = _ball_detections(record, min_conf)
        if detections:
            balls.append(max(detections, key=lambda item: item["confidence"]))
    return balls


def _track_detections(records, min_conf=0.1, max_gap_sec=0.35):
    """Associate detections using motion continuity instead of confidence only.

    This combines the practical nearest-track association used by
    Basketball-Shot-Detection with a short linear prediction. It is deliberately
    lightweight because the input is already restricted to one hoop ROI.
    """
    tracks = []
    for record in sorted(records, key=lambda item: item["time"]):
        detections = _ball_detections(record, min_conf)
        active = []
        for track_index, track in enumerate(tracks):
            gap = record["time"] - track[-1]["time"]
            if gap <= max_gap_sec:
                active.append((track_index, gap))

        pairs = []
        for track_index, gap in active:
            track = tracks[track_index]
            last = track[-1]
            if len(track) >= 2:
                previous = track[-2]
                dt = max(0.001, last["time"] - previous["time"])
                vx = (last["x"] - previous["x"]) / dt
                vy = (last["y"] - previous["y"]) / dt
                predicted = {
                    "x": last["x"] + vx * gap,
                    "y": last["y"] + vy * gap,
                }
            else:
                predicted = last
            for detection_index, detection in enumerate(detections):
                distance = ((detection["x"] - predicted["x"]) ** 2 +
                             (detection["y"] - predicted["y"]) ** 2) ** 0.5
                gate = max(35.0, min(240.0, 900.0 * max(gap, 0.001) +
                                      2.0 * max(last["width"], last["height"])))
                if distance <= gate:
                    pairs.append((distance, track_index, detection_index))

        used_tracks = set()
        used_detections = set()
        for _, track_index, detection_index in sorted(pairs):
            if track_index in used_tracks or detection_index in used_detections:
                continue
            tracks[track_index].append(detections[detection_index])
            used_tracks.add(track_index)
            used_detections.add(detection_index)

        for detection_index, detection in enumerate(detections):
            if detection_index not in used_detections:
                tracks.append([detection])

    return [track for track in tracks if len(track) >= 2]


def _track_forward(records, start, horizon=1.2, min_conf=0.2):
    previous = start
    tracked = [start]
    for record in records:
        if record["time"] <= start["time"] or record["time"] > start["time"] + horizon:
            continue
        detections = _ball_detections(record, min_conf)
        if not detections:
            continue
        candidate = min(
            detections,
            key=lambda point: (point["x"] - previous["x"]) ** 2 +
                              (point["y"] - previous["y"]) ** 2,
        )
        distance = ((candidate["x"] - previous["x"]) ** 2 +
                    (candidate["y"] - previous["y"]) ** 2) ** 0.5
        time_gap = max(0.001, candidate["time"] - previous["time"])
        max_jump = max(35, min(100, 700 * time_gap))
        if distance > max_jump:
            continue
        tracked.append(candidate)
        previous = candidate
    return tracked


def _trajectory_features(balls, above, below, rim_y):
    approach = [
        point for point in balls
        if above["time"] - 0.8 <= point["time"] <= above["time"]
        and point["y"] <= rim_y - 8
    ]
    if not approach:
        approach = [above]
    rise_px = max(0, max(point["y"] for point in approach) - min(point["y"] for point in approach))
    horizontal_span_px = max(point["x"] for point in approach) - min(point["x"] for point in approach)
    descent_speed = (below["y"] - above["y"]) / max(0.001, below["time"] - above["time"])
    arc_score = min(1.0, rise_px / 35.0)
    descent_score = min(1.0, max(0.0, descent_speed) / 120.0)
    direction_steps = [
        current["y"] - previous["y"]
        for previous, current in zip(approach, approach[1:])
    ]
    downward_ratio = (
        sum(delta >= -4.0 for delta in direction_steps) / len(direction_steps)
        if direction_steps else 0.5
    )
    return {
        "approach_rise_px": round(rise_px, 1),
        "approach_horizontal_span_px": round(horizontal_span_px, 1),
        "approach_downward_ratio": round(downward_ratio, 2),
        "trajectory_score": round(0.45 * arc_score + 0.35 * descent_score + 0.20 * downward_ratio, 2),
    }


def _peak_signal(records, field, event_time, start=-0.2, end=0.9):
    values = [
        float(record.get(field, 0.0))
        for record in records
        if event_time + start <= record["time"] <= event_time + end
    ]
    return max(values, default=0.0)


def _delta_signal(records, field, event_time):
    baseline = [
        float(record.get(field, 0.0))
        for record in records
        if event_time - 1.0 <= record["time"] < event_time - 0.2
    ]
    active = [
        float(record.get(field, 0.0))
        for record in records
        if event_time - 0.1 <= record["time"] <= event_time + 0.8
    ]
    if not active:
        return 0.0
    return max(0.0, max(active) - (median(baseline) if baseline else 0.0))


def _multi_signal_features(records, event_time):
    lower = max(
        _delta_signal(records, "net_lower_motion_score", event_time),
        _delta_signal(records, "net_lower_orange_score", event_time),
    )
    below = max(
        _delta_signal(records, "net_below_motion_score", event_time),
        _delta_signal(records, "net_below_orange_score", event_time),
    )
    upper = max(
        _delta_signal(records, "net_upper_motion_score", event_time),
        _delta_signal(records, "net_upper_orange_score", event_time),
    )
    whole = _delta_signal(records, "net_whole_signal_score", event_time)
    if whole == 0.0:
        whole = min(1.0, _delta_signal(records, "net_motion_score", event_time) / 18.0)
    net_score = min(1.0, 0.55 * lower + 0.25 * below + 0.10 * upper + 0.10 * whole)
    return {
        "net_lower": round(lower, 3),
        "net_below": round(below, 3),
        "net_upper": round(upper, 3),
        "net_motion": round(whole, 3),
        "net_score": round(net_score, 3),
    }


def _score_crossing(above, below, later, track, trajectory, signals, horizontal_ratio, rim):
    gap = max(0.001, below["time"] - above["time"])
    descent_speed = max(0.0, (below["y"] - above["y"]) / gap)
    persistence = min(1.0, len([point for point in later if point["y"] >= rim["rim_y"] + 10]) / 3.0)
    confidence = median(point["confidence"] for point in track[-min(6, len(track)):])
    geometry = (
        0.30 * min(1.0, descent_speed / 120.0) +
        0.45 * persistence +
        0.25 * min(1.0, 0.8 / gap)
    )
    track_quality = 0.65 * min(1.0, confidence / 0.75) + 0.35 * min(1.0, len(track) / 6.0)
    crossing_quality = max(0.0, 1.0 - min(1.0, horizontal_ratio / 0.9))
    speed_penalty = max(0.0, descent_speed - 240.0) / 240.0
    penalty = max(0.0, horizontal_ratio - 0.55) * 0.25 + min(0.25, speed_penalty * 0.22)
    score = (
        0.38 * geometry +
        0.22 * trajectory["trajectory_score"] +
        0.10 * signals["net_score"] +
        0.20 * track_quality +
        0.10 * crossing_quality -
        penalty
    )
    return round(max(0.0, min(1.0, score)), 3)


def calibrated_gates(candidate):
    """Empirical precision/recall gates calibrated from the user's 59 labels.

    The strict gate is used for automatic export; the broader gate keeps
    ambiguous events in the human-review queue. These thresholds are versioned
    behavior, not universal basketball physics, and should be recalibrated when
    more venues/cameras are labeled.
    """
    speed = float(candidate.get("speed_px_s", 0.0))
    span = float(candidate.get("approach_horizontal_span_px", 0.0))
    horizontal_ratio = float(candidate.get("horizontal_ratio", 1.0))
    net_motion = float(candidate.get("net_motion_score", 0.0))
    net_score = float(candidate.get("net_score", candidate.get("signals", {}).get("net_score", 0.0)))
    net_changed_ratio = float(candidate.get("net_changed_ratio", 0.0))
    high_speed_net = (
        150.0 <= speed <= 260.0 and
        horizontal_ratio >= 0.50 and
        net_motion >= 0.90
    )
    high_speed_drop = (
        150.0 <= speed <= 220.0 and
        span <= 130.0 and
        net_motion <= 0.40 and
        horizontal_ratio >= 0.55
    )
    strict_low_speed = speed <= 95.0 and span <= 100.0
    review_low_speed = speed <= 95.0 and span <= 192.0
    review_gate = review_low_speed or high_speed_net or high_speed_drop
    recall_review = (
        review_gate or
        net_score >= 0.45 or
        (speed <= 110.0 and span <= 190.0) or
        (speed <= 260.0 and span <= 45.0 and horizontal_ratio <= 0.20)
    )
    automatic_goal = speed <= 102.0 or net_changed_ratio >= 0.129
    return {
        "high_precision": strict_low_speed or high_speed_net or high_speed_drop,
        "automatic_goal": automatic_goal,
        "review": review_gate,
        "recall_review": recall_review,
        "strict_low_speed": strict_low_speed,
        "high_speed_net": high_speed_net,
        "high_speed_drop": high_speed_drop,
    }


def normalized_calibrated_gates(candidate, reference_rim_width=30.54):
    """Apply the existing empirical gates in rim-relative coordinates.

    This is an evaluation path only. It preserves the current default gate
    while allowing a threshold calibrated at one apparent rim size to be
    replayed at another camera distance.
    """
    rim_width = max(1.0, float(candidate.get("rim_width_px", 1.0)))
    speed_per_rim = candidate.get("speed_per_rim")
    if speed_per_rim is None:
        speed_per_rim = float(candidate.get("speed_px_s", 0.0)) / rim_width
    span_per_rim = candidate.get("approach_span_per_rim")
    if span_per_rim is None:
        span_per_rim = float(candidate.get("approach_horizontal_span_px", 0.0)) / rim_width
    normalized = dict(candidate)
    normalized["speed_px_s"] = float(speed_per_rim) * reference_rim_width
    normalized["approach_horizontal_span_px"] = float(span_per_rim) * reference_rim_width
    return calibrated_gates(normalized)


def _confidence_label(score, signals=None, gates=None):
    if gates and gates["high_precision"] and score >= 0.55:
        return "high"
    if gates and gates["review"] and score >= 0.42:
        return "review"
    if score >= 0.48 and (signals is None or signals.get("net_score", 0.0) >= 0.1):
        return "review"
    return "low"


def _net_motion_features(records, event_time):
    values = [
        (record["time"], record.get("net_motion_score", 0.0), record.get("net_changed_ratio", 0.0))
        for record in records
    ]
    if not values:
        return {
            "net_motion_peak": 0.0,
            "net_motion_delta": 0.0,
            "net_changed_ratio": 0.0,
            "net_motion_score": 0.0,
        }
    baseline_values = [score for time, score, _ in values if event_time - 0.5 <= time < event_time - 0.1]
    active_values = [
        (score, ratio) for time, score, ratio in values
        if event_time - 0.05 <= time <= event_time + 0.8
    ]
    baseline = median(baseline_values) if baseline_values else median(score for _, score, _ in values)
    peak = max((score for score, _ in active_values), default=baseline)
    ratio = max((ratio for _, ratio in active_values), default=0.0)
    delta = max(0.0, peak - baseline)
    motion_score = min(1.0, max(delta / 12.0, ratio / 0.35))
    return {
        "net_motion_peak": round(peak, 2),
        "net_motion_delta": round(delta, 2),
        "net_changed_ratio": round(ratio, 3),
        "net_motion_score": round(motion_score, 2),
    }


def find_candidate_crossings(records, rim, max_gap_sec=2.5, margin=16, dedupe_sec=2.0, min_descent_px=20):
    balls = _flatten_balls(records)
    rim_y = rim["rim_y"]
    rim_left = rim["center_x"] - rim["width"] / 2
    rim_right = rim["center_x"] + rim["width"] / 2
    candidates = []

    for index, above in enumerate(balls):
        if above["y"] > rim_y - 8:
            continue
        for below in balls[index + 1:]:
            gap = below["time"] - above["time"]
            if gap <= 0:
                continue
            if gap > max_gap_sec:
                break
            if below["y"] < rim_y + 10:
                continue
            if below["y"] - above["y"] < min_descent_px:
                continue
            x_cross = crossing_x_at_y(above, below, rim_y)
            if x_cross is None or not is_rim_crossing(x_cross, rim_left, rim_right, margin):
                continue
            candidate = {
                "time": round((above["time"] + below["time"]) / 2, 2),
                "x_cross": round(x_cross),
                "above": above,
                "below": below,
            }
            if not candidates or candidate["time"] - candidates[-1]["time"] > dedupe_sec:
                candidates.append(candidate)
            break
    return candidates


def find_refined_crossings(records, rim, max_cross_gap_sec=1.8, dedupe_sec=2.0):
    """Find and score rim crossings using geometry, tracking and net zones.

    The result intentionally keeps ambiguous crossings as ``low`` or
    ``review`` candidates. The caller can set the product's recall/precision
    trade-off without throwing away evidence from the detector.
    """
    tracks = _track_detections(records, min_conf=0.1)
    legacy_track = _flatten_balls(records, min_conf=0.2)
    if len(legacy_track) >= 2:
        tracks.append(legacy_track)
    rim_y = rim["rim_y"]
    rim_half_w = max(1.0, rim["width"] / 2.0)
    above_y = rim_y - max(12.0, rim.get("height", 20) * 0.45)
    below_y = rim_y + max(18.0, rim.get("height", 20) * 0.55)
    rim_left = rim["center_x"] - rim_half_w
    rim_right = rim["center_x"] + rim_half_w
    gate_margin = max(8.0, rim_half_w * 0.55)
    candidates = []

    for track in tracks:
        prediction = prediction_score(track, rim)
        for index, above in enumerate(track):
            if above["y"] > above_y:
                continue
            for below in track[index + 1:]:
                gap = below["time"] - above["time"]
                if gap <= 0:
                    continue
                if gap > max_cross_gap_sec:
                    break
                if below["y"] < below_y or below["y"] <= above["y"]:
                    continue
                x_cross = crossing_x_at_y(above, below, rim_y)
                if x_cross is None or not is_rim_crossing(x_cross, rim_left, rim_right, gate_margin):
                    continue

                later = [
                    point for point in track
                    if below["time"] <= point["time"] <= below["time"] + 0.8
                ]
                below_points = [point for point in later if point["y"] >= rim_y + 10]
                fast_single_below = (
                    len(below_points) == 1 and
                    below["confidence"] >= 0.5 and
                    (below["y"] - above["y"]) / gap >= 100
                )
                if len(below_points) < 2 and not fast_single_below:
                    break

                previous_y = below["y"]
                rebounded = False
                for point in later:
                    if point["time"] <= below["time"]:
                        continue
                    if point["y"] < previous_y - max(8.0, rim.get("height", 20) * 0.18):
                        rebounded = True
                        break
                    previous_y = point["y"]
                if rebounded:
                    break

                lateral_exit = any(
                    abs(point["x"] - rim["center_x"]) > max(3.0 * rim_half_w, 45.0)
                    and point["y"] < rim_y + 80
                    for point in later
                )
                if lateral_exit:
                    break

                event_time = (above["time"] + below["time"]) / 2
                trajectory = _trajectory_features(track, above, below, rim_y)
                signals = _multi_signal_features(records, event_time)
                horizontal_ratio = abs(below["x"] - above["x"]) / max(1.0, below["y"] - above["y"])
                if horizontal_ratio > 0.95:
                    break
                descent_speed = (below["y"] - above["y"]) / max(0.001, gap)
                if descent_speed > 320.0:
                    break
                score = _score_crossing(
                    above, below, later, track, trajectory, signals, horizontal_ratio, rim,
                )
                net_features = _net_motion_features(records, event_time)
                normalized_geometry = normalize_geometry({
                    "speed_px_s": descent_speed,
                    "approach_horizontal_span_px": trajectory["approach_horizontal_span_px"],
                    "x_cross": x_cross,
                }, {
                    "center_x": rim["center_x"],
                    "width": rim_half_w * 2.0,
                    "height": rim.get("height", 20),
                })
                gates = calibrated_gates({
                    "speed_px_s": descent_speed,
                    "approach_horizontal_span_px": trajectory["approach_horizontal_span_px"],
                    "horizontal_ratio": horizontal_ratio,
                    "net_motion_score": net_features["net_motion_score"],
                    "net_changed_ratio": net_features["net_changed_ratio"],
                    "net_score": signals["net_score"],
                })
                prediction_review = bool(
                    prediction and
                    prediction["landing_center"] >= 0.5 and
                    prediction["predict_score"] >= 0.8
                )
                gates["prediction_review"] = prediction_review
                if prediction_review:
                    gates["recall_review"] = True
                candidate = {
                    "time": round(event_time, 2),
                    "x_cross": round(x_cross),
                    "speed_px_s": round((below["y"] - above["y"]) / gap, 1),
                    "horizontal_ratio": round(horizontal_ratio, 2),
                    **trajectory,
                    **net_features,
                    **normalized_geometry,
                    "signals": signals,
                    "prediction": prediction,
                    "score": score,
                    "gates": gates,
                    "confidence": _confidence_label(score, signals, gates),
                    "above": above,
                    "below": below,
                }
                verdict = resolve_verdict(candidate, track, rim)
                candidate["verdict"] = verdict["verdict"]
                candidate["decision_time"] = verdict["decision_time"]
                candidate["verification"] = verdict
                # Only a made verdict may feed an automatic-export gate. The
                # review queue still keeps ambiguous candidates for a person.
                if verdict["verdict"] != "made":
                    candidate["gates"]["automatic_goal"] = False
                candidates.append(candidate)
                break

    candidates.sort(key=lambda item: item["time"])
    deduped = []
    for candidate in candidates:
        if not deduped or candidate["time"] - deduped[-1]["time"] > dedupe_sec:
            deduped.append(candidate)
        elif candidate["score"] > deduped[-1]["score"]:
            deduped[-1] = candidate
    return deduped
