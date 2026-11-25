import 'dart:math' as math;

enum ExportFraming { original, portrait916 }

class PortraitDetection {
  const PortraitDetection({
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.conf,
  });

  final double cx, cy, w, h, conf;
}

class PortraitTrackSample {
  const PortraitTrackSample({
    required this.tMs,
    required this.balls,
    required this.rims,
  });

  final int tMs;
  final List<PortraitDetection> balls, rims;
}

class PortraitKeyframe {
  const PortraitKeyframe(this.tMs, this.cxNorm);

  final int tMs;
  final double cxNorm;
}

class PortraitPlan {
  const PortraitPlan({required this.keyframes, required this.trackingCoverage});

  final List<PortraitKeyframe> keyframes;
  final double trackingCoverage;

  /// Desktop requires ball observations in at least a quarter of its local
  /// evidence window. Use the same fraction over each exported clip.
  static const minBallCoverage = .25;
  bool get hasBallTrack => trackingCoverage >= minBallCoverage;
}

abstract final class PortraitPlanner {
  static const sampleHz = 10;
  static const _samplePeriodMs = 1000 ~/ sampleHz;
  // Desktop supports nearby ball positions for four samples at 10 Hz and
  // checks isolated jumps against observations up to one second away.
  static const _supportMs = 400;
  static const _neighbourMs = 1000;
  static const _smoothingMs = 450;
  static const _smoothingRadiusMs = 3 * _smoothingMs;
  static const _deadZoneFraction = .06;
  // Desktop's normal-pan limits, in crop widths per second and second squared.
  static const _maxPanSpeed = .6;
  static const _maxPanAcceleration = .8;
  // Same framing margin as the desktop safe path, relaxed at image edges.
  static const _ballMarginFraction = .42;

