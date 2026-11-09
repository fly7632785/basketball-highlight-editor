"""Frame-by-frame rim crossing check on a tight crop around the rim.

The detector runs on every source frame around a candidate, on a square crop
of about five rim widths, so the ball stays large and no crossing frame is
skipped. A make must:

1. come down from above the rim opening,
2. cross the rim plane inside the rim, a ball rolling on the rim included,
3. reach the net bottom close to the rim center and keep falling,
4. not bounce back up near the rim,
5. be hidden or blurred for at least one frame while passing the rim/net.
   A ball that falls in front of the rim stays fully visible. Close, low
   cameras with a thin net see the ball clearly through the net, so this
   rule is dropped for a video where most central crossings stay visible.
   In that mode, compare net movement with its own pre-crossing level.
   An accelerating ball with little net response, or a fully visible
   unimpeded passage outside the opening, is evidence against a make.

A candidate is excluded only on what the detector saw: a ball crossing
outside the rim, leaving the side of the net, bouncing up, staying in front
of a net that hides makes, or a net that did not move. A small or blurred
ball drops out near the rim, and players or an orange jersey can block or
imitate it, so "the ball was not seen" excludes a candidate only when the
refine stage did not see a crossing either and no ball fell toward the rim.
Other failed checks are "unsure" and stay for review.

Coordinates are normalized to the rim: x = (x - center_x) / width and
y = (y - rim_y) / width. Rims smaller than 30 px are skipped and left for
manual review.
"""
from statistics import median

RIM_CHECK_VERSION = "rim-dense-v3"
AUTO_REVIEW_REASON = "auto_rim_check"
MIN_RIM_WIDTH_PX = 30.0
CROP_RIM_WIDTHS = 5.0
MIN_CROP_SIDE_PX = 96.0
WINDOW_BEFORE_S = 1.0
WINDOW_AFTER_S = 1.0

MIN_BALL_CONF = 0.15
STRONG_BALL_CONF = 0.5
# The rim opening spans +-0.5; a ball rolling on the rim crosses up to 0.7.
MAX_CROSS_OFFSET = 0.7
MAX_EXIT_OFFSET = 0.7
MIN_HIDDEN_FRAMES = 1
# Reviewed videos where the net hides the ball: 86% and 95% of central
# crossings were hidden, 70% for a far camera. A close camera with a thin
# net: 16%.
MIN_OCCLUDED_SHARE = 0.5
MIN_OCCLUSION_SAMPLES = 8
# A visible ball proves a miss only where the net hides nearly every make.
STRONG_OCCLUDED_SHARE = 0.8
# Net motion after the crossing minus before. Its scale depends on the camera
# and the net (makes scored 2.6 and up on a close camera, -0.7 to 4 on a far
# one), so a negative change remains the original net-still check.
MIN_NET_MOTION = 0.0
# An off-center track must be a falling ball: misses spanned 1.06 rim widths
# and more, a jersey next to the rim 0.45. A shorter track may not be the
# shot ball either.
MIN_OFF_CENTER_TRACK_POINTS = 10
MIN_OFF_CENTER_TRACK_SPAN = 1.0
UNSEEN_REASONS = ("no_crossing", "no_entry", "no_exit")
# Same-frame boxes near the mouth of the net can describe the same ball.
DUPLICATE_BALL_RADIUS = 0.3
# Ratios use this candidate's pre-crossing motion, not a camera-specific
# pixel-difference threshold. Require independent accelerating ball evidence.
MIN_NET_RESPONSE_RATIO = 2.0
MIN_PASSAGE_SPEED_RATIO = 1.05
RIM_OPENING_HALF_WIDTH = 0.5
MIN_CAPTURE_OVERLAP = 0.75
NET_HOLD_RANGE = 0.2
MIN_NET_HOLD_FRAMES = 6
MIN_EDGE_HOLD_FRAMES = 4

_ZONE_X = 2.5
_ZONE_TOP = -2.5
_ZONE_BOTTOM = 3.0


def tight_crop_box(rim, frame_width, frame_height):
    """Square crop centered just below the rim so approach and net exit fit."""
    side = max(MIN_CROP_SIDE_PX, CROP_RIM_WIDTHS * float(rim["width"]))
    side = min(side, float(frame_width), float(frame_height))
    cx = float(rim["center_x"])
    cy = float(rim["rim_y"]) + 0.75 * float(rim["width"])
    x1 = int(round(min(max(0.0, cx - side / 2), frame_width - side)))
    y1 = int(round(min(max(0.0, cy - side / 2), frame_height - side)))
    return [x1, y1, x1 + int(side), y1 + int(side)]


