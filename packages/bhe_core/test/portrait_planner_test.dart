import 'package:bhe_core/bhe_core.dart';
import 'package:test/test.dart';

const _start = 12000;
const _end = 16000;
const _rim = PortraitDetection(cx: 1440, cy: 480, w: 80, h: 30, conf: .9);

PortraitPlan _plan(List<PortraitTrackSample> samples, {int width = 1920}) =>
    PortraitPlanner.plan(
      frameWidth: width,
      frameHeight: 1080,
      startMs: _start,
      endMs: _end,
      samples: samples,
    );

List<PortraitTrackSample> _track(
  double? Function(int) ball, {
  bool rim = true,
}) => [
  for (var i = 0; i < 40; i++)
    PortraitTrackSample(
      tMs: _start + i * 100,
      balls: [
        if (ball(i) case final x?)
          PortraitDetection(cx: x, cy: 490, w: 20, h: 20, conf: .9),
      ],
      rims: rim ? [_rim] : [],
    ),
];

void main() {
  test('follows a continuous track with original video timestamps', () {
    final plan = _plan(_track((i) => 420.0 + 24 * i));
    expect(plan.trackingCoverage, 1);
    expect(plan.hasBallTrack, isTrue);
    expect(plan.keyframes.first.tMs, _start);
    expect(plan.keyframes.last.tMs, _end);
    expect(plan.keyframes[2].cxNorm, lessThan(.36));
    expect(plan.keyframes[38].cxNorm, greaterThan(.63));
  });

  test('smooths gaps and isolated false detections without chasing them', () {
    final plan = _plan(
      _track((i) {
        if (i == 8) return 1800;
        if (i >= 10 && i < 13) return null;
        if (i >= 18 && i < 36) return null;
        return 500;
      }),
    );
    expect(plan.keyframes[8].cxNorm, closeTo(500 / 1920, .04));
    expect(plan.keyframes[11].cxNorm, closeTo(500 / 1920, .06));
    // A long gap still pans toward the rim, at the same bounded rate as
    // other moves, and turns back toward the ball when tracking resumes.
    expect(plan.keyframes[28].cxNorm, greaterThan(plan.keyframes[18].cxNorm));
    expect(plan.keyframes[28].cxNorm, greaterThan(.45));
    expect(plan.keyframes.last.cxNorm, lessThan(plan.keyframes[28].cxNorm));
    expect(plan.trackingCoverage, closeTo(.45, .001));
  });

  test('keeps the recent ball when a distant candidate ranks higher', () {
    final plan = _plan([
      for (var i = 0; i < 40; i++)
        PortraitTrackSample(
          tMs: _start + 13 + i * 100 + (i.isEven ? 0 : 7),
          balls: [
            PortraitDetection(
              cx: 450,
              cy: 490,
              w: 20,
              h: 20,
              conf: i ~/ 4 % 2 == 0 ? .9 : .7,
            ),
            PortraitDetection(
              cx: 1350,
              cy: 490,
              w: 20,
              h: 20,
              conf: i ~/ 4 % 2 == 0 ? .7 : .9,
            ),
          ],
          rims: [],
        ),
    ]);
    expect(plan.trackingCoverage, 1);
    expect(
      plan.keyframes.map((frame) => frame.cxNorm),
      everyElement(closeTo(450 / 1920, 1e-8)),
    );
  });

  test('limits speed and acceleration across unequal sample intervals', () {
    final plan = _plan([
      for (var i = 0; i < 40; i++)
        PortraitTrackSample(
          tMs: _start + 13 + i * 100 + (i.isEven ? 0 : 7),
          balls: [
            PortraitDetection(
              cx: i ~/ 4 % 2 == 0 ? 450 : 1350,
              cy: 490,
              w: 20,
              h: 20,
              conf: .9,
            ),
          ],
          rims: [],
        ),
    ]);
    final frames = plan.keyframes;
    final durations = [
      for (var i = 1; i < frames.length; i++)
        (frames[i].tMs - frames[i - 1].tMs) / 1000,
    ];
    const normPerCrop = (1080 * 9 / 16) / 1920;
    final velocities = [
      for (var i = 0; i < durations.length; i++)
        (frames[i + 1].cxNorm - frames[i].cxNorm) / normPerCrop / durations[i],
    ];
    expect(plan.hasBallTrack, isTrue);
    for (var i = 0; i < velocities.length; i++) {
      expect(velocities[i].abs(), lessThanOrEqualTo(.6 + 1e-8));
      if (i == 0) continue;
      final timeBetweenCenters = (durations[i - 1] + durations[i]) / 2;
      final acceleration =
          (velocities[i] - velocities[i - 1]).abs() / timeBetweenCenters;
      expect(acceleration, lessThanOrEqualTo(.8 + 1e-8));
    }
  });

  test('without a rim, a long gap retains the last framing target', () {
    final plan = _plan(_track((i) => i < 11 ? 1200 : null, rim: false));
    expect(plan.keyframes.last.cxNorm, closeTo(.625, .001));
    expect(plan.hasBallTrack, isTrue);
  });

  test('with no reliable ball, uses rim then screen center', () {
    final plan = _plan(_track((i) => i == 3 ? 600 : null));
    expect(plan.hasBallTrack, isFalse);
    expect(plan.trackingCoverage, 0);
    expect(
      plan.keyframes.every((frame) => (frame.cxNorm - .75).abs() < 1e-9),
      isTrue,
    );
    expect(_plan([]).keyframes.map((frame) => frame.cxNorm), [.5, .5]);
  });

  test('keeps crop windows inside the image at both edges', () {
    const half = 1080 * 9 / 16 / 2 / 1920;
    for (final x in [0.0, 1920.0]) {
      final plan = _plan(_track((i) => x));
      expect(plan.hasBallTrack, isTrue);
      for (final frame in plan.keyframes) {
        expect(frame.cxNorm, closeTo(x == 0 ? half : 1 - half, 1e-9));
      }
    }
    final portrait = _plan(_track((i) => 42, rim: false), width: 608);
    expect(portrait.keyframes.last.cxNorm, closeTo(.5, .001));
  });

  test('ignores samples outside the range and pins both time boundaries', () {
    final plan = _plan([
      const PortraitTrackSample(tMs: _start - 100, balls: [], rims: []),
      ..._track((i) => 650).skip(1).toList().reversed,
      const PortraitTrackSample(tMs: _end + 100, balls: [], rims: []),
    ]);
    final times = plan.keyframes.map((frame) => frame.tMs).toList();
    expect(times, [...times.toSet()]..sort());
    expect(times.first, _start);
    expect(times.last, _end);
    expect(plan.keyframes.first.cxNorm, closeTo(650 / 1920, .001));
  });
}
