import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/export_settings_actions.dart';
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
  int? failSaveAt;
  int? failExportAtMs;
  final enteredClip = Completer<void>();
  final heldClip = Completer<void>();
  bool hold = false;

  @override
  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'exportClip') {
      if (!enteredClip.isCompleted) enteredClip.complete();
      if (hold) await heldClip.future;
      if ((call.arguments as Map)['startMs'] == failExportAtMs) {
        throw PlatformException(
          code: 'EXPORT_FAILED',
          message: 'No space left',
        );
      }
    }
    if (call.method == 'saveToLibrary') {
      saveCalls++;
      if (refuseSave || saveCalls == failSaveAt) {
        throw PlatformException(code: 'PHOTO_PERMISSION_DENIED');
      }
      return null;
    }
    return super.handle(call);
  }
}

Future<({MobileVideoFixture fixture, _Media media, GlobalKey root})> _open(
  WidgetTester tester, {
  bool twoClips = false,
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  double textScale = 1,
  Duration drain = const Duration(seconds: 30),
  WidgetBuilder? allowance,
}) async {
  final fixture = MobileVideoFixture();
  final media = _Media();
  await tester.runAsync(() async {
    await fixture.init(exportDrainTimeout: drain);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('bhe.github-star-prompt-shown', true);
    final video = await fixture.file('original.mp4', 'original');
    final project = fixture.project(video.path);
    fixture.state.project = project.copyWith(
      candidates: [
        ...project.candidates,
        if (twoClips)
          const Candidate(
            id: 'extra',
            startMs: 4000,
            endMs: 5500,
            eventMs: 5000,
            reviewed: true,
            player: 'Alice',
          ),
      ],
    );
    media.install();
  });
  addTearDown(() async {
    if (!media.heldClip.isCompleted) media.heldClip.complete();
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
      child: BheMobileApp(
        appState: fixture.state,
        exportAllowanceBuilder: allowance,
      ),
    ),
  );
  await _frame(tester);
  await tester.tap(
    find.byTooltip(locale.languageCode == 'zh' ? '导出' : 'Export').first,
  );
  await _frame(tester);
  final zh = locale.languageCode == 'zh';
  await chooseExportMode(
    tester,
    zh ? '每段一个视频' : 'One video per clip',
    zh ? '完成' : 'Done',
  );
  return (fixture: fixture, media: media, root: root);
}

