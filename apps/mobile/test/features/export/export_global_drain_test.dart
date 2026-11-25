import 'dart:async';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:bhe_mobile/features/export/export_modes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/export_settings_actions.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  late MobileVideoFixture f;
  var closed = false;
  setUp(() {
    closed = false;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (!closed) await f.close();
  });
  for (final oldMerge in [true, false]) {
    test(
      'mixed exports wait for ${oldMerge ? 'merge' : 'separate'} to drain',
      () async {
        f = MobileVideoFixture();
        await f.init();
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        final entered = Completer<void>(), release = Completer<Object?>();
        var active = 0, maxActive = 0, calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'registerMergeExport') return true;
              if (call.method == 'mergeClips' || call.method == 'exportClip') {
                calls++;
                active++;
                if (active > maxActive) maxActive = active;
                if (calls == 1) {
                  if (!entered.isCompleted) entered.complete();
                  try {
                    return await release.future;
                  } finally {
                    active--;
                  }
                }
                active--;
                return {
                  'outputPath': (call.arguments as Map)['outputPath'],
                  'committed': true,
                };
              }
              return null;
            });
        final old = oldMerge ? f.state.mergeClips() : f.state.exportClips();
        await entered.future;
        await f.state.createNewProject();
        f.state.project = f.project(file.path, id: 'B');
        final next = oldMerge ? f.state.exportClips() : f.state.mergeClips();
        for (
          var attempt = 0;
          attempt < 100 && f.state.progressMessage != '正在结束上一次导出';
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(calls, 1);
        expect(f.state.progressMessage, '正在结束上一次导出');
        release.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
        await old;
        await next;
        expect(calls, 2);
        expect(maxActive, 1);
      },
    );
  }
  test(
    'wait timeout and cancellation escape without bypassing the native gate',
    () async {
      f = MobileVideoFixture();
      await f.init(
        exportEngine: NativeMediaExportEngine(
          drainTimeout: const Duration(milliseconds: 40),
        ),
        exportCancelTimeout: const Duration(milliseconds: 30),
        exportDrainTimeout: const Duration(milliseconds: 50),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      final entered = Completer<void>(),
          release = Completer<Object?>(),
          cancelReply = Completer<void>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'cancelExport') {
              await cancelReply.future;
              return null;
            }
            if (call.method == 'mergeClips') {
              if (++calls == 1) {
                if (!entered.isCompleted) entered.complete();
                return release.future;
              }
              return {'outputPath': 'new.mp4', 'committed': true};
            }
            return null;
          });
      final old = f.state.mergeClips();
      await entered.future;
      await f.state.cancelExport();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(f.state.exporting, isFalse);
      expect(f.state.diagnosticError, isNotNull);
      await f.state.mergeClips();
      expect(calls, 1);
      expect(f.state.errorMessage, '上一次导出尚未结束，请稍后重试。');
      release.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      cancelReply.complete();
      await old;
      await pumpEventQueue();
      await f.state.mergeClips();
      expect(calls, 2);
    },
  );
  test(
    'cancelling a queued run leaves the previous native task alone',
    () async {
      f = MobileVideoFixture();
      await f.init();
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      final entered = Completer<void>(), release = Completer<Object?>();
      var calls = 0, cancels = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'cancelExport') cancels++;
            if (call.method == 'mergeClips') {
              calls++;
              entered.complete();
              return release.future;
            }
            return null;
          });
      final old = f.state.mergeClips();
      await entered.future;
      await f.state.createNewProject();
      f.state.project = f.project(file.path, id: 'B');
      final next = f.state.mergeClips();
      for (
        var attempt = 0;
        attempt < 100 && f.state.progressMessage != '正在结束上一次导出';
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(f.state.progressMessage, '正在结束上一次导出');
      await f.state.cancelExport();
      await next;
      expect(calls, 1);
      expect(cancels, 1);
      release.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await old;
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets('preflight status is visible: $language', (tester) async {
      f = MobileVideoFixture();
      await tester.runAsync(() => f.init());
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = Locale(language);
      try {
        await tester.runAsync(() async {
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
        });
        f.state.exportRequest = MobileExportRequest(
          scope: ExportScope.all,
          mode: MobileOutputMode.clips,
          framing: ExportFraming.original,
          candidates: f.state.project.candidates,
        );
        f.state.exporting = true;
        f.state.progressMessage = '正在检查视频';
        f.state.progress = 0;
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        await tester.tap(find.byTooltip(language == 'zh' ? '导出' : 'Export'));
        await tester.pump();
        await tester.tap(
          find.text(language == 'zh' ? '查看进度' : 'View progress'),
        );
        await settleExportRoute(tester);
        final label = language == 'zh' ? '正在检查视频' : 'Checking video';
        expect(find.text(label), findsOneWidget);
        f.state.progressMessage = '正在结束上一次导出';
        f.state.notifyListeners();
        await tester.pump();
        expect(
          find.text(
            language == 'zh' ? '等上一次导出结束' : 'Waiting for the previous export',
          ),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '取消等待' : 'Stop waiting'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.binding.platformDispatcher.clearLocaleTestValue();
        VideoPlayerPlatform.instance = previous;
        await tester.runAsync(() => f.close());
        closed = true;
      }
    });
  }
}