def _frame_balls(detections, rim):
    width = float(rim["width"])
    balls = []
    for item in detections:
        if item.get("name") != "ball" or float(item.get("confidence", 0.0)) < MIN_BALL_CONF:
            continue
        x1, y1, x2, y2 = item["xyxy"]
        x = ((x1 + x2) / 2 - float(rim["center_x"])) / width
        y = ((y1 + y2) / 2 - float(rim["rim_y"])) / width
        if abs(x) <= _ZONE_X and _ZONE_TOP <= y <= _ZONE_BOTTOM:
            balls.append({"x": x, "y": y, "conf": float(item["confidence"]),
                          "radius": (x2 - x1) / (2 * width)})
    return balls


def _drop_static(frames_balls, radius=0.12, min_frames=6):
    """Remove detections that sit still for many frames (bolts, logos)."""
    flat = [(index, ball) for index, balls in enumerate(frames_balls) for ball in balls]
    static = set()
    for index, ball in flat:
        frames = {
            other_index for other_index, other in flat
            if abs(other["x"] - ball["x"]) <= radius and abs(other["y"] - ball["y"]) <= radius
        }
        if len(frames) >= min_frames:
            static.add((index, id(ball)))
    return [
        [ball for ball in balls if (index, id(ball)) not in static]
        for index, balls in enumerate(frames_balls)
    ]


def _dedupe_balls(frames_balls):
    """Keep the strongest of overlapping same-frame ball centers.

    This never joins different times or candidates. Distant simultaneous balls
    remain separate; only centers within 0.3 rim widths are suppressed.
    """
    output = []
    for balls in frames_balls:
        kept = []
        for ball in sorted(balls, key=lambda item: -item["conf"]):
            if not any(
                (ball["x"] - other["x"]) ** 2 + (ball["y"] - other["y"]) ** 2
                < DUPLICATE_BALL_RADIUS ** 2
                for other in kept
            ):
                kept.append(ball)
        output.append(kept)
    return output


def _passage_speed_ratio(path, cross_frame):
    """Downward speed in the net / speed just before it, or no evidence.

    Use at least two short, strong detection intervals on each side. Long
    hidden gaps and low-confidence duplicate boxes cannot establish free fall.
    Speed units cancel in the ratio; the short windows use source frames.
    """
    def speed(low, high, first, last):
        points = [
            point for point in path
            if first <= point["i"] <= last and low <= point["y"] <= high
            and point["conf"] >= STRONG_BALL_CONF
        ]
        velocities = [
            (b["y"] - a["y"]) / (b["i"] - a["i"])
            for a, b in zip(points, points[1:])
            if 0 < b["i"] - a["i"] <= 2 and b["y"] > a["y"]
        ]
        return median(velocities[-4:]) if len(velocities) >= 2 else None

    before = speed(-1.2, -0.1, cross_frame - 12, cross_frame)
    after = speed(0.0, 1.2, cross_frame, cross_frame + 10)
    return round(after / before, 3) if before and after else None


def _build_tracks(frames_balls, per_frame=0.7, max_gap=12, max_jump=2.0):
    tracks = []
    for index, balls in enumerate(frames_balls):
        for ball in sorted(balls, key=lambda item: -item["conf"]):
            point = {**ball, "i": index}
            best = None
            for track in tracks:
                last = track[-1]
                gap = index - last["i"]
                if gap <= 0 or gap > max_gap:
                    continue
                distance = ((point["x"] - last["x"]) ** 2 + (point["y"] - last["y"]) ** 2) ** 0.5
                if distance <= min(per_frame * gap, max_jump) and (best is None or distance < best[0]):
                    best = (distance, track)
            if best:
                best[1].append(point)
            else:
                tracks.append([point])
    return [track for track in tracks if len(track) >= 3]


def _continuation(after, below, tracks):
    """Append a fragment that starts right after the crossing.

    The net often yields a second box in the same frame, which splits one
    physical fall into two tracks.
    """
    tail = after[-1] if after else below
    for other in tracks:
        first = other[0]
        if (
            below["i"] - 3 <= first["i"] <= tail["i"] + 12
            and -0.1 <= first["y"] <= 1.0
            and abs(first["x"] - tail["x"]) <= 0.8
            and other[-1]["i"] > tail["i"]
        ):
            return after + [point for point in other if point["i"] > tail["i"]]
    return after



