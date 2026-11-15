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

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
    seeks.add(position);
  }
}

void main() {
  testWidgets(
    'filter switch follows selected start or active playhead and seeks nearest',
    (tester) async {
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
                    selection: i.isOdd
                        ? CandidateSelection.excluded
                        : CandidateSelection.included,
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
        await tester.tap(find.byKey(const Key('review-filter-included')));
        await _reviewFrames(tester);
        final last = find.text('#5  0:08');
        await tester.scrollUntilVisible(
          last,
          150,
          scrollable: find.byType(Scrollable).last,
        );
        await _reviewFrames(tester);
        await tester.tap(last);
        await _reviewFrames(tester);
        expect(platform.seeks.last.inMilliseconds, 8000);
        await tester.tap(find.byTooltip(l10n.text('暂停')));
        await _reviewFrames(tester);
        await tester.tap(find.byKey(const Key('review-filter-excluded')));
        await _reviewFrames(tester);
        expect(platform.seeks.last.inMilliseconds, 6000);
        await tester.tap(find.byKey(const Key('review-filter-all')));
        await _reviewFrames(tester);
        expect(platform.seeks.last.inMilliseconds, 6000);
        await tester.tap(find.byKey(const Key('review-filter-included')));
        await _reviewFrames(tester);
        expect(
          platform.seeks.last.inMilliseconds,
          4000,
          reason: 'equal distance chooses earlier',
        );
        await tester.scrollUntilVisible(
          last,
          150,
          scrollable: find.byType(Scrollable).last,
        );
        await _reviewFrames(tester);
        await tester.tap(last);
        await _reviewFrames(tester);
        platform.position = const Duration(milliseconds: 2500);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-filter-excluded')));
        await _reviewFrames(tester);
        expect(
          platform.seeks.last.inMilliseconds,
          2000,
          reason: 'playing position overrides selected start',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = originalPlatform;
        await tester.runAsync(() => fixture.close());
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}

Future<void> _reviewFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
