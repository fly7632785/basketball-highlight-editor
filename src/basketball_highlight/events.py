from statistics import median

from .features import normalize_geometry
from .geometry import crossing_x_at_y, is_rim_crossing
from .ranking import dedupe_candidates
from .trajectory import prediction_score
from .verdict import resolve_verdict


ANALYSIS_CONTRACT_VERSION = "analysis-contract-v1"


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
    for record in sorted(records, key=lambda item: float(item["time"])):
        detections = _ball_detections(record, min_conf)
        if detections:
            balls.append(max(detections, key=lambda item: item["confidence"]))
    return balls


def _continuous_flatten_balls(
    records,
    min_conf=0.0,
    max_gap_sec=0.5,
    rim_width=30.54,
):
    balls = _flatten_balls(records, min_conf)
    for previous, candidate in zip(balls, balls[1:]):
        gap = candidate["time"] - previous["time"]
        distance = (
            (candidate["x"] - previous["x"]) ** 2
            + (candidate["y"] - previous["y"]) ** 2
        ) ** 0.5
        gate = max(
            1.75 * rim_width,
            min(
                12.0 * rim_width,
                45.0 * rim_width * max(gap, 0.001)
                + 2.0 * max(previous["width"], previous["height"]),
            ),
        )
        if gap <= 0 or gap > max_gap_sec or distance > gate:
            return []
    return balls


def _track_detections(
    records,
    min_conf=0.1,
    max_gap_sec=0.35,
    rim_width=30.54,
):
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
                gate = max(
                    1.75 * rim_width,
                    min(
                        12.0 * rim_width,
                        45.0 * rim_width * max(gap, 0.001)
                        + 2.0 * max(last["width"], last["height"]),
                    ),
                )
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


