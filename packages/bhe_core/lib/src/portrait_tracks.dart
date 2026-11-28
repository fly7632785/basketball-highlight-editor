part of 'portrait_planner.dart';

// The desktop export uses the same track association and shot selection.
const _maxTrackGapMs = 2000;
const _eventWindowMs = 650;
const _crossingWindowMs = 450;

typedef _TrackPoint = (int, PortraitDetection);
typedef _Shot = (List<_TrackPoint>, PortraitDetection?);
typedef _BallFrame = (int, List<PortraitDetection>);

double _distance(double dx, double dy) => math.sqrt(dx * dx + dy * dy);

List<PortraitDetection> _uniqueBalls(List<PortraitDetection> boxes) {
  final sorted = [...boxes]
    ..sort((a, b) {
      final score = b.conf.compareTo(a.conf);
      if (score != 0) return score;
      final x = a.cx.compareTo(b.cx);
      return x != 0 ? x : a.cy.compareTo(b.cy);
    });
  final kept = <PortraitDetection>[];
  for (final ball in sorted) {
    final size = math.min(ball.w, ball.h);
    if (kept.any(
      (other) =>
          _distance(ball.cx - other.cx, ball.cy - other.cy) <=
          .5 * math.min(size, math.min(other.w, other.h)),
    )) {
      continue;
    }
    kept.add(ball);
  }
  return kept;
}

List<_BallFrame> _ballFrames(
  Iterable<PortraitTrackSample> samples,
  double width,
  int height,
) => [
  for (final sample in samples)
    (
      sample.tMs,
      [
        for (final ball in sample.balls)
          if (PortraitPlanner._valid(ball, width, height) &&
              ball.w / ball.h >= .6 &&
              ball.w / ball.h <= 1.6 &&
              math.max(ball.w, ball.h) <= .08 * width)
            ball,
      ],
    ),
];

List<List<_TrackPoint>> _ballTracks(List<_BallFrame> frames, double crop) {
  final tracks = <List<_TrackPoint>>[];
  final active = <int>[];
  for (final (time, boxes) in frames) {
    final balls = _uniqueBalls(boxes);
    active.removeWhere((id) => time - tracks[id].last.$1 > _maxTrackGapMs);
    final matches = <(double, int, int)>[];
    for (final id in active) {
      final track = tracks[id];
      final (lastTime, last) = track.last;
      final elapsed = time - lastTime;
      var x = last.cx, y = last.cy;
      if (track.length > 1 && elapsed <= 400) {
        final (earlierTime, earlier) = track[track.length - 2];
        final fraction = math.min(elapsed, 200) / (lastTime - earlierTime);
        x += (last.cx - earlier.cx) * fraction;
        y += (last.cy - earlier.cy) * fraction;
      }
      final radius = crop * math.min(.36, .10 + 2.4 * elapsed / 1000);
      for (var i = 0; i < balls.length; i++) {
        final ball = balls[i];
        final distance = math.min(
          _distance(ball.cx - x, ball.cy - y),
          _distance(ball.cx - last.cx, ball.cy - last.cy) + .06 * crop,
        );
        if (distance <= radius) {
          matches.add((distance + elapsed * crop * .00004, id, i));
        }
      }
    }
    matches.sort((a, b) {
      final cost = a.$1.compareTo(b.$1);
      if (cost != 0) return cost;
      final track = a.$2.compareTo(b.$2);
      return track != 0 ? track : a.$3.compareTo(b.$3);
    });
    final assignedTracks = <int>{};
    final assignedBalls = <int>{};
    for (final (_, id, i) in matches) {
      if (assignedTracks.contains(id) || assignedBalls.contains(i)) continue;
      tracks[id].add((time, balls[i]));
      assignedTracks.add(id);
      assignedBalls.add(i);
    }
    for (var i = 0; i < balls.length; i++) {
      if (assignedBalls.contains(i)) continue;
      active.add(tracks.length);
      tracks.add([(time, balls[i])]);
    }
  }
  return [
    for (final track in tracks)
      if (track.length >= 2) track,
  ];
}

List<_TrackPoint> _manualTrack(List<List<_TrackPoint>> tracks) {
  final observations =
      [
        for (final (id, track) in tracks.indexed)
          for (final point in track) (id, point),
      ]..sort((a, b) {
        final time = a.$2.$1.compareTo(b.$2.$1);
        return time != 0 ? time : a.$1.compareTo(b.$1);
      });
  final selected = <_TrackPoint>[];
  int? active;
  for (final (id, point) in observations) {
    if (selected.isEmpty ||
        id == active ||
        point.$1 - selected.last.$1 > _maxTrackGapMs) {
      selected.add(point);
      active = id;
    }
  }
  return selected;
}