def _net_hold_frames(path, cross_frame):
    """Longest strong, consecutive near-stationary segment at the net mouth.

    A ball caught or carried in front of the net must not supply a free-fall
    exit. Short slowdowns are common in genuine makes, so this feature alone
    never rejects a passage.
    """
    points = [p for p in path if cross_frame <= p["i"] <= cross_frame + 12]
    longest = 0
    for start in range(len(points)):
        segment = []
        for point in points[start:]:
            if (point["conf"] < STRONG_BALL_CONF or not 0.15 <= point["y"] <= 0.85
                    or abs(point["x"]) > MAX_EXIT_OFFSET
                    or (segment and point["i"] != segment[-1]["i"] + 1)):
                break
            segment.append(point)
            if any(max(p[axis] for p in segment) - min(p[axis] for p in segment) > NET_HOLD_RANGE
                   for axis in ("x", "y")):
                break
            longest = max(longest, len(segment))
    return longest


def _track_crossings(track, tracks):
    others = [other for other in tracks if other is not track]
    for k in range(len(track) - 1):
        above, below = track[k], track[k + 1]
        if not (above["y"] < 0 <= below["y"]):
            continue
        ratio = -above["y"] / (below["y"] - above["y"])
        x_cross = above["x"] + ratio * (below["x"] - above["x"])
        entry = any(
            -1.2 <= point["y"] <= -0.1 and point["i"] >= above["i"] - 15
            for point in track[:k + 1]
        )
        after = _continuation(track[k + 1:], below, others)
        exits = [point for point in after if point["y"] >= 0.4 and point["i"] - below["i"] <= 20]
        deep = [point for point in after if point["y"] >= 1.0 and point["i"] - below["i"] <= 30]
        rebound = False
        lowest = below["y"]
        for point in after:
            if point["y"] > 1.2:
                break
            if point["y"] < lowest - 0.3:
                rebound = True
                break
            lowest = max(lowest, point["y"])
        last_above = max(
            (point["i"] for point in track[:k + 1] if point["y"] < -0.1),
            default=above["i"],
        )
        first_below = min(
            (point["i"] for point in after if point["y"] >= 0.6),
            default=below["i"],
        )
        path = track[:k + 1] + after
        radii = [
            point["radius"] for point in path
            if abs(point["i"] - below["i"]) <= 2
            and point["conf"] >= STRONG_BALL_CONF
            and 0.05 <= point.get("radius", 0.0) <= 0.4
        ]
        clearance = RIM_OPENING_HALF_WIDTH - abs(x_cross) - median(radii) if radii else None
        overlap = None
        if radii:
            radius = median(radii)
            inside = min(RIM_OPENING_HALF_WIDTH, x_cross + radius) - max(-RIM_OPENING_HALF_WIDTH, x_cross - radius)
            overlap = max(0.0, inside / (2 * radius))
        seen = {point["i"]: point["conf"] for point in path}
        hidden = sum(
            1 for index in range(last_above + 1, first_below)
            if seen.get(index, 0.0) < STRONG_BALL_CONF
        )
        yield {
            "x_cross": round(x_cross, 3),
            "entry": entry,
            "x_exit": round(exits[0]["x"], 3) if exits else None,
            "reached_net_bottom": bool(deep),
            "rebound": rebound,
            "hidden_frames": hidden,
            "track_points": k + 1 + len(after),
            "track_span": round(max(point["y"] for point in path) - min(point["y"] for point in path), 3),
            "cross_frame": below["i"],
            "passage_speed_ratio": _passage_speed_ratio(path, below["i"]),
            "opening_clearance": round(clearance, 3) if clearance is not None else None,
            "opening_overlap": round(overlap, 3) if overlap is not None else None,
            "net_hold_frames": _net_hold_frames(path, below["i"]),
        }


def _ball_approached(tracks):
    """Whether a ball fell toward the rim from above, close to its center."""
    for track in tracks:
        above = [point for point in track if abs(point["x"]) <= 1.5 and -2.5 <= point["y"] <= -0.1]
        if len(above) >= 3 and above[-1]["y"] - above[0]["y"] >= 0.3:
            return True
    return False


def rejection_reason(crossing):
    """Return why a crossing is not a make, or ``None`` for a make."""
    if crossing is None:
        return "no_crossing"
    if not crossing["entry"]:
        return "no_entry"
    if abs(crossing["x_cross"]) > MAX_CROSS_OFFSET:
        return "off_center"
    if crossing["x_exit"] is None or not crossing["reached_net_bottom"]:
        return "no_exit"
    if abs(crossing["x_exit"]) > MAX_EXIT_OFFSET:
        return "exit_off_center"
    if crossing["rebound"]:
        return "rebound"
    if crossing["hidden_frames"] < MIN_HIDDEN_FRAMES:
        return "not_occluded"
    return None