def _trajectory_features(balls, above, below, rim):
    rim_y = float(rim["rim_y"])
    rim_width = max(1.0, float(rim["width"]))
    approach = [
        point for point in balls
        if above["time"] - 0.8 <= point["time"] <= above["time"]
        and point["y"] <= rim_y - 0.25 * rim_width
    ]
    if not approach:
        approach = [above]
    rise_px = max(0, max(point["y"] for point in approach) - min(point["y"] for point in approach))
    horizontal_span_px = max(point["x"] for point in approach) - min(point["x"] for point in approach)
    descent_speed = (below["y"] - above["y"]) / max(0.001, below["time"] - above["time"])
    arc_score = min(1.0, rise_px / (1.15 * rim_width))
    descent_score = min(1.0, max(0.0, descent_speed) / (4.0 * rim_width))
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
    records = _valid_net_records(records)
    lower = max(
        _delta_signal(records, "net_lower_motion_score", event_time),
        _delta_signal(records, "net_lower_orange_score", event_time),
        _delta_signal(records, "net_lower_white_motion_score", event_time),
        _delta_signal(records, "net_lower_downward_motion_score", event_time),
    )
    below = max(
        _delta_signal(records, "net_below_motion_score", event_time),
        _delta_signal(records, "net_below_orange_score", event_time),
        _delta_signal(records, "net_below_white_motion_score", event_time),
        _delta_signal(records, "net_below_downward_motion_score", event_time),
    )
    upper = max(
        _delta_signal(records, "net_upper_motion_score", event_time),
        _delta_signal(records, "net_upper_orange_score", event_time),
        _delta_signal(records, "net_upper_white_motion_score", event_time),
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


def _zone_signal_value(record, zone):
    return max(
        float(record.get(f"net_{zone}_motion_score", 0.0)),
        float(record.get(f"net_{zone}_orange_score", 0.0)),
        float(record.get(f"net_{zone}_white_motion_score", 0.0)),
        float(record.get(f"net_{zone}_downward_motion_score", 0.0)),
        min(1.0, float(record.get(f"net_{zone}_changed_ratio", 0.0)) / 0.12),
    )


def _net_inside_motion_features(records, event_time):
    """Measure motion inside the net and its downward activation order.

    A global frame-difference peak also reacts to players, the backboard and
    camera noise.  A made basket should instead produce activity in the net's
    lower zone followed by activity in the zone below it.
    """
    active = [
        record for record in records
        if event_time - 0.10 <= record["time"] <= event_time + 0.80
        and record.get("net_measurement_valid") is True
    ]
    baseline = [
        record for record in records
        if event_time - 0.80 <= record["time"] < event_time - 0.10
        and record.get("net_measurement_valid") is True
    ]
    signal_available = len(active) >= 2 and len(baseline) >= 1
    baseline_by_zone = {}
    for zone in ("upper", "lower", "below"):
        values = [_zone_signal_value(record, zone) for record in baseline]
        baseline_by_zone[zone] = median(values) if values else 0.0

    def activated_value(record, zone):
        return max(0.0, _zone_signal_value(record, zone) - baseline_by_zone[zone])

    threshold = 0.25
    lower_peak = max((activated_value(record, "lower") for record in active), default=0.0)
    below_peak = max((activated_value(record, "below") for record in active), default=0.0)
    lower_hits = [
        record["time"] for record in active
        if activated_value(record, "lower") >= threshold
    ]
    below_hits = [
        record["time"] for record in active
        if activated_value(record, "below") >= threshold
    ]
    if lower_hits and below_hits:
        first_lower = min(lower_hits)
        first_below = min(below_hits)
        sequence_gap = first_below - first_lower
        if sequence_gap >= 0.05:
            sequence = 1.0
            order = "lower_to_below"
        elif sequence_gap >= 0.0:
            sequence = 0.8 if lower_peak >= 0.4 and below_peak >= 0.4 else 0.45
            order = "same_frame"
        else:
            sequence = 0.15
            order = "below_to_lower"
    elif lower_hits:
        sequence_gap = None
        sequence = 0.45
        order = "lower_only"
    elif below_hits:
        sequence_gap = None
        sequence = 0.15
        order = "below_only"
    else:
        sequence_gap = None
        sequence = 0.0
        order = "none"
    active_count = sum(
        activated_value(record, "lower") >= threshold or
        activated_value(record, "below") >= threshold
        for record in active
    )
    persistence = min(1.0, active_count / 3.0)
    inside_score = min(
        1.0,
        0.55 * lower_peak + 0.25 * below_peak + 0.12 * sequence + 0.08 * persistence,
    )
    no_motion = bool(
        signal_available
        and baseline_by_zone["lower"] < 0.35
        and baseline_by_zone["below"] < 0.35
        and lower_peak < 0.12
        and below_peak < 0.12
        and inside_score < 0.12
    )
    return {
        "net_signal_available": signal_available,
        "net_no_motion": no_motion,
        "net_inside_motion_score": round(inside_score, 3),
        "net_sequence_score": round(sequence, 3),
        "net_motion_order": order,
        "net_sequence_gap_s": None if sequence_gap is None else round(sequence_gap, 3),
        "net_lower_peak": round(lower_peak, 3),
        "net_below_peak": round(below_peak, 3),
        "net_lower_baseline": round(baseline_by_zone["lower"], 3),
        "net_below_baseline": round(baseline_by_zone["below"], 3),
        "net_baseline_quiet": bool(
            baseline_by_zone["lower"] < 0.35
            and baseline_by_zone["below"] < 0.35
        ),
    }


def _point_in_rim_corridor(point, rim, tolerance_ratio=0.15):
    half_width = max(1.0, float(rim["width"]) / 2.0)
    ball_half_width = max(2.0, float(point.get("width", 4.0)) / 2.0)
    tolerance = min(half_width * tolerance_ratio, ball_half_width)
    left = float(rim["center_x"]) - half_width - tolerance
    right = float(rim["center_x"]) + half_width + tolerance
    return left <= float(point["x"]) <= right


def _continuous_post_points(track, below, rim, horizon=0.8):
    """Stop a track at the first implausible post-crossing jump.

    Greedy association can switch to another visible ball after the real ball
    enters the net.  Treating that switch as a rebound or lateral exit both
    rejects real makes and pollutes the overlay trajectory.
    """
    rim_width = max(1.0, float(rim["width"]))
    points = [below]
    previous = below
    for point in sorted(track, key=lambda item: item["time"]):
        if point["time"] <= below["time"]:
            continue
        if point["time"] > below["time"] + horizon:
            break
        gap = point["time"] - previous["time"]
        if gap <= 0:
            continue
        if (
            previous["y"] - point["y"] > max(2.0, float(rim.get("height", 20.0)) * 0.30)
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
                + 2.0 * max(previous["width"], point["width"],
                             previous["height"], point["height"]),
            ),
        )
        if distance > gate:
            break
        points.append(point)
        previous = point
    return points