  static PortraitPlan plan({
    required int frameWidth,
    required int frameHeight,
    required int startMs,
    required int endMs,
    required Iterable<PortraitTrackSample> samples,
  }) {
    if (frameWidth < 2 || frameHeight < 2 || startMs < 0 || startMs >= endMs) {
      throw ArgumentError('Invalid portrait source dimensions or clip range');
    }
    final width = frameWidth.toDouble();
    final half = math.min(width, frameHeight * 9 / 16) / 2;
    double bound(double x) => x.clamp(half, width - half);
    final inRange = {
      for (final sample in samples)
        if (sample.tMs >= startMs && sample.tMs <= endMs) sample.tMs: sample,
    };
    final times = {startMs, endMs, ...inRange.keys}.toList()..sort();
    final observations = <(int, double)>[];
    PortraitDetection? previousBall;
    for (final t in times) {
      final sample = inRange[t];
      if (sample == null) continue;
      PortraitDetection? strongest, nearby;
      final elapsed = observations.isEmpty
          ? _supportMs + 1
          : t - observations.last.$1;
      final previous = elapsed <= _supportMs ? previousBall : null;
      var nearestDistance = _observationRadius(half * 2, elapsed);
      for (final ball in sample.balls) {
        // Desktop bounds for a plausible ball box. Partially visible balls
        // at the source edges can still provide a center.
        if (!_valid(ball, width, frameHeight) ||
            ball.w / ball.h < .6 ||
            ball.w / ball.h > 1.6 ||
            math.max(ball.w, ball.h) > .08 * width) {
          continue;
        }
        if (strongest == null || ball.conf > strongest.conf) strongest = ball;
        // Keep a recent track when a distant detection briefly ranks higher.
        if (previous != null) {
          final dx = ball.cx - previous.cx, dy = ball.cy - previous.cy;
          final distance = math.sqrt(dx * dx + dy * dy);
          if (distance < nearestDistance) {
            nearestDistance = distance;
            nearby = ball;
          }
        }
      }
      final selected = nearby ?? strongest;
      if (selected != null) {
        observations.add((t, selected.cx));
        previousBall = selected;
      }
    }
    final clean = [
      for (var i = 0; i < observations.length; i++)
        if (_supportedObservation(observations, i, half * 2)) observations[i],
    ];
    final rim = _stableRim(
      times.map((t) => inRange[t]).whereType<PortraitTrackSample>(),
      width,
      frameHeight,
      half * 2,
    );
    final targets = <double>[];
    var last = width / 2;
    var next = 0;
    for (final t in times) {
      while (next < clean.length && clean[next].$1 <= t) {
        next++;
      }
      final left = next > 0 ? clean[next - 1] : null;
      final right = next < clean.length ? clean[next] : null;
      final fromLeft = left == null ? double.infinity : t - left.$1;
      final fromRight = right == null ? double.infinity : right.$1 - t;
      if (left != null &&
          right != null &&
          fromLeft + fromRight <= 2 * _supportMs) {
        last =
            left.$2 + (right.$2 - left.$2) * fromLeft / (fromLeft + fromRight);
      } else if (left != null &&
          fromLeft <= _supportMs &&
          fromLeft <= fromRight) {
        last = left.$2;
      } else if (right != null && fromRight <= _supportMs) {
        last = right.$2;
      } else if (rim != null) {
        last = rim;
      }
      targets.add(bound(last));
    }

    final deadZone = 2 * half * _deadZoneFraction;
    final forward = [...targets], backward = [...targets];
    for (var i = 1; i < times.length; i++) {
      forward[i] = forward[i - 1].clamp(
        targets[i] - deadZone,
        targets[i] + deadZone,
      );
    }
    for (var i = times.length - 2; i >= 0; i--) {
      backward[i] = backward[i + 1].clamp(
        targets[i] - deadZone,
        targets[i] + deadZone,
      );
    }
    final centers = <double>[];
    final observed = {for (final (time, x) in clean) time: x};
    final ballMargin = half * 2 * _ballMarginFraction;
    var lower = 0;
    for (var i = 0; i < times.length; i++) {
      while (times[lower] < times[i] - _smoothingRadiusMs) {
        lower++;
      }
      var weight = 0.0, center = 0.0;
      for (
        var j = lower;
        j < times.length && times[j] <= times[i] + _smoothingRadiusMs;
        j++
      ) {
        final distance = (times[j] - times[i]) / _smoothingMs;
        final w = math.exp(-.5 * distance * distance);
        weight += w;
        center += w * (forward[j] + backward[j]) / 2;
      }
      var smoothed = center / weight;
      if (observed[times[i]] case final ball?) {
        smoothed = smoothed.clamp(ball - ballMargin, ball + ballMargin);
      }
      centers.add(bound(smoothed));
    }
    final limited = _limitPan(times, centers, half * 2);
    final expectedSamples = ((endMs - startMs) / _samplePeriodMs).ceil();
    return PortraitPlan(
      keyframes: List.unmodifiable([
        for (var i = 0; i < times.length; i++)
          PortraitKeyframe(times[i], bound(limited[i]) / width),
      ]),
      trackingCoverage: math.min(1, clean.length / expectedSamples),
    );
  }

  static List<double> _limitPan(
    List<int> times,
    List<double> centers,
    double cropWidth,
  ) {
    final speed = cropWidth * _maxPanSpeed / 1000;
    final acceleration = cropWidth * _maxPanAcceleration / 1000000;
    final periods = [
      for (var i = 1; i < times.length; i++) times[i] - times[i - 1],
    ];
    final forward = [...centers], backward = [...centers];
    for (var i = 0; i < periods.length; i++) {
      final step = speed * periods[i];
      forward[i + 1] = centers[i + 1].clamp(
        forward[i] - step,
        forward[i] + step,
      );
    }
    for (var i = periods.length - 1; i >= 0; i--) {
      final step = speed * periods[i];
      backward[i] = centers[i].clamp(
        backward[i + 1] - step,
        backward[i + 1] + step,
      );
    }
    final path = [
      for (var i = 0; i < times.length; i++) (forward[i] + backward[i]) / 2,
    ];

    var minRate = 0.0, maxRate = 0.0, previousRate = 0.0;
    var needsSmoothing = false;
    for (var i = 0; i < periods.length; i++) {
      final rate = (path[i + 1] - path[i]) / periods[i];
      minRate = math.min(minRate, rate);
      maxRate = math.max(maxRate, rate);
      if (i > 0 &&
          (rate - previousRate).abs() >
              acceleration * (periods[i - 1] + periods[i]) / 2) {
        needsSmoothing = true;
      }
      previousRate = rate;
    }
    if (!needsSmoothing) return path;

    // Averaging the continuous, speed-limited path over a time window bounds
    // its acceleration by (maxRate - minRate) / windowMs. The integral uses
    // actual media timestamps, including short first and final intervals.
    final radius = (maxRate - minRate) / (2 * acceleration);
    final integral = [0.0];
    for (var i = 0; i < periods.length; i++) {
      integral.add(integral.last + (path[i] + path[i + 1]) * periods[i] / 2);
    }

    double areaAt(double time) {
      if (time <= times.first) return (time - times.first) * path.first;
      if (time >= times.last) {
        return integral.last + (time - times.last) * path.last;
      }
      var left = 0, right = times.length - 1;
      while (right - left > 1) {
        final middle = (left + right) ~/ 2;
        if (times[middle] <= time) {
          left = middle;
        } else {
          right = middle;
        }
      }
      final elapsed = time - times[left];
      final rate = (path[right] - path[left]) / periods[left];
      return integral[left] + elapsed * (path[left] + rate * elapsed / 2);
    }

    return [
      for (final time in times)
        (areaAt(time + radius) - areaAt(time - radius)) / (2 * radius),
    ];
  }