def _rank(crossing):
    # Rejection reasons are ordered by how far the evidence got; any fragment
    # that proves a make wins over a closer-to-center fragment that lost the
    # ball (rim rollers often split into several fragments).
    order = ["no_entry", "off_center", "no_exit", "exit_off_center", "rebound", "not_occluded", None]
    return (-order.index(rejection_reason(crossing)), abs(crossing["x_cross"]))


def skipped_result(reason, rim_width=None):
    return {
        "version": RIM_CHECK_VERSION,
        "status": "skipped",
        "reason": reason,
        "rim_width_px": round(float(rim_width), 2) if rim_width is not None else None,
    }


def net_motion_score(series, cross_frame):
    """Net motion right after the crossing minus the motion before it.

    ``series[k]`` is the change of the net from frame k-1 to frame k. The top
    five changes after the crossing count, so a short push is enough.
    """
    before = [value for value in series[max(1, cross_frame - 24):cross_frame - 5] if value is not None]
    after = sorted(value for value in series[cross_frame + 1:cross_frame + 21] if value is not None)
    if not before or not after:
        return None
    return round(sum(after[-5:]) / len(after[-5:]) - median(before), 3)



def _local_net_response_ratio(series, cross_frame):
    """Measure a new net push against the immediately preceding five frames.

    An earlier rim bounce can move the net inside the long baseline used by
    net_motion_score. Keep that score for replay, but do not infer an inert
    net from it when a well-sampled new push starts at the final crossing.
    Missing recent frames provide no positive evidence.
    """
    before = [value for value in series[max(1, cross_frame - 5):cross_frame]
              if value is not None]
    after = sorted(value for value in series[cross_frame + 1:cross_frame + 21]
                   if value is not None)
    if len(before) < 3 or len(after) < 5:
        return None
    baseline = median(before)
    push = sum(after[-5:]) / 5
    return round((push - baseline) / max(baseline, 0.05), 3)


def assess_rim_crossing(frames, rim, net_motion_series=None):
    """Judge one candidate from per-frame detections in source coordinates.

    ``frames`` is the ordered list of consecutive source frames; each item is
    a list of detections ``{"name", "confidence", "xyxy"}``.
    ``net_motion_series`` comes from ``net_motion.net_motion_series``.
    """
    rim_width = float(rim["width"])
    if rim_width < MIN_RIM_WIDTH_PX:
        return skipped_result("small_rim", rim_width)
    if not frames:
        return skipped_result("no_frames", rim_width)
    frames_balls = _drop_static(_dedupe_balls([_frame_balls(detections, rim) for detections in frames]))
    tracks = _build_tracks(frames_balls)
    crossings = [crossing for track in tracks for crossing in _track_crossings(track, tracks)]
    best = min(crossings, key=_rank) if crossings else None
    reason = rejection_reason(best)
    motion = net_motion_score(net_motion_series, best["cross_frame"]) if best and net_motion_series else None
    before = [
        value for value in (net_motion_series or [])[max(1, best["cross_frame"] - 24):best["cross_frame"] - 5]
        if value is not None
    ] if best else []
    response = motion / max(median(before), 0.05) if motion is not None and before else None
    return {
        "version": RIM_CHECK_VERSION,
        "status": "made" if reason is None else "rejected",
        "reason": reason,
        "rim_width_px": round(rim_width, 2),
        "frames": len(frames),
        "ball_approached": _ball_approached(tracks),
        **(best or {}),
        "net_motion": motion,
        "net_response_ratio": round(response, 3) if response is not None else None,
        "net_local_response_ratio": _local_net_response_ratio(net_motion_series, best["cross_frame"])
        if best and net_motion_series else None,
    }


def keep_unless_seen(result, refined):
    """Turn a rejection that no detection proves into "unsure".

    ``refined`` tells whether the refine stage saw a crossing.
    """
    if result.get("status") != "rejected":
        return result
    reason = result.get("reason")
    if reason in UNSEEN_REASONS:
        proven = not refined and not result.get("ball_approached")
    elif reason == "off_center":
        proven = (
            result.get("track_points", 0) >= MIN_OFF_CENTER_TRACK_POINTS
            and result.get("track_span", 0.0) >= MIN_OFF_CENTER_TRACK_SPAN
        )
    elif reason == "not_occluded":
        proven = (result.get("occluded_share") or 0.0) >= STRONG_OCCLUDED_SHARE
    else:
        proven = True
    return result if proven else {**result, "status": "unsure"}


