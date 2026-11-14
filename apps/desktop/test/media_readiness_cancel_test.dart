import 'dart:async';

import 'package:desktop/features/review/media_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingDurationStream extends Stream<Duration> {
  CountingDurationStream(this.source);
  final Stream<Duration> source;
  int subscriptions = 0;

  @override
  StreamSubscription<Duration> listen(
    void Function(Duration)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    subscriptions++;
    return source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

// Control only the deadline; leave stream cancellation and microtasks real.
class ControlledDeadline implements Timer {
  ControlledDeadline(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() => isActive = false;
  void fire() {
    if (!isActive) return;
    isActive = false;
    tick++;
    callback();
  }
}

class WaitClock {
  final deadlines = <ControlledDeadline>[];
  Future<Duration> wait(Stream<Duration> updates, {Future<void>? cancelled}) =>
      runZoned(
        () => waitForPlayableDuration(
          current: Duration.zero,
          updates: updates,
          cancelled: cancelled,
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = ControlledDeadline(duration, callback);
            deadlines.add(timer);
            return timer;
          },
        ),
      );
}

void main() {
  test(
    'late NAS metadata keeps one subscription for the full budget',
    () async {
      final controller = StreamController<Duration>.broadcast();
      final stream = CountingDurationStream(controller.stream);
      final clock = WaitClock();
      final waiting = clock.wait(stream);
      expect(clock.deadlines.single.duration, const Duration(seconds: 45));
      controller.add(const Duration(seconds: 90));
      expect(await waiting, const Duration(seconds: 90));
      expect(stream.subscriptions, 1);
      expect(controller.hasListener, isFalse);
      expect(clock.deadlines.single.isActive, isFalse);
      await controller.close();
    },
  );

  test('timeout releases its one subscription and timer', () async {
    final controller = StreamController<Duration>.broadcast();
    final stream = CountingDurationStream(controller.stream);
    final clock = WaitClock();
    final expectation = expectLater(
      clock.wait(stream),
      throwsA(
        isA<MediaReadinessTimeout>().having(
          (value) => value.seconds,
          'total seconds',
          45,
        ),
      ),
    );
    clock.deadlines.single.fire();
    await expectation;
    expect(stream.subscriptions, 1);
    expect(controller.hasListener, isFalse);
    expect(clock.deadlines.single.isActive, isFalse);
    await controller.close();
  });

  test('positive duration releases the subscription immediately', () async {
    final controller = StreamController<Duration>.broadcast();
    final clock = WaitClock();
    final waiting = clock.wait(controller.stream);
    controller.add(const Duration(seconds: 9));
    expect(await waiting, const Duration(seconds: 9));
    expect(controller.hasListener, isFalse);
    expect(clock.deadlines.single.isActive, isFalse);
    await controller.close();
  });

  test('stream errors also release subscription and timer', () async {
    final controller = StreamController<Duration>.broadcast();
    final clock = WaitClock();
    final expectation = expectLater(
      clock.wait(controller.stream),
      throwsStateError,
    );
    controller.addError(StateError('media closed'));
    await expectation;
    expect(controller.hasListener, isFalse);
    expect(clock.deadlines.single.isActive, isFalse);
    await controller.close();
  });

  for (final reason in [
    'source switch',
    'page disposal',
    'generation change',
  ]) {
    test('$reason frees the old media queue immediately', () async {
      final controller = StreamController<Duration>.broadcast();
      final cancelled = Completer<void>();
      final clock = WaitClock();
      var retired = false;
      var staleStateWritten = false;
      var nextActionRan = false;
      Object? error;
      final oldAction = clock
          .wait(controller.stream, cancelled: cancelled.future)
          .then<void>(
            (_) {
              if (!retired) staleStateWritten = true;
            },
            onError: (Object value) {
              error = value;
            },
          );
      final queue = oldAction.then((_) => nextActionRan = true);
      retired = true;
      cancelled.complete();
      await queue;
      expect(error, isA<MediaReadinessCancelled>());
      expect(nextActionRan, isTrue);
      expect(staleStateWritten, isFalse);
      expect(controller.hasListener, isFalse);
      expect(clock.deadlines.single.isActive, isFalse);
      expect(clock.deadlines.single.tick, 0);
      controller.add(const Duration(seconds: 99));
      await controller.close();
      expect(staleStateWritten, isFalse);
    });
  }

  test(
    'already cancelled wait cleans up without firing its deadline',
    () async {
      final controller = StreamController<Duration>.broadcast();
      final cancelled = Completer<void>()..complete();
      final clock = WaitClock();
      await expectLater(
        clock.wait(controller.stream, cancelled: cancelled.future),
        throwsA(isA<MediaReadinessCancelled>()),
      );
      expect(controller.hasListener, isFalse);
      expect(clock.deadlines.single.isActive, isFalse);
      expect(clock.deadlines.single.tick, 0);
      await controller.close();
    },
  );
}
