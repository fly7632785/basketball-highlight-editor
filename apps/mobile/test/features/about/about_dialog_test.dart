// G-L060a：「关于」入口显示版本号；dev 构建显示「开发版」。
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() async {
    await fixture.close();
  });

  for (final (language, english) in [('zh', false), ('en', true)]) {
    testWidgets('about dialog shows app and engine version ($language)', (
      tester,
    ) async {
      tester.binding.platformDispatcher.localeTestValue = Locale(language);
      addTearDown(
        tester.binding.platformDispatcher.clearLocaleTestValue,
      );
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(BheMobileApp(appState: fixture.state));
      await tester.pump();
      await tester.tap(find.byTooltip(english ? 'More' : '更多').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.text(english ? 'About' : '关于'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // 本地测试构建没有注入 BHE_VERSION，应显示「开发版/Dev build」。
      expect(
        find.textContaining(english ? 'Dev build' : '开发版'),
        findsOneWidget,
      );
      // 引擎版本行存在（原生不可用时显示占位，不隐藏行）。
      expect(
        find.textContaining(english ? 'Analysis engine version' : '分析引擎版本'),
        findsOneWidget,
      );
      // 反馈入口复用现有反馈。
      expect(
        find.text(english ? 'Report now' : '现在反馈'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
