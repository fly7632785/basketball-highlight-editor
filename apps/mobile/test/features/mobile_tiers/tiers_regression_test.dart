import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/export/export_modes.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/features/review_tiers/mobile_tiers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/export_settings_actions.dart';
import '../../support/mobile_video_fixture.dart';

const _clips = [
  Candidate(id: 'old', startMs: 0, endMs: 2000, eventMs: 1000),
  Candidate(
    id: 'goal',
    startMs: 2000,
    endMs: 4000,
    eventMs: 3000,
    reviewed: true,
    players: ['Alice', 'Bob'],
  ),
  Candidate(
    id: 'auto',
    startMs: 4000,
    endMs: 6000,
    eventMs: 5000,
    selection: CandidateSelection.excluded,
    rimCheck: {'status': 'rejected'},
  ),
  Candidate(id: 'fold', startMs: 6000, endMs: 8000, eventMs: 7000),
];

class _FoldedState extends MobileAppState {
  _FoldedState() : super(videoProbe: MobileVideoFixture.inspect);

  @override
  Set<String> get likelyMissCandidateIds => const {
    'fold',
    'fold2',
    'goal',
    'auto',
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only unrestricted grouping includes both tags for the same clip', () {
    final groups = labelExportGroups([_clips[1]]);
    expect(
      {for (final group in groups) group.label: group.candidates},
      {
        'Alice': [_clips[1]],
        'Bob': [_clips[1]],
      },
    );
    final selected = labelExportGroups([
      _clips[1],
    ], scope: const ExportScope.only({'Bob'}));
    expect(selected.map((group) => group.label), ['Bob']);
    expect(selected.single.candidates, [_clips[1]]);
  });

  test('grouped export never creates an untagged output group', () {
    expect(labelExportGroups([_clips[0]]), isEmpty);
  });

  test(
    'folded batch preserves human decisions and undoes in one step',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      addTearDown(f.close);
      f.state.dispose();
      f.state = _FoldedState();
      await f.state.ready;
      final file = await f.file('original.mp4', 'original');
      final sequence = [
        ..._clips,
        const Candidate(id: 'fold2', startMs: 8000, endMs: 9900, eventMs: 9000),
      ];
      f.state.project = f.project(file.path).copyWith(candidates: sequence);
      await f.state.markLikelyMissed({
        'old',
        'goal',
        'auto',
        'fold',
        'fold2',
      }, expanded: true);
      expect(f.state.project.candidates.map((c) => c.selection), [
        CandidateSelection.included,
        CandidateSelection.included,
        CandidateSelection.excluded,
        CandidateSelection.excluded,
        CandidateSelection.excluded,
      ]);
      expect(f.state.project.candidates.map((c) => c.reviewed), [
        false,
        true,
        false,
        true,
        true,
      ]);
      expect(f.state.reviewHistory.allEntries.length, 1);
      await f.state.undoReview();
      expect(
        f.state.project.candidates.map((c) => c.toJson()),
        sequence.map((c) => c.toJson()),
      );
      expect(f.state.canUndoReview, isFalse);
      expect(f.state.undoFoldedView, isTrue);
    },
  );

  test('tier derives from persisted human judgment before rim evidence', () {
    expect(
      mobileTier(Candidate.fromJson(_clips[0].toJson()..remove('reviewed'))),
      MobileTier.uncertain,
    );
    expect(mobileTier(_clips[1]), MobileTier.goal);
    expect(mobileTier(_clips[2]), MobileTier.excluded);
    expect(
      mobileTier(
        _clips[2].copyWith(
          selection: CandidateSelection.included,
          reviewed: true,
        ),
      ),
      MobileTier.goal,
    );
    expect(
      mobileTier(
        _clips[0].copyWith(
          selection: CandidateSelection.excluded,
          reviewed: true,
        ),
      ),
      MobileTier.excluded,
    );
    const passed = Candidate(
      id: 'pass',
      startMs: 0,
      endMs: 1,
      eventMs: 0,
      rimCheck: {'status': 'made'},
    );
    expect(mobileTier(passed), MobileTier.uncertain);
    expect(ExportScope.only({'Bob'}).select(_clips, MobileOutputMode.clips), [
      _clips[1],
    ]);
    expect(
      const ExportScope.anyTag(
        tiers: {MobileTier.excluded},
      ).select(_clips, MobileOutputMode.clips),
      [_clips[2]],
    );
  });

  testWidgets('review starts in Uncertain and counts only human goals', (
    tester,
  ) async {
    final f = MobileVideoFixture();
    await tester.runAsync(f.init);
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    try {
      final file = await tester.runAsync(
        () => f.file('original.mp4', 'original'),
      );
      f.state.project = f.project(file!.path).copyWith(candidates: _clips);
      await tester.pumpWidget(BheMobileApp(appState: f.state));
      await tester.pump();
      await tester.ensureVisible(find.text('Review 4'));
      await tester.pump();
      await tester.tap(find.text('Review 4'));
      await tester.pump();
      expect(find.byKey(const Key('review-filter-uncertain')), findsOneWidget);
      expect(find.text('2 uncertain left · 1 reviewed'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    }
  });

  testWidgets('export defaults to goals and merge, then restores choices', (
    tester,
  ) async {
    final f = MobileVideoFixture();
    await tester.runAsync(f.init);
    tester.binding.platformDispatcher.localeTestValue = const Locale('en');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    try {
      final file = await tester.runAsync(
        () => f.file('original.mp4', 'original'),
      );
      f.state.project = f.project(file!.path).copyWith(candidates: [_clips[0]]);

      Future<void> open() async {
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        await tester.tap(find.byTooltip('Export').first);
        await settleExportRoute(tester);
      }

      bool tierSelected(String name) => tester
          .widget<FilterChip>(find.byKey(Key('export-tier-$name')))
          .selected;

      await open();
      expect(find.text('One merged video'), findsOneWidget);
      expect(find.text('No clips to export'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start export'),
            )
            .onPressed,
        isNull,
      );

      await openExportScope(tester);
      expect(tierSelected('goal'), isTrue);
      expect(tierSelected('uncertain'), isFalse);
      expect(tierSelected('excluded'), isFalse);
      await tester.tap(find.byKey(const Key('export-tier-uncertain')));
      await finishExportSettings(tester, 'Done');
      await chooseExportMode(tester, 'One video per clip', 'Done');

      await tester.pumpWidget(const SizedBox());
      await open();
      expect(find.text('One video per clip'), findsOneWidget);
      expect(find.text('Will export 1 clip · Clip total 0:02'), findsOneWidget);
      await openExportScope(tester);
      expect(tierSelected('goal'), isTrue);
      expect(tierSelected('uncertain'), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
    }
  });
}
