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
   Such a video instead needs the net to move after the crossing.

A candidate is excluded only on what the detector saw: a ball crossing
outside the rim, leaving the side of the net, bouncing up, staying in front
of a net that hides makes, or a net that did not move. A small or blurred
ball drops out near the rim, and players or an orange jersey can block or
imitate it, so missing observations cannot prove a miss, even when the
refine stage did not confirm a crossing. Incomplete evidence is "unsure"
and stays for review.

Coordinates are normalized to the rim: x = (x - center_x) / width and
y = (y - rim_y) / width. Rims smaller than 30 px are skipped and left for
manual review.
"""
from statistics import median

RIM_CHECK_VERSION = "rim-dense-v2"
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
# one), so only a net that moved less than before proves a miss.
MIN_NET_MOTION = 0.0
# An off-center track must be a falling ball: misses spanned 1.06 rim widths
# and more, a jersey next to the rim 0.45. A shorter track may not be the
# shot ball either.
MIN_OFF_CENTER_TRACK_POINTS = 10
MIN_OFF_CENTER_TRACK_SPAN = 1.0
UNSEEN_REASONS = ("no_crossing", "no_entry", "no_exit")

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
            balls.append({"x": x, "y": y, "conf": float(item["confidence"])})
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
    # Seen misses take precedence over missing observations. Otherwise an
    # incomplete entry/exit could hide a witnessed rebound or side exit.
    if abs(crossing["x_cross"]) > MAX_CROSS_OFFSET:
        return "off_center"
    if crossing["x_exit"] is not None and abs(crossing["x_exit"]) > MAX_EXIT_OFFSET:
        return "exit_off_center"
    if crossing["rebound"]:
        return "rebound"
    if not crossing["entry"]:
        return "no_entry"
    if crossing["x_exit"] is None or not crossing["reached_net_bottom"]:
        return "no_exit"
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
    frames_balls = _drop_static([_frame_balls(detections, rim) for detections in frames])
    tracks = _build_tracks(frames_balls)
    crossings = [crossing for track in tracks for crossing in _track_crossings(track, tracks)]
    best = min(crossings, key=_rank) if crossings else None
    reason = rejection_reason(best)
    return {
        "version": RIM_CHECK_VERSION,
        "status": "made" if reason is None else "rejected",
        "reason": reason,
        "rim_width_px": round(rim_width, 2),
        "frames": len(frames),
        "ball_approached": _ball_approached(tracks),
        **(best or {}),
        "net_motion": net_motion_score(net_motion_series, best["cross_frame"])
        if best and net_motion_series else None,
    }


def keep_unless_seen(result, refined):
    """Turn a rejection that no detection proves into "unsure".

    Missing evidence remains uncertain regardless of upstream confirmation.
    ``refined`` is retained for compatibility with existing callers.
    """
    if result.get("status") != "rejected":
        return result
    reason = result.get("reason")
    if reason in UNSEEN_REASONS:
        proven = False
    elif reason == "off_center":
        proven = (
            result.get("track_points", 0) >= MIN_OFF_CENTER_TRACK_POINTS
            and result.get("track_span", 0.0) >= MIN_OFF_CENTER_TRACK_SPAN
        )
        # A short off-center track is inconclusive, but must not hide a
        # witnessed side exit or rebound from that same crossing.
        if not proven:
            if result.get("x_exit") is not None and abs(result["x_exit"]) > MAX_EXIT_OFFSET:
                return {**result, "reason": "exit_off_center"}
            if result.get("rebound"):
                return {**result, "reason": "rebound"}
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
        if not use_rule and result["reason"] in (None, "not_occluded"):
            still = result.get("net_motion") is not None and result["net_motion"] < MIN_NET_MOTION
            result.update(status="rejected" if still else "made", reason="net_still" if still else None)
        judged.append(result)
    return judged
