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

import '../../support/fake_portrait_media.dart';
import '../../support/mobile_video_fixture.dart';

const _clip = Candidate(
  id: 'next',
  startMs: 3100,
  endMs: 5100,
  eventMs: 4000,
  player: 'Alice',
  reviewed: true,
);
const _hdrCopy =
    'Exports in standard dynamic range. Colors may look flatter than the original.';

final _captureDir = Platform.environment['BHE_L525_CAPTURE_DIR'];
final _captureFont = Platform.environment['BHE_L525_CAPTURE_FONT'];

Future<void> _advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 4 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -180));
    await tester.pump(const Duration(milliseconds: 400));
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, GlobalKey root, String name) async {
  if (_captureDir == null) return;
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(
      '$_captureDir/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
  });
}

void _assertEnglish(WidgetTester tester) {
  final han = RegExp(r'[\u3400-\u9fff]');
  for (final widget in tester.widgetList<Text>(find.byType(Text))) {
    expect(widget.data ?? widget.textSpan?.toPlainText(), isNot(matches(han)));
  }
}

Future<({GlobalKey root, MobileVideoFixture fixture, FakePortraitMedia media})>
_openExport(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Locale locale = const Locale('en'),
  bool hdr = false,
}) async {
  final fixture = MobileVideoFixture();
  await tester.runAsync(() async {
    await fixture.init();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('bhe.github-star-prompt-shown', true);
  });
  final media = FakePortraitMedia()..isHdr = hdr;
  media.install();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => fixture.close());
    media.close();
  });
  final source = await tester.runAsync(
    () => fixture.file('original.mp4', 'original'),
  );
  final project = fixture.project(source!.path);
  fixture.state.project = project.copyWith(
    name: locale.languageCode == 'zh' ? '比赛 1119' : 'Game 1119',
    candidates: [...project.candidates, _clip],
  );
  tester.binding.platformDispatcher.localeTestValue = locale;
  addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final root = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: root,
      child: BheMobileApp(appState: fixture.state),
    ),
  );
  await _advance(tester);
  await tester.tap(
    find.byTooltip(locale.languageCode == 'zh' ? '导出' : 'Export').first,
  );
  await _advance(tester);
  return (root: root, fixture: fixture, media: media);
}

Future<void> _openPicture(WidgetTester tester, {bool zh = false}) async {
  final picture = find.text(zh ? '画面' : 'Picture');
  await _scrollTo(tester, picture);
  await tester.tap(picture);
  await _advance(tester);
}

Future<void> _choosePortrait(WidgetTester tester) async {
  await _openPicture(tester);
  await tester.tap(find.text('Portrait 9:16 (follow ball)'));
  await _advance(tester);
  final done = find.text('Done');
  await tester.ensureVisible(done);
  await tester.tap(done);
  await _advance(tester);
}

Future<void> _finish(WidgetTester tester, MobileVideoFixture fixture) async {
  for (var i = 0; i < 60 && fixture.state.exporting; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(
    fixture.state.exporting,
    isFalse,
    reason: '${fixture.state.progressMessage} / ${fixture.state.errorMessage}',
  );
  await _advance(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = _captureFont;
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

  testWidgets('portrait framing is opt-in from the export page', (
    tester,
  ) async {
    final app = await _openExport(tester);
    await _scrollTo(tester, find.text('Picture'));
    expect(find.text('Original aspect'), findsOneWidget);
    await _choosePortrait(tester);
    expect(find.text('Portrait 9:16 (follow ball)'), findsOneWidget);
    expect(
      find.textContaining('Will export 2 portrait videos'),
      findsOneWidget,
    );
    _assertEnglish(tester);
    await _capture(tester, app.root, 'l525-1-portrait');
  });

  testWidgets('the framing row fits the English landscape export layout', (
    tester,
  ) async {
    final app = await _openExport(tester, size: const Size(844, 390));
    await _choosePortrait(tester);
    expect(find.text('Start export'), findsOneWidget);
    expect(tester.takeException(), isNull);
    _assertEnglish(tester);
    await _capture(tester, app.root, 'l525-2-landscape');
  });

  testWidgets('Chinese picker explains the crop and energy cost', (
    tester,
  ) async {
    final app = await _openExport(tester, locale: const Locale('zh'));
    await _openPicture(tester, zh: true);
    await tester.tap(find.text('竖屏 9:16（跟球）'));
    await _advance(tester);
    expect(find.textContaining('输出 1080 × 1920'), findsOneWidget);
    expect(find.textContaining('逐帧重新生成'), findsOneWidget);
    await _capture(tester, app.root, 'l525-3-picture-picker');
  });

  testWidgets('legacy HDR is selectable and shows the SDR color notice', (
    tester,
  ) async {
    final app = await _openExport(tester, hdr: true);
    await _openPicture(tester);
    await tester.tap(find.text('Portrait 9:16 (follow ball)'));
    await _advance(tester);
    expect(find.text(_hdrCopy), findsOneWidget);
    expect(find.textContaining('Cropping and upscaling'), findsOneWidget);
    _assertEnglish(tester);
    await _capture(tester, app.root, 'l525-4-hdr-sdr');
    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.text('Done'));
    await _advance(tester);
    expect(
      find.textContaining('Will export 2 portrait videos'),
      findsOneWidget,
    );
  });

  testWidgets('portrait merge shows named steps and the no-ball result', (
    tester,
  ) async {
    final app = await _openExport(tester);
    await _scrollTo(tester, find.text('Merge into one video'));
    await tester.tap(find.text('Merge into one video'));
    await _advance(tester);
    await _choosePortrait(tester);
    app.media.holdRender = Completer<void>();
    await tester.runAsync(() => tester.tap(find.text('Start export')));
    for (var i = 0; i < 60 && !app.media.enteredRender.isCompleted; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(app.media.enteredRender.isCompleted, isTrue);
    await _advance(tester);
    expect(find.text('Clip 1 of 2'), findsOneWidget);
    expect(find.text('Find ball and rim'), findsOneWidget);
    expect(find.text('Crop and render'), findsOneWidget);
    expect(find.text('Merge into one video'), findsOneWidget);
    _assertEnglish(tester);
    await _capture(tester, app.root, 'l525-5-progress');
    app.media.holdRender!.complete();
    await _finish(tester, app.fixture);
    expect(find.text('Exported 1 portrait video'), findsOneWidget);
    expect(
      find.text('Ball not found in 1 clip; framing may be off'),
      findsOneWidget,
    );
    _assertEnglish(tester);
    await _capture(tester, app.root, 'l525-7-result');
  });

  testWidgets('failure shows the clip and allows retry as original', (
    tester,
  ) async {
    final app = await _openExport(tester);
    await _choosePortrait(tester);
    app.media.failAtMs = _clip.startMs;
    await tester.runAsync(() => tester.tap(find.text('Start export')));
    await _finish(tester, app.fixture);
    expect(find.text('Clip 2 failed. Export stopped.'), findsOneWidget);
    expect(find.textContaining('running out of storage'), findsOneWidget);
    expect(find.text('Exported 1 portrait video'), findsOneWidget);
    expect(find.text('Export again'), findsOneWidget);
    _assertEnglish(tester);
    await _capture(tester, app.root, 'l525-6-failure');
    final previous = app.fixture.state.exportedPaths.single;
    await tester.runAsync(() => tester.tap(find.text('Use original aspect')));
    await _finish(tester, app.fixture);
    expect(app.media.callsTo('exportClip'), hasLength(2));
    expect(File(previous).existsSync(), isTrue);
  });
}