  static bool _valid(PortraitDetection box, double width, int height) =>
      box.cx >= 0 &&
      box.cx <= width &&
      box.cy >= 0 &&
      box.cy <= height &&
      box.w.isFinite &&
      box.h.isFinite &&
      box.conf.isFinite &&
      box.w > 0 &&
      box.h > 0;

  static double _observationRadius(double crop, int deltaMs) =>
      crop * math.min(.5, .12 + 2.2 * deltaMs / 1000);

  static bool _supportedObservation(
    List<(int, double)> track,
    int i,
    double crop,
  ) {
    final (t, x) = track[i];
    final hasNeighbour =
        [
          for (
            var j = math.max(0, i - 2);
            j < math.min(track.length, i + 3);
            j++
          )
            if (i != j) track[j],
        ].any((point) {
          final delta = (t - point.$1).abs();
          return delta <= _neighbourMs &&
              (x - point.$2).abs() <= _observationRadius(crop, delta);
        });
    if (!hasNeighbour || i == 0 || i == track.length - 1) return hasNeighbour;
    final (before, left) = track[i - 1];
    final (after, right) = track[i + 1];
    if (after - before > _neighbourMs) return true;
    final expected = left + (right - left) * (t - before) / (after - before);
    return (x - expected).abs() <= .35 * crop ||
        (left - right).abs() >= .25 * crop;
  }

  static double? _stableRim(
    Iterable<PortraitTrackSample> samples,
    double width,
    int height,
    double crop,
  ) {
    // Count distinct timestamps, so multiple overlapping detections in the
    // same frame do not establish a persistent rim on their own.
    final groups = <(PortraitDetection, Map<int, double>)>[];
    for (final sample in samples) {
      for (final rim in sample.rims) {
        if (!_valid(rim, width, height) ||
            rim.w / rim.h < .75 ||
            rim.w / rim.h > 6 ||
            rim.w < .008 * width ||
            rim.w > math.min(.12 * width, crop)) {
          continue;
        }
        final radius = math.min(.035 * width, math.max(.016 * width, rim.w));
        final group = groups.indexWhere((group) {
          final dx = rim.cx - group.$1.cx, dy = rim.cy - group.$1.cy;
          return dx * dx + dy * dy <= radius * radius;
        });
        if (group < 0) {
          groups.add((rim, {sample.tMs: rim.cx}));
        } else {
          groups[group].$2.putIfAbsent(sample.tMs, () => rim.cx);
        }
      }
    }
    Map<int, double>? best;
    for (final (_, positions) in groups) {
      if (positions.length > (best?.length ?? 0)) best = positions;
    }
    if (best == null ||
        best.length < math.max(3, (.025 * samples.length).ceil())) {
      return null;
    }
    final xs = best.values.toList()..sort();
    return (xs[(xs.length - 1) ~/ 2] + xs[xs.length ~/ 2]) / 2;
  }
}