Future<void> _capture(WidgetTester tester, GlobalKey root, String name) async {
  final directory = Platform.environment['BHE_L539_CAPTURE_DIR'];
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

void _assertEnglish(WidgetTester tester) {
  for (final widget in tester.widgetList<Text>(
    find.byType(Text).hitTestable(),
  )) {
    expect(
      widget.data ?? widget.textSpan?.toPlainText(),
      isNot(matches(RegExp(r'[\u3400-\u9fff]'))),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['BHE_L539_CAPTURE_FONT'];
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
    expect(
      find.textContaining('Allow photo access in Settings'),
      findsOneWidget,
    );
  });

  testWidgets(
    'L539 M2 gallery retries only the unsaved file, then allows saving again',
    (tester) async {
      final app = await _open(tester, twoClips: true);
      app.media.failSaveAt = 2;
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.text('Save 2 to Photos'));
      await _frame(tester);
      await tester.runAsync(() => tester.tap(find.byKey(_save)));
      await _until(tester, find.text('Save remaining 1'));
      expect(app.media.saveCalls, 2);
      await tester.runAsync(() => tester.tap(find.byKey(_save)));
      await _until(tester, find.text('Save selected again'));
      await _until(tester, _enabledShare);
      expect(app.media.saveCalls, 3);
      await tester.runAsync(() => tester.tap(find.text('Save selected again')));
      for (var index = 0; index < 30 && app.media.saveCalls < 5; index++) {
        await _frame(tester);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      expect(app.media.saveCalls, 5);
      await _until(tester, _enabledShare);
    },
  );

  testWidgets(
    'L539 M2 missing selected file is named before saving the others',
    (tester) async {
      final app = await _open(tester, twoClips: true);
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.text('Save 2 to Photos'));
      await _frame(tester);
      final path = app.fixture.state.exportedPaths.first;
      final name = File(path).uri.pathSegments.last;
      await tester.runAsync(() => File(path).delete());
      await tester.runAsync(() => tester.tap(find.byKey(_save)));
      await _until(
        tester,
        find.textContaining('File is no longer available: $name'),
      );
      expect(app.media.saveCalls, 0);
      expect(find.text('Save 1 to Photos'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.byKey(_save)));
      await _until(tester, find.text('Save selected again'));
      expect(app.media.saveCalls, 1);
    },
  );

  testWidgets('L539 M2 keep-open guidance also covers ordinary export', (
    tester,
  ) async {
    final app = await _open(tester);
    app.media.hold = true;
    await tester.runAsync(() => tester.tap(find.text('Start export')));
    await _until(tester, find.byKey(_progress));
    await _until(tester, find.textContaining('Keep this page open'));
    expect(find.text('Cancel export'), findsOneWidget);
    app.media.heldClip.complete();
    await _until(tester, find.byKey(_result));
  });

  testWidgets(
    'L539 M2 shares the selected files and keeps a share error separate',
    (tester) async {
      final app = await _open(tester, twoClips: true);
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      List<Object?>? sent;
      messenger.setMockMethodCallHandler(channel, (call) async {
        sent = List<Object?>.of((call.arguments as Map)['paths'] as List);
        throw PlatformException(code: 'SHARE_FAILED');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.text('Save 2 to Photos'));
      final first = find.descendant(
        of: find.byKey(const ValueKey('export-file-0')),
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(first);
      await tester.pump();
      await tester.tap(first);
      await tester.pump();
      await tester.runAsync(() => tester.tap(find.byKey(_share)));
      await _until(tester, find.byKey(const Key('export-share-error')));
      expect(sent, [app.fixture.state.exportedPaths.last]);
      expect(find.text('2 videos ready'), findsOneWidget);
      expect(find.text('Save 1 to Photos'), findsOneWidget);
      expect(app.media.saveCalls, 0);
    },
  );

  testWidgets('L539 M2 an injected allowance appears only in settings', (
    tester,
  ) async {
    final app = await _open(
      tester,
      allowance: (_) => const Text('Allowance display'),
    );
    expect(find.text('Allowance display'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('Start export')));
    await _until(tester, find.byKey(_result));
    await tester.pumpAndSettle();
    expect(find.text('Allowance display').hitTestable(), findsNothing);
    expect(app.fixture.state.exportedPaths, hasLength(1));
  });

  testWidgets('L539 M2 cancel timeout shows the native stop as unconfirmed', (
    tester,
  ) async {
    final app = await _open(tester, drain: const Duration(milliseconds: 75));
    app.media.hold = true;
    await tester.runAsync(() => tester.tap(find.text('Start export')));
    for (
      var attempt = 0;
      attempt < 50 && !app.media.enteredClip.isCompleted;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
    expect(app.media.enteredClip.isCompleted, isTrue);
    await _frame(tester);
    await tester.tap(find.text('Cancel export'));
    await _until(tester, find.text('Not confirmed stopped'));
    expect(app.fixture.state.hasUncertainExport, isTrue);
    expect(
      find.byKey(const ValueKey('uncertain-export-notice')),
      findsOneWidget,
    );
    app.media.heldClip.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  testWidgets(
    'final settings, running export, file actions and history detail',
    (tester) async {
      final app = await _open(
        tester,
        twoClips: true,
        locale: const Locale('zh'),
      );
      expect(find.byType(FilledButton), findsOneWidget);
      await _capture(tester, app.root, '01-设置-中文竖屏');
      app.media.hold = true;
      await tester.runAsync(() => tester.tap(find.text('开始导出')));
      await _until(tester, find.byKey(_progress));
      await _frame(tester);
      await _capture(tester, app.root, '02-进行中-中文竖屏');
      app.media.heldClip.complete();
      await _until(tester, find.text('保存 2 个到相册'));
      await tester.pumpAndSettle();
      await _capture(tester, app.root, '03-结果成功-中文竖屏');
      await tester.tap(find.text('全不选'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      expect(
        tester.widget<OutlinedButton>(find.byKey(_share)).onPressed,
        isNull,
      );
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('保存 2 个到相册'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.byKey(_save)));
      await _until(tester, find.text('再次保存所选文件'));
      await _until(tester, _enabledShare);
      await tester.pumpAndSettle();
      await _capture(tester, app.root, '04-文件与保存-中文竖屏');
      await tester.tap(find.byType(BackButton));
      await _frame(tester);
      await openExportControl(tester, 'export-history');
      expect(find.textContaining('中断的导出不会继续'), findsOneWidget);
      await _capture(tester, app.root, '05-导出历史-中文竖屏');
      final id = app.fixture.state.project.exportHistory.single.id;
      await tester.tap(find.byKey(ValueKey('history-entry-$id')));
      await _until(tester, find.text('再次保存所选文件'));
      await tester.pumpAndSettle();
      expect(find.byKey(_result), findsOneWidget);
      expect(find.byKey(_share), findsOneWidget);
      expect(find.byKey(_save), findsOneWidget);
      await _capture(tester, app.root, '06-历史详情-中文竖屏');
    },
  );

  for (final (start, marker, outcome) in [
    (4000, '1 exported, 1 to go', '07-结果部分成功-英文横屏'),
    (1000, 'Nothing was exported', '08-结果失败-英文横屏'),
  ]) {
    testWidgets('final $marker shares the landscape layout', (tester) async {
      final app = await _open(
        tester,
        twoClips: true,
        size: const Size(820, 390),
      );
      app.media.failExportAtMs = start;
      await _capture(tester, app.root, '09-设置-英文横屏');
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.text(marker));
      if (start == 4000) await _until(tester, find.text('Save 1 to Photos'));
      await tester.pumpAndSettle();
      _assertEnglish(tester);
      expect(tester.takeException(), isNull);
      await _capture(tester, app.root, outcome);
    });
  }

  testWidgets(
    'final 360 wide English layout in light theme with large text and cancellation',
    (tester) async {
      final app = await _open(
        tester,
        size: const Size(360, 760),
        textScale: 1.4,
      );
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await _frame(tester);
      await tester.tap(find.text('Theme · Dark'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byKey(_settings))).brightness,
        Brightness.light,
      );
      _assertEnglish(tester);
      expect(find.text('Start export').hitTestable(), findsOneWidget);
      await _capture(tester, app.root, '10-设置-英文360大字浅色');
      app.media.hold = true;
      await tester.runAsync(() => tester.tap(find.text('Start export')));
      await _until(tester, find.byKey(_progress));
      await _frame(tester);
      _assertEnglish(tester);
      await _capture(tester, app.root, '11-进行中-英文360大字浅色');
      await tester.tap(find.text('Cancel export'));
      app.media.heldClip.complete();
      await _until(tester, find.text('Cancelled, kept 0'));
      await _frame(tester);
      _assertEnglish(tester);
      expect(tester.takeException(), isNull);
      await _capture(tester, app.root, '12-结果已取消-英文360大字浅色');
    },
  );

  testWidgets('L539 M2 a long history file list keeps its actions visible', (
    tester,
  ) async {
    final app = await _open(tester, size: const Size(360, 760), textScale: 1.4);
    final files = (await tester.runAsync(() async {
      final files = <ExportHistoryFile>[];
      for (var index = 1; index <= 30; index++) {
        final relative = 'batch/group_$index.mp4';
        await app.fixture.file('BHE Mobile/exports/A/$relative', 'demo file');
        files.add(
          ExportHistoryFile(
            name: 'Team Blue · Long label, group $index',
            relativePath: relative,
          ),
        );
      }
      return files;
    }))!;
    final state = app.fixture.state;
    state.project = state.project.copyWith(
      exportHistory: [
        ExportHistoryEntry(
          id: 'demo',
          createdAt: DateTime.utc(2026, 11, 25),
          mode: 'labels',
          plannedCount: files.length,
          durationMs: 1000,
          files: files,
        ),
      ],
    );
    state.notifyListeners();
    await tester.pump();
    await openExportControl(tester, 'export-history');
    await tester.tap(find.byKey(const ValueKey('history-entry-demo')));
    await _until(tester, find.text('Save 30 to Photos'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('export-file-0')), findsNothing);
    await tester.tap(find.byTooltip('Expand'));
    await tester.pumpAndSettle();
    expect(find.text('Team Blue · Long label, group 1'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('export-file-29')),
      230,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('group_30.mp4').hitTestable(), findsOneWidget);
    expect(find.byKey(_save).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    _assertEnglish(tester);
    await _capture(tester, app.root, '13-历史详情30个文件-英文360大字');
  });
}
