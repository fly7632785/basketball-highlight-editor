import 'dart:async';
import 'dart:io';

import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/features/home/home_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_advance_playback_test.dart' show MemoryPlayback;
import 'tiers_ui_test.dart' as harness;

class OpeningProject extends harness.FakeProject {
  Completer<void>? hydration;
  Future<void> stageOpen() async {
    state = state.copyWith(
      reviewSessionRevision: state.reviewSessionRevision + 1,
      candidates: [],
      hydrating: true,
    );
    hydration = Completer<void>();
    unawaited(
      hydration!.future.then((_) {
        state = state.copyWith(
          candidates: harness.fixture().candidates,
          hydrating: false,
        );
      }),
    );
  }

  @override
  Future<bool> openProject(
    String root, {
    String? relinkVideoButtonLabel,
    String? videoTypeLabel,
  }) async {
    await stageOpen();
    return true;
  }

  @override
  Future<bool> chooseOpenProject({
    String? openProjectButtonLabel,
    String? relinkVideoButtonLabel,
    String? videoTypeLabel,
  }) => openProject('/synthetic');
  @override
  Future<bool> startNewProject() async {
    await stageOpen();
    return true;
  }
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      onboardingStepsPrefsKey: allOnboardingStepIds,
      'courtside.sidebar_extended': false,
    }),
  );
  for (final warm in [false, true]) {
    for (final entry in ['recent', 'file picker', 'new', 'switch in review']) {
      testWidgets('$entry warm=$warm: async first candidates position paused', (
        tester,
      ) async {
        final dir = Directory.systemTemp.createTempSync('bhe-open-playback-');
        final file = File('${dir.path}/video.mp4')..writeAsBytesSync([0]);
        addTearDown(() => dir.deleteSync(recursive: true));
        final n = OpeningProject();
        n.initial = harness.fixture().copyWith(
          video: {'id': 'v1', 'source_path': file.path},
          videoPath: file.path,
          reviewVideoPath: file.path,
          candidates: [],
          recentProjects: const [
            {
              'project_root': '/synthetic',
              'project': {'name': 'Opening fixture'},
            },
          ],
        );
        final p = MemoryPlayback();
        final app = await harness.pump(
          tester,
          n,
          reviewScreen: ReviewScreen(playbackPlayer: Player(platformPlayer: p)),
          homeBuilder: (context) =>
              HomeScreen(onProjectOpened: () => context.go('/review')),
        );
        if (warm) {
          await n.stageOpen();
          n.hydration!.complete();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(p.state.playing, isTrue);
          expect(p.state.position, const Duration(seconds: 36));
        }
        if (entry != 'switch in review') {
          app.router.go('/home');
          await tester.pumpAndSettle();
          if (entry == 'recent') {
            await tester.tap(find.text('Opening fixture'));
          } else if (entry == 'file picker') {
            // Same chooseOpenProject path as the file picker, without a native dialog.
            await tester.tap(find.text('打开项目').first);
          } else {
            await tester.tap(find.text('新建项目').first);
          }
          await tester.pumpAndSettle();
          if (entry == 'new') app.router.go('/review');
        } else {
          await n.openProject('/other');
        }
        await tester.pumpAndSettle();
        expect(p.state.playing, isFalse);
        n.hydration!.complete();
        await tester.pumpAndSettle();
        expect(find.text('候选 00:36'), findsOneWidget);
        expect(p.state.position, const Duration(seconds: 27));
        expect(
          p.state.playing,
          isFalse,
          reason: 'Hydration is not a user playback request',
        );
        await tester.tap(find.byKey(const ValueKey('tier-dot-c4')));
        await tester.pumpAndSettle();
        expect(p.state.playing, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(
          p.state.playing,
          isTrue,
          reason: 'Explicit candidate switching still plays',
        );
      });
    }
  }
  testWidgets(
    'same-project reopen coalesced before a frame resets selection and old play intent',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('bhe-reopen-');
      final file = File('${dir.path}/video.mp4')..writeAsBytesSync([0]);
      addTearDown(() => dir.deleteSync(recursive: true));
      final n = OpeningProject();
      n.initial = harness.fixture().copyWith(
        video: {'id': 'v1', 'source_path': file.path},
        videoPath: file.path,
        reviewVideoPath: file.path,
      );
      final p = MemoryPlayback();
      await harness.pump(
        tester,
        n,
        reviewScreen: ReviewScreen(playbackPlayer: Player(platformPlayer: p)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(p.state.playing, isTrue);
      await n.openProject('/same');
      n.hydration!.complete();
      // No intermediate pump: Riverpod's empty and hydrated updates share one frame.
      await tester.pumpAndSettle();
      expect(find.text('候选 00:36'), findsOneWidget);
      expect(p.state.position, const Duration(seconds: 27));
      expect(p.state.playing, isFalse);
    },
  );
}