def _post_corridor_points(records, below, rim, horizon=0.8):
    """Follow the first post-crossing detections inside a broad rim corridor.

    Recovery is only used when the main tracker switched to another ball. It
    must not inspect every ball in the window: a nearby player's ball can look
    like a lateral exit and make us discard a real crossing.
    """
    rim_width = max(1.0, float(rim["width"]))
    points = [below]
    previous = below
    for record in sorted(records, key=lambda item: item["time"]):
        if record["time"] <= below["time"]:
            continue
        if record["time"] > below["time"] + horizon:
            break
        detections = _ball_detections(record, min_conf=0.1)
        if not detections:
            if record["time"] - previous["time"] <= 0.25:
                continue
            break
        gap = record["time"] - previous["time"]
        if len(points) >= 2:
            prior = points[-2]
            dt = max(0.001, previous["time"] - prior["time"])
            velocity = {
                "x": (previous["x"] - prior["x"]) / dt,
                "y": (previous["y"] - prior["y"]) / dt,
            }
            predicted = {
                "x": previous["x"] + velocity["x"] * gap,
                "y": previous["y"] + velocity["y"] * gap,
            }
        else:
            predicted = previous
        gate = max(
            1.75 * rim_width,
            min(
                12.0 * rim_width,
                45.0 * rim_width * max(gap, 0.001)
                + 2.0 * max(previous["width"], previous["height"]),
            ),
        )
        viable = [
            point for point in detections
            if _point_in_rim_corridor(point, rim, tolerance_ratio=0.35)
            and ((point["x"] - predicted["x"]) ** 2
                 + (point["y"] - predicted["y"]) ** 2) ** 0.5 <= gate
        ]
        if not viable:
            break
        previous = min(
            viable,
            key=lambda point: (
                (point["x"] - predicted["x"]) ** 2
                + (point["y"] - predicted["y"]) ** 2,
                -point["confidence"],
            ),
        )
        points.append(previous)
    return points


