import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/core/video_orientation.dart';
import 'package:desktop/providers/playback_coordinator.dart';

PlaybackCoordinator _coordinator({
  Duration timeout = const Duration(seconds: 10),
  Future<void> Function()? nextFrame,
}) => PlaybackCoordinator(
  prepareTimeout: timeout,
  nextFrame: nextFrame ?? () async {},
);

void main() {
  test('hides video surfaces while the native dialog is open', () async {
    final coordinator = _coordinator();
    final events = <String>[];
    final result = await coordinator.withNativeDialog(() async {
      events.add('dialog hidden=${videoSurfaceHidden.value}');
      expect(coordinator.dialogActive, isTrue);
      return 'path';
    });
    expect(result, 'path');
    expect(events, ['dialog hidden=true']);
    expect(videoSurfaceHidden.value, isFalse);
    expect(coordinator.dialogActive, isFalse);
  });

  test('rejects overlapping dialogs and unlocks after cancellation', () async {
    final coordinator = _coordinator();
    final selected = Completer<String?>();
    final first = coordinator.withNativeDialog(() => selected.future);
    await expectLater(
      coordinator.withNativeDialog(() async => 'duplicate'),
      throwsStateError,
    );
    selected.complete(null);
    expect(await first, isNull);
    expect(await coordinator.withNativeDialog(() async => 'retry'), 'retry');
  });

  test('stuck frame still opens the dialog after the timeout', () async {
    final stuck = Completer<void>();
    final coordinator = _coordinator(
      timeout: const Duration(milliseconds: 10),
      nextFrame: () => stuck.future,
    );
    var timedOut = false;
    var shown = false;
    await coordinator.withNativeDialog(
      () async => shown = true,
      onPrepareTimeout: () => timedOut = true,
    );
    expect(timedOut, isTrue);
    expect(shown, isTrue);
    expect(videoSurfaceHidden.value, isFalse);
    expect(coordinator.dialogActive, isFalse);
  });

  test('native dialog error releases the guard and shows video again', () async {
    final coordinator = _coordinator();
    await expectLater(
      coordinator.withNativeDialog(() async {
        throw StateError('dialog failed');
      }),
      throwsStateError,
    );
    expect(videoSurfaceHidden.value, isFalse);
    expect(coordinator.dialogActive, isFalse);
  });
}
