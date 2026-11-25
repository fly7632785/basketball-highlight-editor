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

class _LandscapeTagVideoPlatform extends _VisualVideoPlatform {
  bool playing = false;
  Duration position = Duration.zero;
  final seeks = <Duration>[];

  @override
  Future<void> play(int playerId) async => playing = true;

  @override
  Future<void> pause(int playerId) async => playing = false;

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Future<void> seekTo(int playerId, Duration next) async {
    position = next;
    seeks.add(next);
  }
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

Future<void> openReview(WidgetTester tester, int count) async {
  final l10n = Localizations.of<BheLocalizations>(
    tester.element(find.byType(Scaffold).first),
    BheLocalizations,
  )!;
  final review = find.text(l10n.reviewCount(count));
  await tester.ensureVisible(review);
  await tester.pump();
  await tester.tap(review);
  await settleVideo(tester);
}

Future<void> capture(WidgetTester tester, GlobalKey root, String path) async {
  await tester.runAsync(() async {
    final boundary =
        root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(path).writeAsBytes(png!.buffer.asUint8List());
  });
}

Future<GlobalKey> openCandidateRow(
  WidgetTester tester,
  MobileVideoFixture fixture,
  Candidate candidate, {
  List<Candidate> others = const [],
  Locale locale = const Locale('zh'),
  List<String> players = const ['科比', '乔丹'],
}) async {
  tester.binding.platformDispatcher.localeTestValue = locale;
  addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
  await tester.binding.setSurfaceSize(const Size(360, 780));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final file = await tester.runAsync(
    () => fixture.file('original.mp4', 'original'),
  );
  fixture.state.project = fixture
      .project(file!.path)
      .copyWith(candidates: [candidate, ...others], players: players);
  final root = GlobalKey();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: root,
      child: BheMobileApp(appState: fixture.state),
    ),
  );
  await tester.pump();
  await openReview(tester, 1 + others.length);
  return root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['BHE_L513_CAPTURE_DIR'];
  final rowOutput = Platform.environment['BHE_L515_CAPTURE_DIR'];
  final multiTagOutput = Platform.environment['BHE_L517_CAPTURE_DIR'];
  final landscapeTagOutput = Platform.environment['BHE_L518_CAPTURE_DIR'];
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
        await openReview(tester, clips.length);
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
        await capture(tester, root, '$output/$screen.png');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
    });
  }

  testWidgets('candidate row separates the rim status and player chip', (
    tester,
  ) async {
    final root = await openCandidateRow(
      tester,
      fixture,
      clips[1].copyWith(player: '科比'),
    );
    final status = tester.getRect(find.text('通过'));
    final chip = tester.getRect(
      find.ancestor(
        of: find.text('科比'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.padding ==
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        ),
      ),
    );
    expect(
      chip.left - status.right >= 4 || chip.top - status.bottom >= 4,
      isTrue,
      reason: 'The chip needs a gap from the pass status.',
    );
    if (rowOutput != null) {
      await capture(tester, root, '$rowOutput/portrait-review.png');
    }
  });

  testWidgets('tagging a candidate keeps its pass status in place', (
    tester,
  ) async {
    await openCandidateRow(
      tester,
      fixture,
      clips[1].copyWith(clearPlayer: true),
    );
    final status = find.text('通过');
    final before = tester.getTopLeft(status);
    await tester.tap(find.byTooltip('球员标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-select-科比')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('apply-candidate-tags')));
    await tester.pumpAndSettle();
    await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
    expect(fixture.state.project.candidates.single.player, '科比');
    expect(find.text('科比'), findsOneWidget);
    expect(tester.getTopLeft(status), before);
  });

  testWidgets('a confirmed goal shows the human decision on its row', (
    tester,
  ) async {
    final root = await openCandidateRow(tester, fixture, clips[2]);
    expect(find.text('未确认'), findsOneWidget);
    await tester.tap(find.text('选中'));
    await tester.pumpAndSettle();
    await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
    await tester.tap(find.byKey(const Key('review-filter-included')));
    await tester.pumpAndSettle();
    final goal = fixture.state.project.candidates.single;
    expect(goal.reviewed, isTrue);
    expect(goal.selection, CandidateSelection.included);
    expect(goal.rimCheckStatus, 'unsure');
    expect(find.text('未确认'), findsNothing);
    expect(find.text('已确认'), findsOneWidget);
    if (rowOutput != null) {
      await capture(tester, root, '$rowOutput/portrait-goal.png');
    }
  });

  testWidgets('excluded candidate row retains its tags in each orientation', (
    tester,
  ) async {
    final root = await openCandidateRow(
      tester,
      fixture,
      clips[1].copyWith(players: ['科比', '乔丹']),
    );
    await tester.tap(find.text('不选'));
    await tester.pumpAndSettle();
    await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
    await tester.tap(find.byKey(const Key('review-filter-excluded')));
    await settleVideo(tester);
    final excluded = fixture.state.project.candidates.single;
    expect(excluded.selection, CandidateSelection.excluded);
    expect(excluded.effectivePlayers, ['科比', '乔丹']);
    expect(find.text('你排除的'), findsOneWidget);
    expect(find.text('科比'), findsOneWidget);
    expect(find.text('乔丹'), findsOneWidget);
    if (rowOutput != null) {
      await capture(tester, root, '$rowOutput/portrait-excluded.png');
    }
    await tester.tap(find.byTooltip('横屏全屏'));
    await tester.binding.setSurfaceSize(const Size(640, 360));
    await settleVideo(tester);
    expect(find.text('科比'), findsOneWidget);
    expect(find.text('乔丹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtered goal empty state explains the total and clears it', (
    tester,
  ) async {
    final root = await openCandidateRow(
      tester,
      fixture,
      clips[0].copyWith(clearPlayer: true),
    );
    await tester.tap(find.byKey(const Key('review-filter-included')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review-player-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review-player-option-player:科比')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review-apply-filters')));
    await tester.pumpAndSettle();
    expect(find.text('进球 1'), findsOneWidget);
    expect(find.text('#1  0:01'), findsNothing);
    final empty = find.text('没有符合筛选的片段');
    expect(empty, findsOneWidget);
    expect(find.text('已按球员标签筛选'), findsOneWidget);
    final clear = find.widgetWithText(FilledButton, '清除筛选');
    expect(clear, findsOneWidget);
    expect(
      tester.getRect(clear).top - tester.getRect(empty).bottom,
      lessThan(72),
    );
    if (rowOutput != null) {
      await capture(tester, root, '$rowOutput/portrait-filtered.png');
    }
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.text('进球 1'), findsOneWidget);
    expect(find.text('#1  0:01'), findsOneWidget);
    expect(find.byKey(const Key('review-filters-active')), findsNothing);
  });

  for (final (locale, label) in [
    (const Locale('zh'), '恢复·算进球'),
    (const Locale('en'), 'Restore as goal'),
  ]) {
    testWidgets(
      'restore goal label stays on one line in ${locale.languageCode}',
      (tester) async {
        await openCandidateRow(tester, fixture, clips.last, locale: locale);
        await tester.tap(find.byKey(const Key('review-filter-excluded')));
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        final lines = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            )
            .map((box) => box.top)
            .toSet();
        expect(lines, hasLength(1));
      },
    );
  }

  testWidgets('portrait list fits complete rows above the video', (
    tester,
  ) async {
    final root = await openCandidateRow(
      tester,
      fixture,
      clips[1].copyWith(
        selection: CandidateSelection.excluded,
        reviewed: true,
        player: '科比',
      ),
      others: [
        clips[2].copyWith(
          selection: CandidateSelection.excluded,
          reviewed: true,
          player: '乔丹',
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('review-filter-excluded')));
    await settleVideo(tester);
    void expectWholeRow(String title) {
      final text = find.text(title);
      final tile = find.ancestor(of: text, matching: find.byType(InkWell));
      final list = find.ancestor(of: text, matching: find.byType(ListView));
      expect(
        tester.getRect(tile).top,
        greaterThanOrEqualTo(tester.getRect(list).top),
      );
      expect(
        tester.getRect(tile).bottom,
        lessThanOrEqualTo(tester.getRect(list).bottom),
      );
    }

    expectWholeRow('#1  0:03');
    expectWholeRow('#2  0:05');
    if (rowOutput != null) {
      await capture(tester, root, '$rowOutput/portrait-excluded-list.png');
    }
    await tester.binding.setSurfaceSize(const Size(360, 600));
    await settleVideo(tester);
    expectWholeRow('#1  0:03');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'legacy single tag grows into ordered tags and undoes in one edit',
    (tester) async {
      final legacy = Candidate.fromJson({
        'id': 'legacy',
        'start_ms': 0,
        'end_ms': 2000,
        'event_ms': 1000,
        'player': 'Alice',
      });
      expect(legacy.players, ['Alice']);
      final root = await openCandidateRow(
        tester,
        fixture,
        legacy,
        locale: const Locale('en'),
        players: ['Alice', 'Bob', 'Carol', 'Drew'],
      );
      await tester.tap(find.byTooltip('Player: Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-select-Bob')));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('apply-candidate-tags'));
      expect(save, findsOneWidget);
      expect(fixture.state.project.candidates.single.players, ['Alice']);
      await tester.tap(find.byKey(const ValueKey('player-select-Carol')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-select-Bob')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-select-Drew')));
      await tester.pumpAndSettle();
      assertEnglishWidgets(tester);
      if (multiTagOutput != null) {
        await capture(tester, root, '$multiTagOutput/portrait-tag-picker.png');
      }
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
      expect(fixture.state.project.candidates.single.players, [
        'Alice',
        'Carol',
        'Drew',
      ]);
      expect(fixture.state.reviewHistory.allEntries, hasLength(1));
      expect(find.text('+1'), findsOneWidget);
      if (multiTagOutput != null) {
        await capture(tester, root, '$multiTagOutput/portrait-review.png');
      }
      await tester.tap(find.byKey(const ValueKey('review-undo-bottom')));
      await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
      await tester.pumpAndSettle();
      expect(fixture.state.project.candidates.single.players, ['Alice']);
    },
  );

  testWidgets('landscape tags open the shared picker without losing playback', (
    tester,
  ) async {
    final video = _LandscapeTagVideoPlatform();
    VideoPlayerPlatform.instance = video;
    final root = await openCandidateRow(
      tester,
      fixture,
      clips[1],
      locale: const Locale('en'),
      players: ['Alice', 'Bob', 'Carol'],
    );
    await tester.tap(find.byTooltip('Landscape full screen'));
    await tester.binding.setSurfaceSize(const Size(640, 360));
    await settleVideo(tester);
    expect(find.byTooltip('Exit landscape review'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    final tag = find.byTooltip('Choose player tag');
    expect(tag, findsOneWidget);
    final undo = find.byKey(const ValueKey('review-undo-bottom'));
    final exclude = find.widgetWithText(OutlinedButton, 'Exclude');
    final include = find.widgetWithText(FilledButton, 'Include');
    final excludeRect = tester.getRect(exclude);
    final includeRect = tester.getRect(include);
    expect(
      tester.getRect(undo).right,
      lessThanOrEqualTo(tester.getRect(tag).left),
    );
    expect(tester.getRect(tag).right, lessThanOrEqualTo(excludeRect.left));
    expect(includeRect.right, lessThanOrEqualTo(640));
    expect(includeRect.bottom, lessThanOrEqualTo(360));

    const position = Duration(milliseconds: 3150);
    expect(video.playing, isTrue);
    video.position = position;
    await tester.pump(const Duration(milliseconds: 550));
    final slider = find.byType(Slider);
    expect(tester.widget<Slider>(slider).value, 3150);
    final seekCount = video.seeks.length;
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect(find.text('Player tags'), findsOneWidget);
    expect(video.playing, isFalse);
    assertEnglishWidgets(tester);
    for (final name in ['Bob', 'Carol']) {
      final label = find.byKey(ValueKey('player-select-$name'));
      await tester.ensureVisible(label);
      await tester.tap(label);
      await tester.pump();
    }
    final apply = find.byKey(const ValueKey('apply-candidate-tags'));
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Exit landscape review'), findsOneWidget);
    expect(fixture.state.project.candidates.single.effectivePlayers, [
      'Alice',
      'Bob',
      'Carol',
    ]);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(video.position, position);
    expect(video.seeks, hasLength(seekCount));
    expect(video.playing, isTrue);
    expect(tester.widget<Slider>(slider).value, 3150);
    expect(tester.getRect(exclude), excludeRect);
    expect(tester.getRect(include), includeRect);
    assertEnglishWidgets(tester);
    expect(tester.takeException(), isNull);
    if (landscapeTagOutput != null) {
      await capture(tester, root, '$landscapeTagOutput/landscape-review.png');
    }
    await tester.binding.setSurfaceSize(const Size(750, 360));
    await settleVideo(tester);
    expect(tester.getRect(include).right, lessThanOrEqualTo(750));
    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    await tester.tap(tag);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Exit landscape review'), findsOneWidget);
    expect(video.playing, isFalse);
    expect(tester.widget<Slider>(slider).value, 3150);
    expect(tester.takeException(), isNull);
  });

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
    await openReview(tester, clips.length);
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