def _recovery_tracks(records, tracks, rim, max_cross_gap_sec):
    points = sorted(
        [
            point
            for record in records
            for point in _ball_detections(record, min_conf=0.1)
        ],
        key=lambda item: item["time"],
    )
    if not points:
        return []
    rim_y = float(rim["rim_y"])
    rim_width = max(1.0, float(rim["width"]))
    rim_height = max(1.0, float(rim.get("height", 20.0)))
    above_y = rim_y - 0.6 * rim_height
    below_y = rim_y + 0.9 * rim_height
    below_depth = max(rim_width * 0.35, rim_height * 0.5)
    rim_left = float(rim["center_x"]) - rim_width / 2.0
    rim_right = float(rim["center_x"]) + rim_width / 2.0
    recovery = []

    for track in tracks:
        for above in track:
            if above["y"] > above_y:
                continue
            candidates = []
            for below in points:
                gap = below["time"] - above["time"]
                if gap <= 0 or gap > max_cross_gap_sec:
                    continue
                if below["y"] < below_y or not _point_in_rim_corridor(
                    below, rim, tolerance_ratio=0.25,
                ):
                    continue
                if any(
                    abs(point["time"] - below["time"]) < 0.0001
                    and abs(point["x"] - below["x"]) < 0.1
                    and abs(point["y"] - below["y"]) < 0.1
                    for point in track
                    if point["time"] > above["time"]
                ):
                    continue
                x_cross = crossing_x_at_y(above, below, rim_y)
                if x_cross is None or not is_rim_crossing(
                    x_cross, rim_left, rim_right, rim_width * 0.1,
                ):
                    continue
                post = [
                    point for point in _post_corridor_points(records, below, rim)
                    if point["y"] >= rim_y + below_depth
                ]
                if len(post) < 2:
                    continue
                candidates.append((
                    abs(x_cross - float(rim["center_x"])),
                    -len(post),
                    gap,
                    below,
                    post,
                ))
            if not candidates:
                continue
            _, _, _, below, post = min(candidates, key=lambda item: item[:3])
            transition = [
                point for point in points
                if above["time"] <= point["time"] <= below["time"]
                and rim_y - 1.5 * rim_height <= point["y"] <= rim_y + 0.5 * rim_height
                and _point_in_rim_corridor(point, rim, tolerance_ratio=0.25)
            ]
            stitched = [
                point for point in track if point["time"] <= above["time"]
            ] + transition + post
            unique = []
            seen = set()
            for point in sorted(stitched, key=lambda item: item["time"]):
                key = (round(point["time"], 4), round(point["x"], 1), round(point["y"], 1))
                if key not in seen:
                    seen.add(key)
                    unique.append(point)
            if len(unique) >= 3:
                recovery.append(unique)
                break
    return recovery


def _complete_rim_crossing(track, above, below, rim):
    rim_y = float(rim["rim_y"])
    rim_height = max(8.0, float(rim.get("height", 20.0)))
    near_above = [
        point for point in track
        if point["time"] <= above["time"]
        and rim_y - 1.8 * rim_height <= point["y"] <= rim_y
    ]
    later = _continuous_post_points(track, below, rim)
    post_rim = [
        point for point in later
        if point["y"] >= rim_y + max(float(rim["width"]) * 0.35, rim_height * 0.5)
    ]
    post_inside = [
        point for point in post_rim
        if _point_in_rim_corridor(point, rim, tolerance_ratio=0.35)
    ]
    transition_points = [
        point for point in track
        if above["time"] <= point["time"] <= below["time"]
        and rim_y - 1.5 * rim_height <= point["y"] <= rim_y + 0.5 * rim_height
    ]
    x_cross = crossing_x_at_y(above, below, rim_y)
    half_width = max(1.0, float(rim["width"]) / 2.0)
    crossing_inside = (
        x_cross is not None
        and float(rim["center_x"]) - half_width <= x_cross <=
        float(rim["center_x"]) + half_width
    )
    transition_inside = sum(
        _point_in_rim_corridor(point, rim) for point in transition_points
    )
    post_sample = post_rim[:3]
    # 穿网后的球会自然向外甩摆,越往下允许偏离筐口越宽(漏斗形),
    # 否则把"穿网后甩出"误判为"未从筐口穿过"。
    post_depth_line = rim_y + max(float(rim["width"]) * 0.35, rim_height * 0.5)
    post_center_x = float(rim["center_x"])
    post_half = max(1.0, float(rim["width"]) / 2.0)
    post_width = max(1.0, float(rim["width"]))

    def _post_in_funnel(point):
        fall = max(0.0, point["y"] - post_depth_line)
        allow = post_width * 0.35 + fall * 0.35
        return abs(point["x"] - post_center_x) <= post_half + allow

    post_inside_count = sum(
        1 for point in post_sample if _post_in_funnel(point)
    )
    complete = bool(
        crossing_inside
        # 完整穿框必须有真实检测点证明球接近并经过筐口带。
        # 仅凭 above->below 插值会把从侧边掠过、恰好在 rim_y 处
        # 插值到框内的轨迹误标为 complete_crossing。
        and near_above
        and transition_points
        and transition_inside / len(transition_points) >= 0.60
        and len(post_rim) >= 2
        and post_inside_count >= 2
    )
    return {
        "complete_crossing": complete,
        "post_rim_points": len(post_rim),
        "post_rim_corridor_points": len(post_inside),
        "transition_points": len(transition_points),
        "transition_corridor_points": (
            sum(_point_in_rim_corridor(point, rim) for point in transition_points)
        ),
        "crossing_inside_rim": crossing_inside,
    }


