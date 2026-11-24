import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

const clips = [
  Candidate(
    id: 'goal',
    startMs: 0,
    endMs: 2000,
    eventMs: 1000,
    reviewed: true,
    players: ['Alice', 'Bob'],
  ),
  Candidate(
    id: 'first',
    startMs: 2100,
    endMs: 4100,
    eventMs: 3100,
    players: ['Alice'],
    rimCheck: {'status': 'made'},
  ),
  Candidate(
    id: 'fold1',
    startMs: 4200,
    endMs: 6200,
    eventMs: 5200,
    players: ['Bob'],
    rimCheck: {'status': 'unsure'},
  ),
  Candidate(id: 'fold2', startMs: 6300, endMs: 8300, eventMs: 7300),
  Candidate(
    id: 'miss',
    startMs: 8400,
    endMs: 9900,
    eventMs: 9400,
    rimCheck: {'status': 'rejected'},
  ),
];

class _FoldedState extends MobileAppState {
  _FoldedState() : super(videoProbe: MobileVideoFixture.inspect);
  @override
  Set<String> get likelyMissCandidateIds => const {'fold1', 'fold2'};
}

class _VisualVideoPlatform extends FakeVideoPlatform {
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Color(0xFF17332E));
}

void assertEnglishWidgets(WidgetTester tester) {
  final chinese = RegExp(r'[\u3400-\u9FFF]');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    expect(text.data ?? text.textSpan?.toPlainText(), isNot(matches(chinese)));
  }
}

Future<void> settleVideo(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 18)),
    );
    await tester.pump(const Duration(milliseconds: 90));
  }
}

Future<void> openReview(WidgetTester tester) async {
  final l10n = Localizations.of<BheLocalizations>(
    tester.element(find.byType(Scaffold).first),
    BheLocalizations,
  )!;
  final review = find.text(l10n.reviewCount(clips.length));
  await tester.ensureVisible(review);
  await tester.pump();
  await tester.tap(review);
  await settleVideo(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['BHE_L513_CAPTURE_DIR'];
  final font = Platform.environment['BHE_L513_CAPTURE_FONT'];

  setUpAll(() async {
    if (font == null) return;
    await (FontLoader(
      'Inter',
    )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(
          rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  late MobileVideoFixture fixture;
  late VideoPlayerPlatform previousVideo;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
    previousVideo = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _VisualVideoPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() async {
    VideoPlayerPlatform.instance = previousVideo;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await fixture.close();
  });

  for (final screen in ['portrait-review', 'landscape-review', 'export']) {
    testWidgets('$screen layout', (tester) async {
      final locale = screen == 'portrait-review' ? 'zh' : 'en';
      tester.binding.platformDispatcher.localeTestValue = Locale(locale);
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      await tester.binding.setSurfaceSize(
        screen == 'export' ? const Size(390, 844) : const Size(360, 700),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final file = await tester.runAsync(
        () => fixture.file('original.mp4', 'original'),
      );
      fixture.state.project = fixture
          .project(file!.path)
          .copyWith(candidates: clips);
      final root = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: root,
          child: BheMobileApp(appState: fixture.state),
        ),
      );
      await tester.pump();
      if (screen == 'export') {
        await tester.tap(find.byTooltip('Export').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('Will export 4 clips'), findsOneWidget);
      } else {
        await openReview(tester);
        if (screen == 'landscape-review') {
          await tester.tap(find.byTooltip('Landscape full screen'));
          await tester.binding.setSurfaceSize(const Size(800, 360));
          await settleVideo(tester);
          expect(find.byKey(const Key('review-player-filter')), findsNothing);
          expect(find.text('Uncertain\n3'), findsOneWidget);
        }
        expect(find.byKey(const Key('review-fold-toggle')), findsNothing);
        expect(find.text('#2  0:03'), findsOneWidget);
        expect(tester.getRect(find.text('#2  0:03')).bottom, lessThan(360));
      }
      if (locale == 'en') assertEnglishWidgets(tester);
      expect(tester.takeException(), isNull);
      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File(
            '$output/$screen.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
    });
  }

  testWidgets('folded confirmation, filtering, and one-step undo in English', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      fixture.state.dispose();
      fixture.state = _FoldedState();
      await fixture.state.ready;
      final file = await fixture.file('original.mp4', 'original');
      fixture.state.project = fixture
          .project(file.path)
          .copyWith(candidates: clips);
    });
    await tester.pumpWidget(BheMobileApp(appState: fixture.state));
    await tester.pump();
    await openReview(tester);
    final bulk = find.byKey(const Key('review-fold-mark-all'));
    expect(find.text('Uncertain\n1'), findsOneWidget);
    expect(find.text('#3  0:05'), findsNothing);
    await tester.tap(find.byKey(const Key('review-player-filter')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('review-player-option-player:Alice')),
    );
    await tester.pumpAndSettle();
    assertEnglishWidgets(tester);
    await tester.tap(find.byKey(const Key('review-apply-filters')));
    await tester.pumpAndSettle();
    expect(bulk, findsNothing);
    expect(find.text('Uncertain\n1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review-player-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    await tester.tap(bulk);
    await tester.pumpAndSettle();
    expect(find.text('Mark 2 clips as missed?'), findsOneWidget);
    assertEnglishWidgets(tester);
    await tester.tap(find.text('Take a look first'));
    await tester.pumpAndSettle();
    expect(find.text('#3  0:05'), findsOneWidget);
    expect(fixture.state.reviewHistory.allEntries, isEmpty);
    await tester.tap(bulk);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review-fold-confirm')));
    await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-fold-notice')), findsOneWidget);
    expect(fixture.state.reviewHistory.allEntries.length, 1);

    await tester.tap(find.byKey(const Key('review-filter-excluded')));
    await tester.pumpAndSettle();
    expect(find.text('Restore as goal'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-undo-bottom')));
    await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
    await tester.pumpAndSettle();
    expect(fixture.state.canUndoReview, isFalse);
    expect(find.text('#3  0:05'), findsOneWidget);
    expect(bulk, findsOneWidget);
    assertEnglishWidgets(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
  });
}
