import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());
  testWidgets(
    'undo remains at the bottom when the active filter hides the last clip',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      fixture.state.project = fixture.project(
        '${fixture.root.path}/missing.mp4',
      );
      try {
        await tester.pumpWidget(BheMobileApp(appState: fixture.state));
        await tester.pump();
        final context = tester.element(find.byType(Scaffold).first);
        final l10n = Localizations.of<BheLocalizations>(
          context,
          BheLocalizations,
        )!;
        final review = find.text(l10n.reviewCount(1));
        await tester.ensureVisible(review);
        await tester.pump();
        await tester.tap(review);
        await tester.pump();
        await tester.tap(find.byKey(const Key('review-filter-included')));
        await tester.pump();
        await tester.tap(find.text(l10n.text('不选')).last);
        await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
        await tester.pump();
        final rail = find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_CandidateRail',
        );
        expect(
          find.byKey(const ValueKey('review-notice-surface')),
          findsNothing,
        );
        final undo = find.byKey(const ValueKey('review-undo-bottom'));
        expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
        expect(
          tester.getRect(undo).top,
          greaterThanOrEqualTo(tester.getRect(rail).bottom),
        );
        expect(find.byKey(const ValueKey('review-undo-top')), findsNothing);
        expect(
          fixture.state.project.candidates.single.selection,
          CandidateSelection.excluded,
        );
        await tester.tap(undo);
        await tester.pump();
        await waitProjectWrites(tester, fixture.state.pendingProjectWrites);
        await tester.pump();
        expect(
          fixture.state.project.candidates.single.selection,
          CandidateSelection.included,
        );
        expect(fixture.state.undoFocusId, 'goal');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
