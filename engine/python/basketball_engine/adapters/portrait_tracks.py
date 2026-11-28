"""Associate portrait detections before choosing the ball for a shot."""
from __future__ import annotations

import math
from dataclasses import dataclass

MAX_TRACK_GAP_MS = 2000
EVENT_WINDOW_MS = 650
CROSSING_WINDOW_MS = 450


@dataclass(frozen=True)
class Ball:
    x: float
    y: float
    width: float
    height: float
    confidence: float

    @classmethod
    def from_box(cls, box, confidence=0.):
        left, top, right, bottom = box
        return cls((left + right) / 2, (top + bottom) / 2, right - left, bottom - top, confidence)

    @property
    def box(self):
        return [self.x - self.width / 2, self.y - self.height / 2,
                self.x + self.width / 2, self.y + self.height / 2]


@dataclass(frozen=True)
class TrackPoint:
    time: int
    ball: Ball


@dataclass(frozen=True)
class Shot:
    time: int | None
    rim: Ball | None
    track: list[TrackPoint]
    crossings: list[float]


def _unique_balls(balls):
    kept = []
    for ball in sorted(balls, key=lambda b: (-b.confidence, b.x, b.y)):
        # Full-frame and rim crops may report the same physical observation.
        if any(math.hypot(ball.x - other.x, ball.y - other.y)
               <= .5 * min(ball.width, ball.height, other.width, other.height) for other in kept):
            continue
        kept.append(ball)
    return kept


def _tracks(frames, crop):
    active, tracks = [], []
    for time, boxes in frames:
        balls = _unique_balls(boxes)
        active = [track_id for track_id in active if time - tracks[track_id][-1].time <= MAX_TRACK_GAP_MS]
        matches = []
        for track_id in active:
            track = tracks[track_id]
            last = track[-1]
            elapsed = time - last.time
            x, y = last.ball.x, last.ball.y
            if len(track) > 1 and elapsed <= 400:
                earlier = track[-2]
                fraction = min(elapsed, 200) / (last.time - earlier.time)
                x += (last.ball.x - earlier.ball.x) * fraction
                y += (last.ball.y - earlier.ball.y) * fraction
            radius = crop * min(.36, .10 + 2.4 * elapsed / 1000)
            for index, ball in enumerate(balls):
                distance = min(math.hypot(ball.x - x, ball.y - y),
                               math.hypot(ball.x - last.ball.x, ball.y - last.ball.y) + .06 * crop)
                if distance <= radius:
                    matches.append((distance + elapsed * crop * .00004, track_id, index))
        assigned_tracks, assigned_balls = set(), set()
        for _, track_id, index in sorted(matches):
            if track_id in assigned_tracks or index in assigned_balls:
                continue
            tracks[track_id].append(TrackPoint(time, balls[index]))
            assigned_tracks.add(track_id)
            assigned_balls.add(index)
        for index, ball in enumerate(balls):
            if index not in assigned_balls:
                active.append(len(tracks))
                tracks.append([TrackPoint(time, ball)])
    return [track for track in tracks if len(track) >= 2]


def _plane(rim):
    return rim.y - .2 * rim.height


def _crossings(track, rim):
    plane = _plane(rim)
    for i, (left, right) in enumerate(zip(track, track[1:])):
        dy = right.ball.y - left.ball.y
        gap = right.time - left.time
        if gap > CROSSING_WINDOW_MS or not left.ball.y < plane <= right.ball.y:
            continue
        fraction = (plane - left.ball.y) / dy
        x = left.ball.x + fraction * (right.ball.x - left.ball.x)
        if abs(x - rim.x) > .75 * rim.width:
            continue
        time = left.time + fraction * gap
        if not any(abs(point.ball.x - rim.x) <= rim.width and point.ball.y <= plane - .15 * rim.height
                   for point in reversed(track[max(0, i - 4):i + 1])
                   if time - point.time <= CROSSING_WINDOW_MS):
            continue
        if any(abs(point.ball.x - rim.x) <= rim.width and point.ball.y >= plane + .35 * rim.height
               for point in track[i + 1:i + 6] if point.time - time <= CROSSING_WINDOW_MS):
            yield time


def _event_rims(rims, hint):
    if hint is None:
        return rims
    matches = [rim for rim in rims if math.hypot(rim.x - hint.x, _plane(rim) - _plane(hint))
               <= max(rim.width, hint.width)]
    return matches or [hint]


def select_shots(frames, rims, crop, events):
    tracks = _tracks(frames, crop)
    first_track = tracks[0] if tracks else []
    shots = []
    for time, hint in events or [(None, None)]:
        candidates = _event_rims(rims, hint)
        best_crossing = None
        best_point = None
        for rim in candidates:
            plane = _plane(rim)
            for track in tracks:
                crossings = list(_crossings(track, rim))
                if time is None and crossings:
                    score = (-len(crossings), crossings[0])
                    if best_crossing is None or score < best_crossing[0]:
                        best_crossing = score, Shot(time, rim, track, crossings)
                if time is None:
                    continue
                for crossing in crossings:
                    delta = abs(crossing - time)
                    if delta <= EVENT_WINDOW_MS:
                        score = (delta, -len(track))
                        if best_crossing is None or score < best_crossing[0]:
                            best_crossing = score, Shot(time, rim, track, [crossing])
                for point in track:
                    delta = abs(point.time - time)
                    dx, dy = abs(point.ball.x - rim.x), abs(point.ball.y - plane)
                    if delta <= EVENT_WINDOW_MS and dx <= 2 * rim.width and dy <= 2 * rim.height:
                        score = (math.hypot(dx / rim.width, dy / rim.height) + delta / EVENT_WINDOW_MS,
                                 -len(track))
                        if best_point is None or score < best_point[0]:
                            best_point = score, Shot(time, rim, track, [])
        if choice := best_crossing or best_point:
            shots.append(choice[1])
        else:
            rim = candidates[0] if candidates else None
            # A calibrated shot can only be claimed by a track near its rim.
            shots.append(Shot(time, rim, first_track if hint is None else [], []))
    return shots
