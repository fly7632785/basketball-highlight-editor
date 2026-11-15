import 'dart:async';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

class _PositionVideoPlatform extends FakeVideoPlatform {
  Duration position = Duration.zero;
  final seeks = <Duration>[];
  bool playing = false;

  @override
  Future<void> play(int playerId) async {
    playing = true;
  }

  @override
  Future<void> pause(int playerId) async {
    playing = false;
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
    seeks.add(position);
  }
}

void main() {
  for (final unmount in [false, true]) {
    testWidgets('rapid filter change to empty stays safe unmount=$unmount', (
      tester,
    ) async {
      final fixture = MobileVideoFixture();
      await tester.runAsync(() => fixture.init());
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _PositionVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      await tester.binding.setSurfaceSize(const Size(400, 900));
      try {
        final file = (await tester.runAsync(
          () => fixture.file('original.mp4', 'original'),
        ))!;
        fixture.state.project = fixture
            .project(file.path)
            .copyWith(
              candidates: [
                for (var i = 0; i < 5; i++)
                  Candidate(
                    id: 'position-$i',
                    startMs: i * 2000,
                    endMs: i * 2000 + 1000,
                    eventMs: i * 2000,
                    selection: CandidateSelection.included,
                  ),
              ],
            );
        await tester.pumpWidget(BheMobileApp(appState: fixture.state));
        await tester.pump();
        final l10n = Localizations.of<BheLocalizations>(
          tester.element(find.byType(Scaffold).first),
          BheLocalizations,
        )!;
        final review = find.text(l10n.reviewCount(5));
        await tester.ensureVisible(review);
        await _reviewFrames(tester);
        await tester.tap(review);
        await tester.runAsync(() => pumpEventQueue());
        await _reviewFrames(tester);
        expect(platform.playing, isTrue);
        await tester.tap(find.byKey(const Key('review-filter-included')));
        // Both filter callbacks arrive before Flutter renders the next frame.
        await tester.tap(find.byKey(const Key('review-filter-excluded')));
        if (unmount) await tester.pumpWidget(const SizedBox());
        await _reviewFrames(tester);
        expect(tester.takeException(), isNull);
        if (!unmount) {
          expect(platform.playing, isFalse);
          expect(find.text('#1  0:00'), findsNothing);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = originalPlatform;
        await tester.runAsync(() => fixture.close());
        await tester.binding.setSurfaceSize(null);
      }
    });
  }
}

Future<void> _reviewFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