List<_TrackPoint> _baselineTrack(List<_BallFrame> frames, double crop) {
  final selected = <_TrackPoint>[];
  for (final (time, boxes) in frames) {
    if (boxes.isEmpty) continue;
    PortraitDetection? strongest, nearby;
    final elapsed = selected.isEmpty
        ? PortraitPlanner._supportMs + 1
        : time - selected.last.$1;
    final previous = elapsed <= PortraitPlanner._supportMs
        ? selected.last.$2
        : null;
    var radius = PortraitPlanner._observationRadius(crop, elapsed);
    for (final ball in boxes) {
      if (strongest == null || ball.conf > strongest.conf) strongest = ball;
      if (previous != null) {
        final distance = _distance(
          ball.cx - previous.cx,
          ball.cy - previous.cy,
        );
        if (distance < radius) {
          radius = distance;
          nearby = ball;
        }
      }
    }
    selected.add((time, nearby ?? strongest!));
  }
  return selected;
}

double _rimPlane(PortraitDetection rim) => rim.cy - .2 * rim.h;

Iterable<double> _crossings(
  List<_TrackPoint> track,
  PortraitDetection rim,
) sync* {
  final plane = _rimPlane(rim);
  for (var i = 0; i + 1 < track.length; i++) {
    final (leftTime, left) = track[i];
    final (rightTime, right) = track[i + 1];
    final gap = rightTime - leftTime;
    if (gap > _crossingWindowMs || left.cy >= plane || right.cy < plane) {
      continue;
    }
    final fraction = (plane - left.cy) / (right.cy - left.cy);
    final x = left.cx + fraction * (right.cx - left.cx);
    if ((x - rim.cx).abs() > .75 * rim.w) continue;
    final time = leftTime + fraction * gap;
    final above = track
        .getRange(math.max(0, i - 4), i + 1)
        .any(
          (point) =>
              time - point.$1 <= _crossingWindowMs &&
              (point.$2.cx - rim.cx).abs() <= rim.w &&
              point.$2.cy <= plane - .15 * rim.h,
        );
    if (!above) continue;
    final below = track
        .getRange(i + 1, math.min(track.length, i + 6))
        .any(
          (point) =>
              point.$1 - time <= _crossingWindowMs &&
              (point.$2.cx - rim.cx).abs() <= rim.w &&
              point.$2.cy >= plane + .35 * rim.h,
        );
    if (below) yield time;
  }
}

_Shot _selectShot(
  List<_BallFrame> frames,
  double crop,
  List<PortraitDetection> rims,
  int? time,
  PortraitDetection? hint,
) {
  final tracks = _ballTracks(frames, crop);
  final currentRim = rims.firstOrNull;
  if (hint != null) {
    rims = [
      for (final rim in rims)
        if (_distance(rim.cx - hint.cx, _rimPlane(rim) - _rimPlane(hint)) <=
            math.max(rim.w, hint.w))
          rim,
    ];
    if (rims.isEmpty) rims = [hint];
  }
  (num, num, _Shot)? crossingChoice, pointChoice;
  for (final rim in rims) {
    final plane = _rimPlane(rim);
    for (final track in tracks) {
      final crossings = _crossings(track, rim).toList();
      if (time == null) {
        if (crossings.isNotEmpty) {
          crossingChoice = _preferred(crossingChoice, (
            -crossings.length,
            crossings.first,
            (track, rim),
          ));
        }
        continue;
      }
      for (final crossing in crossings) {
        final delta = (crossing - time).abs();
        if (delta <= _eventWindowMs) {
          crossingChoice = _preferred(crossingChoice, (
            delta,
            -track.length,
            (track, rim),
          ));
        }
      }
      for (final (at, ball) in track) {
        final delta = (at - time).abs();
        final dx = (ball.cx - rim.cx).abs(), dy = (ball.cy - plane).abs();
        if (delta <= _eventWindowMs && dx <= 2 * rim.w && dy <= 2 * rim.h) {
          final score =
              _distance(dx / rim.w, dy / rim.h) + delta / _eventWindowMs;
          pointChoice = _preferred(pointChoice, (
            score,
            -track.length,
            (track, rim),
          ));
        }
      }
    }
  }
  // Event metadata can drift. Fall back to the original selection when the
  // ball observations do not support the event.
  return (crossingChoice ?? pointChoice)?.$3 ??
      (
        time == null ? _manualTrack(tracks) : _baselineTrack(frames, crop),
        currentRim ?? hint,
      );
}

(num, num, _Shot) _preferred(
  (num, num, _Shot)? best,
  (num, num, _Shot) candidate,
) =>
    best == null ||
        candidate.$1 < best.$1 ||
        (candidate.$1 == best.$1 && candidate.$2 < best.$2)
    ? candidate
    : best;
