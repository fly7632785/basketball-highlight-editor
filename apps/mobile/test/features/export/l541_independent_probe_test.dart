import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/export_settings_actions.dart';
import '../../support/fake_portrait_media.dart';
import '../../support/mobile_video_fixture.dart';

const _save = Key('export-save');
const _share = Key('export-share');
const _result = Key('export-result');
const _missing = Key('export-missing-files');

Finder get _enabledShare => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key == _share &&
      widget.onPressed != null,
);

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
  final savedPaths = <String>[];

  @override
  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'saveToLibrary') {
      saveCalls++;
      if (refuseSave) throw PlatformException(code: 'PHOTO_PERMISSION_DENIED');
      savedPaths.add((call.arguments as Map)['path'] as String);
      return null;
    }
    return super.handle(call);
  }
}

Future<({MobileVideoFixture fixture, _Media media, GlobalKey root})> _open(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
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
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(fixture.close);
    media.close();
    await tester.binding.setSurfaceSize(null);
    tester.binding.platformDispatcher.clearLocaleTestValue();
    tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.binding.setSurfaceSize(size);
  tester.binding.platformDispatcher.localeTestValue = locale;
  tester.binding.platformDispatcher.textScaleFactorTestValue = textScale;
  final root = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: root,
      child: BheMobileApp(appState: fixture.state),
    ),
  );
  await _frame(tester);
  await tester.tap(
    find.byTooltip(locale.languageCode == 'zh' ? '导出' : 'Export').first,
  );
  await _frame(tester);
  return (fixture: fixture, media: media, root: root);
}

Future<void> _capture(WidgetTester tester, GlobalKey root, String name) async {
  final directory = Platform.environment['BHE_L543_CAPTURE_DIR'];
  if (directory == null) return;
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
  });
}

Future<List<ExportHistoryFile>> _showMissingBatch(
  WidgetTester tester,
  MobileVideoFixture fixture, {
  required String initialSave,
}) async {
  final files = (await tester.runAsync(() async {
    final files = <ExportHistoryFile>[];
    for (var index = 0; index < 9; index++) {
      final relative =
          'batch/BHE-Basketball-Highlights-goal_${index.toString().padLeft(3, '0')}_123.45s_Team_Blue.mp4';
      await fixture.file('BHE Mobile/exports/A/$relative', 'demo');
      files.add(
        ExportHistoryFile(name: 'Team Blue $index', relativePath: relative),
      );
    }
    return files;
  }))!;
  final state = fixture.state;
  state.project = state.project.copyWith(
    exportHistory: [
      ExportHistoryEntry(
        id: 'many',
        createdAt: DateTime.utc(2026, 11, 25),
        mode: 'labels',
        plannedCount: 9,
        durationMs: 100,
        files: files,
      ),
    ],
  );
  state.notifyListeners();
  await tester.pump();
  await openExportControl(tester, 'export-history');
  await tester.tap(find.byKey(const ValueKey('history-entry-many')));
  await _until(tester, find.text(initialSave));
  await tester.runAsync(() async {
    for (final file in files.take(8)) {
      await File(
        '${fixture.root.path}/BHE Mobile/exports/A/${file.relativePath}',
      ).delete();
    }
  });
  await tester.runAsync(() => tester.tap(find.byKey(_save)));
  return files;
}