def apply_video_occlusion(results):
    """Drop the occlusion rule for a video whose net does not hide the ball.

    ``results`` are the rim checks of every candidate of one video. Central
    crossings are those that passed every rule except possibly occlusion.
    Without the occlusion rule a central crossing must move the net instead.
    """
    central = [
        result for result in results
        if result.get("status") in ("made", "rejected") and result.get("reason") in (None, "not_occluded")
    ]
    share = sum(1 for result in central if result["reason"] is None) / len(central) if central else None
    use_rule = len(central) < MIN_OCCLUSION_SAMPLES or share >= MIN_OCCLUDED_SHARE
    judged = []
    for result in results:
        if result.get("status") not in ("made", "rejected"):
            judged.append(result)
            continue
        result = {
            **result,
            "occluded_share": round(share, 3) if share is not None else None,
            "occlusion_rule": use_rule,
        }
        # The net can carry a made ball sideways. Require a supported
        # approach, most of the ball inside the mouth, and two net responses;
        # a strong background motion by itself cannot override side geometry.
        captured_lateral_exit = (
            result.get("reason") == "exit_off_center"
            and result.get("ball_approached") is True and result.get("entry") is True
            and result.get("reached_net_bottom") is True and not result.get("rebound")
            and (result.get("opening_overlap") or 0.0) >= MIN_CAPTURE_OVERLAP
            and (result.get("net_response_ratio") or 0.0) >= MIN_NET_RESPONSE_RATIO
            and (result.get("net_local_response_ratio") or 0.0) >= MIN_NET_RESPONSE_RATIO
            and result.get("track_points", 0) >= MIN_OFF_CENTER_TRACK_POINTS
        )
        if captured_lateral_exit:
            result.update(status="made", reason=None, net_lateral_capture=True)
            judged.append(result)
            continue
        if not use_rule and result["reason"] in (None, "not_occluded"):
            still = result.get("net_motion") is not None and result["net_motion"] < MIN_NET_MOTION
            accelerating = (result.get("passage_speed_ratio") or 0.0) >= MIN_PASSAGE_SPEED_RATIO
            # A fast, fully visible crossing outside the opening is a side
            # passage, even if contact or background activity moves the net.
            bypass = (
                (result.get("passage_speed_ratio") or 0.0) >= 1.0
                and result.get("hidden_frames") == 0
                and abs(result.get("x_cross", 0.0)) > RIM_OPENING_HALF_WIDTH
            )
            local_push = (
                result.get("net_local_response_ratio") is not None
                and result["net_local_response_ratio"] >= MIN_NET_RESPONSE_RATIO
            )
            weak_response = (
                accelerating and result.get("net_response_ratio") is not None
                and result["net_response_ratio"] < MIN_NET_RESPONSE_RATIO
                and not local_push
            )
            # The ball has finite width. A center just inside the edge does
            # not establish a make when the ball overlaps the outside and the
            # net barely responds. Require a substantial, fully visible track.
            edge_without_response = (
                result.get("net_response_ratio") is not None
                and result["net_response_ratio"] < MIN_NET_RESPONSE_RATIO
                and result.get("opening_clearance") is not None
                and result["opening_clearance"] < 0.0
                and result.get("hidden_frames") == 0
                and result.get("track_points", 0) >= MIN_OFF_CENTER_TRACK_POINTS
                and result.get("track_span", 0.0) >= MIN_OFF_CENTER_TRACK_SPAN
            )
            local_response = result.get("net_local_response_ratio")
            held_in_front = (
                (result.get("net_hold_frames", 0) >= MIN_NET_HOLD_FRAMES
                 and accelerating and local_response is not None
                 and local_response < MIN_NET_RESPONSE_RATIO)
                or (result.get("net_hold_frames", 0) >= MIN_EDGE_HOLD_FRAMES
                    and result.get("ball_approached") is False
                    and result.get("opening_overlap") is not None
                    and result["opening_overlap"] < MIN_CAPTURE_OVERLAP)
            )
            reason = None
            if still:
                reason = "net_still"
            elif bypass:
                reason = "rim_bypass"
            elif held_in_front:
                reason = "held_ball_in_front"
            elif weak_response:
                reason = "net_unresponsive"
            elif edge_without_response:
                reason = "edge_without_net_response"
            result.update(status="rejected" if reason else "made", reason=reason)
        judged.append(result)
    return judged