def _score_crossing(above, below, later, track, trajectory, signals, horizontal_ratio, rim):
    gap = max(0.001, below["time"] - above["time"])
    descent_speed = max(0.0, (below["y"] - above["y"]) / gap)
    rim_width = max(1.0, float(rim["width"]))
    normalized_speed = descent_speed / rim_width * 30.54
    below_depth = max(rim_width * 0.35, float(rim.get("height", 20)) * 0.5)
    persistence = min(1.0, len([point for point in later if point["y"] >= rim["rim_y"] + below_depth]) / 3.0)
    confidence = median(point["confidence"] for point in track[-min(6, len(track)):])
    geometry = (
        0.30 * min(1.0, normalized_speed / 120.0) +
        0.45 * persistence +
        0.25 * min(1.0, 0.8 / gap)
    )
    track_quality = 0.65 * min(1.0, confidence / 0.75) + 0.35 * min(1.0, len(track) / 6.0)
    crossing_quality = max(0.0, 1.0 - min(1.0, horizontal_ratio / 0.9))
    net_quality = 0.5 * signals["net_score"] + 0.5 * signals.get(
        "net_inside_motion_score", signals["net_score"],
    )
    speed_penalty = max(0.0, normalized_speed - 240.0) / 240.0
    penalty = max(0.0, horizontal_ratio - 0.55) * 0.25 + min(0.25, speed_penalty * 0.22)
    score = (
        0.38 * geometry +
        0.22 * trajectory["trajectory_score"] +
        0.10 * net_quality +
        0.20 * track_quality +
        0.10 * crossing_quality -
        penalty
    )
    return round(max(0.0, min(1.0, score)), 3)