Finder get _resultScroll => find.descendant(
  of: find.descendant(
    of: find.byKey(_result),
    matching: find.byType(CustomScrollView),
  ),
  matching: find.byType(Scrollable),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['BHE_L543_CAPTURE_FONT'];
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

  testWidgets('L541 batch disappearance keeps remaining file actions reachable', (
    tester,
  ) async {
    final app = await _open(tester, size: const Size(360, 760), textScale: 1.4);
    final files = await _showMissingBatch(
      tester,
      app.fixture,
      initialSave: 'Save 9 to Photos',
    );
    final details = find.textContaining('File is no longer available:');
    await _until(tester, details);

    final error = tester.takeException();
    debugPrintSynchronously(
      'L541 saveRect=${tester.getRect(find.byKey(_save))} saveHit=${find.byKey(_save).hitTestable().evaluate().length}',
    );
    expect(
      error,
      isNull,
      reason: 'The missing-file message must not overflow the result page',
    );
    expect(find.byKey(_save).hitTestable(), findsOneWidget);
    expect(find.byKey(_share).hitTestable(), findsOneWidget);
    expect(find.text('Save 1 to Photos'), findsOneWidget);
    expect(app.media.saveCalls, 0);
    await _capture(tester, app.root, 'missing-8-of-9-360-en');

    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final shared = <String>[];
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.addAll(((call.arguments as Map)['paths'] as List).cast<String>());
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(shareChannel, null));
    final remaining = await tester.runAsync(
      () => app.fixture.state.exportHistoryFilePath(files.last),
    );
    expect(remaining, isNotNull);
    await tester.runAsync(() => tester.tap(find.byKey(_share)));
    for (var index = 0; index < 60 && shared.isEmpty; index++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _until(tester, _enabledShare);
    expect(shared, [remaining]);
    await tester.runAsync(() => tester.tap(find.byKey(_save)));
    await _until(tester, find.text('Save selected again'));
    await _until(tester, _enabledShare);
    expect(app.media.savedPaths, [remaining]);
  });

  for (final size in [const Size(360, 760), const Size(800, 360)]) {
    for (final english in [true, false]) {
      final language = english ? 'en' : 'zh';
      testWidgets(
        'L543 missing details expand and scroll at ${size.width.toInt()} in $language',
        (tester) async {
          final app = await _open(
            tester,
            size: size,
            locale: Locale(language),
            textScale: 1.4,
          );
          final files = await _showMissingBatch(
            tester,
            app.fixture,
            initialSave: english ? 'Save 9 to Photos' : '保存 9 个到相册',
          );
          final tile = find.byKey(_missing);
          final heading = find.text(english ? 'Missing file list' : '失效文件清单');
          final details = find.textContaining(
            english ? 'File is no longer available:' : '本机文件已不可用：',
          );
          final summary = find.text(
            english ? '8 files are missing' : '8 个文件已不存在',
          );
          await _until(tester, summary);
          await _until(tester, details);
          expect(
            find.descendant(of: _resultScroll, matching: tile),
            findsOneWidget,
          );
          final messages = tester.widget<Text>(details).data!;
          for (final file in files.take(8)) {
            expect(messages, contains(file.relativePath.split('/').last));
          }
          expect(
            messages,
            isNot(contains(files.last.relativePath.split('/').last)),
          );
          expect(tester.widget<Text>(details).maxLines, isNull);
          expect(summary.hitTestable(), findsOneWidget);
          expect(find.byKey(_share).hitTestable(), findsOneWidget);

          await tester.ensureVisible(heading);
          await tester.tap(heading);
          await _frame(tester);
          expect(details, findsNothing);
          await tester.tap(heading);
          await _frame(tester);
          expect(details, findsOneWidget);

          final save = find.byKey(_save);
          final before = tester.getRect(save);
          final scroll = tester.state<ScrollableState>(_resultScroll).position;
          final viewport = tester.getRect(find.byType(CustomScrollView));
          final detailsBottom = tester.getBottomLeft(details).dy;
          if (detailsBottom > viewport.bottom) {
            final target = scroll.pixels + detailsBottom - viewport.bottom + 12;
            scroll.jumpTo(target.clamp(0.0, scroll.maxScrollExtent));
            await _frame(tester);
          }
          expect(
            tester.getBottomLeft(details).dy,
            lessThanOrEqualTo(viewport.bottom),
          );
          expect(tester.getRect(save), before);
          expect(save.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          if (english && size.width == 360) {
            await _capture(tester, app.root, 'missing-8-of-9-360-en-scrolled');
          }
        },
      );
    }
  }

  testWidgets('L543 long save and share errors stay in the scrollable result', (
    tester,
  ) async {
    final app = await _open(tester, size: const Size(360, 760), textScale: 1.4);
    app.media.refuseSave = true;
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'SHARE_FAILED');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.runAsync(() => tester.tap(find.text('Start export')));
    await _until(tester, find.text('Save 1 to Photos'));
    await tester.runAsync(() => tester.tap(find.byKey(_share)));
    await _until(tester, find.byKey(const Key('export-share-error')));
    await tester.runAsync(() => tester.tap(find.byKey(_save)));
    await _until(tester, find.byKey(const Key('export-save-error')));
    await _until(tester, _enabledShare);

    final reason = List.filled(18, 'Details from the system.').join(' ');
    final state = app.fixture.state;
    state.gallerySaveFailure = (
      message: '$reason Save details end.',
      diagnostic: null,
    );
    state.shareFailure = (
      message: '$reason Share details end.',
      diagnostic: null,
    );
    state.notifyListeners();
    await _frame(tester);
    for (final (kind, end) in [
      ('save', 'Save details end.'),
      ('share', 'Share details end.'),
    ]) {
      final notice = find.byKey(ValueKey('export-$kind-error'));
      await tester.scrollUntilVisible(notice, 120, scrollable: _resultScroll);
      await _frame(tester);
      expect(
        find.descendant(of: _resultScroll, matching: notice),
        findsOneWidget,
      );
      final message = find.descendant(
        of: notice,
        matching: find.textContaining(end),
      );
      expect(tester.widget<Text>(message).maxLines, isNull);
      expect(find.byKey(_share).hitTestable(), findsOneWidget);
      expect(find.text('Save remaining 1').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'L541 acknowledged album save remains saved in history after marker I/O failure',
    (tester) async {
      final app = await _open(tester);
      final f = app.fixture;
      final alias = '${f.root.path}/alias-root';
      await tester.runAsync(() => Link(alias).create(f.root.path));
      const provider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(provider, (_) async {
            if (f.state.project.exportHistory.any(
              (e) => e.files.any((file) => file.savedToGallery),
            )) {
              throw PlatformException(code: 'HISTORY_IO');
            }
            return alias;
          });
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.text('Save 1 to Photos'));
      await tester.runAsync(() => tester.tap(find.byKey(_save)));
      await _until(tester, find.text('Save selected again'));
      await _until(tester, _enabledShare);
      expect(f.state.exportHistoryWarning, '已保存到相册，历史记录更新失败。');
      expect(
        f.state.project.exportHistory.single.files.single.savedToGallery,
        isFalse,
      );
      expect(app.media.saveCalls, 1);
      await tester.pageBack();
      await _frame(tester);
      await openExportControl(tester, 'export-history');
      final entry = f.state.project.exportHistory.single;
      await tester.tap(find.byKey(ValueKey('history-entry-${entry.id}')));
      for (var i = 0; i < 20; i++) {
        await _frame(tester);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      final raw = f.state.gallerySavedPaths.single;
      final actual = await tester.runAsync(
        () => f.state.exportHistoryFilePath(entry.files.single),
      );
      debugPrintSynchronously(
        'L541 acknowledged=${f.state.gallerySavedPaths.length} rawEqualsResolved=${raw == actual} currentSaveCalls=${app.media.saveCalls}',
      );
      expect(
        find.text('Save selected again'),
        findsOneWidget,
        reason:
            'Native acknowledged success must survive result/history view changes in the same session',
      );
    },
  );
}
