import 'dart:async';

import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_portrait_media.dart';
import '../../support/mobile_video_fixture.dart';

const _settings = Key('export-settings');
const _progress = Key('export-progress');
const _result = Key('export-result');
const _scope = Key('export-scope');
const _mode = Key('export-mode');
const _history = Key('export-history');
const _save = Key('export-save');
const _share = Key('export-share');

Future<void> _frame(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var index = 0; index < 60 && finder.evaluate().isEmpty; index++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget);
}

class _Media extends FakePortraitMedia {
  int saveCalls = 0;
  bool refuseSave = false;
  final heldClip = Completer<void>();
  bool hold = false;

  @override
  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'exportClip' && hold) await heldClip.future;
    if (call.method == 'saveToLibrary') {
      saveCalls++;
      if (refuseSave) {
        throw PlatformException(code: 'PHOTO_PERMISSION_DENIED');
      }
      return null;
    }
    return super.handle(call);
  }
}

Future<({MobileVideoFixture fixture, _Media media})> _open(
  WidgetTester tester,
) async {
  final fixture = MobileVideoFixture();
  final media = _Media();
  await tester.runAsync(() async {
    await fixture.init();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bhe.github-star-prompt-shown', true);
    final video = await fixture.file('original.mp4', 'original');
    fixture.state.project = fixture.project(video.path);
    media.install();
  });
  addTearDown(() async {
    if (!media.heldClip.isCompleted) media.heldClip.complete();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(fixture.close);
    media.close();
    await tester.binding.setSurfaceSize(null);
    tester.binding.platformDispatcher.clearLocaleTestValue();
  });
  await tester.binding.setSurfaceSize(const Size(390, 844));
  tester.binding.platformDispatcher.localeTestValue = const Locale('en');
  await tester.pumpWidget(BheMobileApp(appState: fixture.state));
  await _frame(tester);
  await tester.tap(find.byTooltip('Export').first);
  await _frame(tester);
  return (fixture: fixture, media: media);
}

void main() {
  testWidgets('settings opens scope and output sheets and separate history', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byKey(_settings), findsOneWidget);
    expect(find.byKey(const Key('export-tier-goal')), findsNothing);
    await tester.tap(find.byKey(_scope));
    await _frame(tester);
    expect(find.byKey(const Key('export-tier-goal')), findsOneWidget);
    await tester.tap(find.text('Done'));
    await _frame(tester);
    await tester.tap(find.byKey(_mode));
    await _frame(tester);
    expect(find.text('One merged video'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await _frame(tester);
    final history = find.byKey(_history);
    await tester.ensureVisible(history);
    await tester.tap(history);
    await _frame(tester);
    expect(find.byKey(const Key('export-history-page')), findsOneWidget);
    expect(find.byKey(_settings), findsNothing);
  });

  testWidgets(
    'going back from progress keeps the export and opens its result once',
    (tester) async {
      final app = await _open(tester);
      app.media.hold = true;
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.byKey(_progress));
      await tester.pageBack();
      await _frame(tester);
      expect(app.fixture.state.exporting, isTrue);
      expect(find.text('View progress'), findsOneWidget);
      app.media.heldClip.complete();
      await _until(tester, find.byKey(_result));
      await _frame(tester);
      expect(find.byKey(_share), findsOneWidget);
      expect(find.byKey(_save), findsOneWidget);
      await tester.pageBack();
      await _frame(tester);
      expect(find.byKey(_result), findsNothing);
      expect(find.byKey(_settings), findsOneWidget);
    },
  );

  testWidgets('gallery failure preserves the result and its selected file', (
    tester,
  ) async {
    final app = await _open(tester);
    app.media.refuseSave = true;
    await tester.runAsync(() => tester.tap(find.text('Start export')));
    await _until(tester, find.byKey(_result));
    final selected = find.byType(Checkbox);
    await _until(
      tester,
      find.byWidgetPredicate(
        (widget) => widget is Checkbox && widget.value == true,
      ),
    );
    expect(tester.widget<Checkbox>(selected).value, isTrue);
    await tester.runAsync(() => tester.tap(find.byKey(_save)));
    await _until(tester, find.byKey(const Key('export-save-error')));
    expect(find.byKey(_progress), findsNothing);
    expect(find.text('Nothing was exported'), findsNothing);
    expect(tester.widget<Checkbox>(selected).value, isTrue);
    expect(app.media.saveCalls, 1);
  });
}
