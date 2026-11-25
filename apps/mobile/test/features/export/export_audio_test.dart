import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/features/diagnostics/diagnostic_report.dart';
import 'package:bhe_mobile/features/diagnostics/friendly_error.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/mobile_ui.dart';
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
  var skipAudio = true;
  setUp(() {
    skipAudio = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (!['exportClip', 'mergeClips'].contains(call.method)) return null;
          final output = (call.arguments as Map)['outputPath'];
          return skipAudio
              ? {
                  'outputPath': output,
                  'mergedOverlapCount': call.method == 'mergeClips' ? 2 : null,
                  'skippedAudioTracks': [
                    {'index': 1, 'mime': 'audio/apac'},
                  ],
                }
              : output;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  const video = VideoInfo(
    path: 'source.mp4',
    name: 'source',
    sizeBytes: 10,
    durationMs: 10000,
    width: 1920,
    height: 1080,
  );
  const candidates = [
    Candidate(id: 'goal', startMs: 0, endMs: 1000, eventMs: 500),
  ];
  test(
    'last-clip failure keeps its native phase and source boundary in feedback',
    () async {
      final clips = [
        for (var index = 1; index <= 9; index++)
          Candidate(
            id: 'clip-$index',
            startMs: index == 9 ? 9800 : index * 1000,
            endMs: index == 9 ? 10200 : index * 1000 + 300,
            eventMs: index == 9 ? 9983 : index * 1000 + 100,
          ),
      ];
      const details = {
        'operation': 'exportClip',
        'stage': 'finish_muxer',
        'clip_index': 9,
        'clip_requested_start_us': 9800000,
        'clip_end_us': 10200000,
        'event_ms': 9983,
        'duration_ms': 10000,
        'native_error': 'java.lang.IllegalStateException',
      };
      final calls = <Map>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map;
            calls.add(args);
            if (args['exportId'] == 'clip-9') {
              throw PlatformException(
                code: 'EXPORT_FAILED',
                message: 'Failed to stop the muxer',
                details: details,
              );
            }
            return args['outputPath'];
          });

      final completed = <String>[];
      MobileDiagnosticException? failure;
      try {
        await for (final update in NativeMediaExportEngine().exportClips(
          video: video,
          candidates: clips,
          outputDirectory: 'out',
        )) {
          if (update.outputPath case final path?) completed.add(path);
        }
      } on MobileDiagnosticException catch (error) {
        failure = error;
      }
      expect(completed, hasLength(8));
      expect(calls.last, containsPair('clipIndex', 9));
      expect(calls.last, containsPair('sourceDurationMs', 10000));
      expect(calls.last, containsPair('eventMs', 9983));
      expect(calls.last, containsPair('endMs', 10200));
      final cause = failure!.cause as PlatformException;
      expect(cause.code, 'EXPORT_FAILED');
      final report = await buildMobileDiagnosticReport(
        MobileDiagnostics(),
        error: DiagnosticErrorRecord(cause, null, failure.operation),
        text: (text) => text,
      );
      for (final field in details.entries) {
        expect(report, contains('${field.key}: ${field.value}'));
      }
      expect(report, contains('Failed to stop the muxer'));
    },
  );

  for (final merge in [false, true]) {
    test(
      '${merge ? "merged" : "individual"} export returns skipped track metadata and accepts legacy string results',
      () async {
        final engine = NativeMediaExportEngine();
        Future<List<ExportProgress>> run() =>
            (merge
                    ? engine.mergeClips(
                        video: video,
                        candidates: candidates,
                        outputPath: 'out.mp4',
                      )
                    : engine.exportClips(
                        video: video,
                        candidates: candidates,
                        outputDirectory: 'out',
                      ))
                .toList();
        final result = (await run()).last;
        expect(result.mergedOverlapCount, merge ? 2 : null);
        expect(result.skippedAudioTracks.single.index, 1);
        expect(result.skippedAudioTracks.single.mime, 'audio/apac');
        skipAudio = false;
        final legacy = (await run()).last;
        expect(legacy.skippedAudioTracks, isEmpty);
        expect(legacy.mergedOverlapCount, isNull);
      },
    );
  }

  testWidgets(
    'successful export visibly warns about discarded audio and next export clears it',
    (tester) async {
      final fixture = MobileVideoFixture();
      await tester.runAsync(() => fixture.init());
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      try {
        await tester.runAsync(() async {
          final source = await fixture.file('original.mp4', 'original');
          fixture.state.project = fixture.project(source.path);
          await fixture.state.exportClips();
        });
        expect(fixture.state.exportAudioSkipped, isTrue);
        await tester.pumpWidget(BheMobileApp(appState: fixture.state));
        await tester.pump();
        await tester.tap(find.byTooltip('导出'));
        await settleExportRoute(tester);
        await settleExportRoute(tester);
        await tester.scrollUntilVisible(find.text('导出成功，部分音轨无法保留'), 300);
        expect(find.text('导出成功，部分音轨无法保留'), findsOneWidget);
        skipAudio = false;
        await tester.runAsync(() => fixture.state.mergeClips());
        await tester.pump();
        expect(fixture.state.exportAudioSkipped, isFalse);
        expect(find.text('导出成功，部分音轨无法保留'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
        await tester.runAsync(() => fixture.close());
      }
    },
  );
  for (final language in ['zh', 'en']) {
    testWidgets(
      'merge count and skipped audio appear together and reset: $language',
      (tester) async {
        final fixture = MobileVideoFixture();
        await tester.runAsync(() => fixture.init());
        final previous = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = FakeVideoPlatform();
        tester.binding.platformDispatcher.localeTestValue = Locale(language);
        await tester.binding.setSurfaceSize(const Size(360, 800));
        try {
          await tester.runAsync(() async {
            final source = await fixture.file('original.mp4', 'original');
            fixture.state.project = fixture.project(source.path);
            await fixture.state.mergeClips();
          });
          await tester.pumpWidget(BheMobileApp(appState: fixture.state));
          await tester.pump();
          final l10n = Localizations.of<BheLocalizations>(
            tester.element(find.byType(Scaffold).first),
            BheLocalizations,
          )!;
          await tester.tap(find.byTooltip(l10n.text('导出')));
          await settleExportRoute(tester);
          await settleExportRoute(tester);
          final message = language == 'zh'
              ? '合并后减少了 2 个片段'
              : 'Merging reduced the clip count by 2.';
          await tester.scrollUntilVisible(find.text(message), 300);
          expect(find.text(message), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text(l10n.text('导出成功，部分音轨无法保留')),
            300,
          );
          expect(find.text(l10n.text('导出成功，部分音轨无法保留')), findsOneWidget);
          skipAudio = false;
          await tester.runAsync(() => fixture.state.mergeClips());
          await tester.pump();
          expect(fixture.state.exportMergedOverlapCount, isNull);
          expect(find.text(message), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => pumpEventQueue());
          VideoPlayerPlatform.instance = previous;
          tester.binding.platformDispatcher.clearLocaleTestValue();
          await tester.binding.setSurfaceSize(null);
          await tester.runAsync(() => fixture.close());
        }
      },
    );
  }
}