def calibrated_gates(candidate, reference_rim_width=30.54):
    """Empirical gates expressed in a camera-size-independent coordinate.

    The strict gate is used for automatic export; the broader gate keeps
    ambiguous events in the human-review queue. These thresholds are versioned
    behavior, not universal basketball physics, and should be recalibrated when
    more venues/cameras are labeled. When normalized rim-relative features are
    present, they are projected to the historical reference rim size before
    applying the same thresholds. Legacy callers with pixel-only features keep
    the old behavior.
    """
    speed = float(candidate.get("speed_px_s", 0.0))
    span = float(candidate.get("approach_horizontal_span_px", 0.0))
    if candidate.get("speed_per_rim") is not None:
        speed = float(candidate["speed_per_rim"]) * float(reference_rim_width)
    if candidate.get("approach_span_per_rim") is not None:
        span = float(candidate["approach_span_per_rim"]) * float(reference_rim_width)
    horizontal_ratio = float(candidate.get("horizontal_ratio", 1.0))
    net_motion = float(candidate.get("net_motion_score", 0.0))
    net_score = float(candidate.get("net_score", candidate.get("signals", {}).get("net_score", 0.0)))
    net_changed_ratio = float(candidate.get("net_changed_ratio", 0.0))
    signals = candidate.get("signals") if isinstance(candidate.get("signals"), dict) else {}
    net_inside = float(candidate.get(
        "net_inside_motion_score",
        signals.get("net_inside_motion_score", 0.0),
    ))
    net_sequence = float(candidate.get(
        "net_sequence_score",
        signals.get("net_sequence_score", 0.0),
    ))
    net_below_peak = float(candidate.get(
        "net_below_peak",
        signals.get("net_below_peak", 0.0),
    ))
    explicit_net_availability = candidate.get(
        "net_signal_available",
        signals.get("net_signal_available"),
    )
    net_evidence_present = (
        bool(explicit_net_availability)
        if explicit_net_availability is not None
        else (
            "net_inside_motion_score" in candidate or
            "net_inside_motion_score" in signals
        )
    )
    net_support = (
        net_inside >= 0.35
        and net_sequence >= 0.80
        and net_below_peak >= 0.25
    )
    net_no_motion = bool(candidate.get(
        "net_no_motion",
        signals.get("net_no_motion", False),
    ))
    complete_crossing = candidate.get("complete_crossing", True) is True
    high_speed_net = (
        150.0 <= speed <= 260.0 and
        horizontal_ratio >= 0.50 and
        (net_support if net_evidence_present else net_motion >= 0.90)
    )
    high_speed_drop = (
        150.0 <= speed <= 220.0 and
        span <= 130.0 and
        (not net_evidence_present or net_support) and
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
    automatic_goal = (
        complete_crossing
        and not net_no_motion
        and (
            speed <= 102.0
            or strict_low_speed
            or high_speed_net
            or high_speed_drop
            or (not net_evidence_present and net_changed_ratio >= 0.129)
        )
    )
    return {
        "high_precision": (
            complete_crossing and
            (strict_low_speed or high_speed_net or high_speed_drop) and
            not net_no_motion
        ),
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
    normalized.pop("speed_per_rim", None)
    normalized.pop("approach_span_per_rim", None)
    return calibrated_gates(normalized, reference_rim_width=reference_rim_width)


def _confidence_label(score, signals=None, gates=None):
    if gates and gates["high_precision"] and score >= 0.55:
        return "high"
    if gates and gates["review"] and score >= 0.42:
        return "review"
    if score >= 0.48 and (signals is None or signals.get("net_score", 0.0) >= 0.1):
        return "review"
    return "low"


def _net_motion_features(records, event_time):
    records = _valid_net_records(records)
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


def _valid_net_records(records):
    if not any("net_measurement_valid" in record for record in records):
        return records
    return [
        record
        for record in records
        if record.get("net_measurement_valid") is True
    ]


def find_candidate_crossings(records, rim, max_gap_sec=2.5, margin=16, dedupe_sec=0.8, min_descent_px=20):
    balls = _flatten_balls(records)
    rim_y = rim["rim_y"]
    rim_width = max(1.0, float(rim["width"]))
    rim_left = rim["center_x"] - rim_width / 2
    rim_right = rim["center_x"] + rim_width / 2
    pixel_scale = rim_width / 50.0
    above_clearance = max(3.0, 8.0 * pixel_scale)
    below_clearance = max(4.0, 10.0 * pixel_scale)
    crossing_margin = max(4.0, float(margin) * pixel_scale)
    minimum_descent = max(8.0, float(min_descent_px) * pixel_scale)
    candidates = []

    for index, above in enumerate(balls):
        if above["y"] > rim_y - above_clearance:
            continue
        for below in balls[index + 1:]:
            gap = below["time"] - above["time"]
            if gap <= 0:
                continue
            if gap > max_gap_sec:
                break
            if below["y"] < rim_y + below_clearance:
                continue
            if below["y"] - above["y"] < minimum_descent:
                continue
            x_cross = crossing_x_at_y(above, below, rim_y)
            if x_cross is None or not is_rim_crossing(
                x_cross,
                rim_left,
                rim_right,
                crossing_margin,
            ):
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


def _crossing_time_at_y(above, below, rim_y):
    denominator = below["y"] - above["y"]
    if denominator == 0:
        return round((above["time"] + below["time"]) / 2.0, 4)
    ratio = (rim_y - above["y"]) / denominator
    return round(above["time"] + ratio * (below["time"] - above["time"]), 4)


def _overlay_data(
    track,
    rim,
    above,
    below,
    x_cross,
    event_time,
    prediction,
    crossing_valid=False,
):
    points = [
        point
        for point in track
        if event_time - 1.2 <= point["time"] <= event_time + 0.8
    ]
    if len(points) > 24:
        step = max(1, len(points) // 24)
        points = points[::step][:24]

    return {
        "rim": {
            "center_x": round(float(rim["center_x"]), 3),
            "rim_y": round(float(rim["rim_y"]), 3),
            "width": round(float(rim["width"]), 3),
            "height": round(float(rim.get("height", 20.0)), 3),
        },
        "trajectory": [
            {
                "time": round(float(point["time"]), 4),
                "x": round(float(point["x"]), 3),
                "y": round(float(point["y"]), 3),
                "confidence": round(float(point.get("confidence", 0.0)), 4),
            }
            for point in points
        ],
        "crossing": {
            "time": _crossing_time_at_y(above, below, rim["rim_y"]),
            "x": round(float(x_cross), 3),
            "y": round(float(rim["rim_y"]), 3),
            "valid": crossing_valid,
        },
        "prediction": None if not prediction else {
            "landing_x": round(float(prediction["predict_x"]), 3),
            "landing_y": round(float(rim["rim_y"]), 3),
            "fit_r2": prediction.get("fit_r2"),
            "predict_score": prediction.get("predict_score"),
        },
    }


def find_refined_crossings(records, rim, max_cross_gap_sec=1.8, dedupe_sec=2.0):
    """Find and score rim crossings using geometry, tracking and net zones.

    The result intentionally keeps ambiguous crossings as ``low`` or
    ``review`` candidates. The caller can set the product's recall/precision
    trade-off without throwing away evidence from the detector.
    """
    rim_width = max(1.0, float(rim["width"]))
    tracks = _track_detections(records, min_conf=0.1, rim_width=rim_width)
    legacy_track = _continuous_flatten_balls(
        records,
        min_conf=0.2,
        rim_width=rim_width,
    )
    if len(legacy_track) >= 2:
        tracks.append(legacy_track)
    tracks.extend(_recovery_tracks(records, tracks, rim, max_cross_gap_sec))
    rim_y = rim["rim_y"]
    rim_half_w = max(1.0, rim["width"] / 2.0)
    rim_height = max(1.0, float(rim.get("height", 20)))
    above_y = rim_y - 0.6 * rim_height
    below_y = rim_y + 0.9 * rim_height
    rim_left = rim["center_x"] - rim_half_w
    rim_right = rim["center_x"] + rim_half_w
    gate_margin = rim_width * 0.1
    candidates = []

    for track in tracks:
        for index, above in enumerate(track):
            if above["y"] > above_y:
                continue
            if index + 1 < len(track) and track[index + 1]["y"] <= above_y:
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

                intermediate_side_deviation = any(
                    above["time"] < point["time"] < below["time"]
                    and rim_y - 1.5 * rim_height <= point["y"] <= rim_y + 0.5 * rim_height
                    and not _point_in_rim_corridor(point, rim, tolerance_ratio=0.15)
                    and abs(point["x"] - float(rim["center_x"])) <= rim_width * 4.0
                    for point in track
                )
                if intermediate_side_deviation:
                    break

                later = _continuous_post_points(track, below, rim)
                below_depth = max(rim_width * 0.35, float(rim.get("height", 20)) * 0.5)
                below_points = [
                    point for point in later
                    if point["y"] >= rim_y + below_depth
                ]

                event_track = [
                    point for point in track
                    if above["time"] - 1.2 <= point["time"] <= below["time"]
                ]
                prediction = prediction_score(event_track, rim)
                prediction_review = bool(
                    prediction and
                    prediction["landing_center"] >= 0.5 and
                    prediction["predict_score"] >= 0.8
                )
                if len(below_points) < 2 and not prediction_review:
                    continue

                crossing_evidence = _complete_rim_crossing(
                    track, above, below, rim,
                )
                transition_points = crossing_evidence["transition_points"]
                transition_ratio = (
                    crossing_evidence["transition_corridor_points"] / transition_points
                    if transition_points else 1.0
                )
                reviewable_crossing = (
                    crossing_evidence["crossing_inside_rim"] and
                    (not transition_points or transition_ratio >= 0.75)
                )
                if not reviewable_crossing and not prediction_review:
                    continue

                previous_y = below["y"]
                rebounded = False
                # 球已深入篮下之后的回升是落地反弹(进球的正常后续),
                # 不算撞框反弹;只在篮筐附近平面内的回升才判为反弹信号。
                rebound_zone_bottom = rim_y + max(
                    2.5 * rim_height,
                    2.5 * rim_width,
                )
                for point in later:
                    if point["time"] <= below["time"]:
                        continue
                    if point["y"] >= rebound_zone_bottom:
                        break
                    if point["y"] < previous_y - max(
                        rim_width * 0.25,
                        float(rim.get("height", 20)) * 0.18,
                    ):
                        rebounded = True
                        break
                    previous_y = point["y"]
                if rebounded:
                    continue

                lateral_exit = any(
                    abs(point["x"] - rim["center_x"]) > 3.0 * rim_half_w
                    and point["y"] <= rim_y + max(
                        4.0 * float(rim.get("height", 20)),
                        4.0 * rim_width,
                    )
                    for point in later
                )
                deep_corridor_points = [
                    point
                    for point in later
                    if point["y"] >= rim_y + below_depth
                    and _point_in_rim_corridor(point, rim)
                ]
                post_crossing_lateral_recovery = (
                    lateral_exit
                    and len(below_points) >= 3
                    and len(deep_corridor_points) == 1
                    and not rebounded
                )
                if lateral_exit and not post_crossing_lateral_recovery:
                    continue

                event_time = _crossing_time_at_y(above, below, rim_y)
                if event_time is None:
                    break
                trajectory = _trajectory_features(track, above, below, rim)
                signals = _multi_signal_features(records, event_time)
                signals.update(_net_inside_motion_features(records, event_time))
                horizontal_ratio = abs(below["x"] - above["x"]) / max(1.0, below["y"] - above["y"])
                if horizontal_ratio > 0.95:
                    break
                descent_speed = (below["y"] - above["y"]) / max(0.001, gap)
                if descent_speed / rim_width > 16.0:
                    continue
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
                    "net_signal_available": signals["net_signal_available"],
                    "net_inside_motion_score": signals["net_inside_motion_score"],
                    "net_sequence_score": signals["net_sequence_score"],
                    "net_below_peak": signals["net_below_peak"],
                    "complete_crossing": crossing_evidence["complete_crossing"],
                    **normalized_geometry,
                })
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
                    **crossing_evidence,
                    **normalized_geometry,
                    "signals": signals,
                    "prediction": prediction,
                    "overlay": _overlay_data(
                        track,
                        rim,
                        above,
                        below,
                        x_cross,
                        event_time,
                        prediction,
                        crossing_valid=crossing_evidence["complete_crossing"],
                    ),
                    "score": score,
                    "gates": gates,
                    "confidence": _confidence_label(score, signals, gates),
                    "post_crossing_lateral_recovery": post_crossing_lateral_recovery,
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
                candidate.update({
                    "algorithm_version": ANALYSIS_CONTRACT_VERSION,
                    "event_ms": round(event_time * 1000),
                    "net_signal_available": verdict["net_signal_available"],
                    "net_support": verdict["net_support"],
                    "net_no_motion": verdict["net_no_motion"],
                    "net_lower_peak": signals["net_lower_peak"],
                    "net_below_peak": signals["net_below_peak"],
                    "ball_persistence": verdict["ball_persistence"],
                    "rebound": verdict["rebound"],
                    "lateral_exit": verdict["lateral_exit"],
                    "auto_export_eligible": candidate["gates"]["automatic_goal"],
                    "decision_time_ms": round(verdict["decision_time"] * 1000),
                })
                candidates.append(candidate)
                break

    return dedupe_candidates(candidates, dedupe_sec)
