import 'package:desktop/features/feedback/feedback_dialog.dart';
import 'package:desktop/features/feedback/feedback_guide.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('反馈窗口显示错误详情，复制后剪贴板里有诊断信息', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: const Scaffold(
          body: FeedbackDialog(error: '导出失败: ffmpeg 退出码 234'),
        ),
      ),
    );

    final errorBox = find.byKey(const Key('feedback-error'));
    expect(errorBox, findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.descendant(
              of: errorBox,
              matching: find.byType(SelectableText),
            ),
          )
          .data,
      '导出失败: ffmpeg 退出码 234',
    );

    // 复制时要读本地日志文件，真实 IO 需要在 runAsync 里完成。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('feedback-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(copied, contains('BHE 诊断信息'));
    expect(copied, contains('ffmpeg 退出码 234'));
    expect(find.text('已复制，可以粘贴发给我了'), findsOneWidget);
  });

  testWidgets('第一次分析完成时高亮反馈入口，只出现一次', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: FeedbackGuideHost(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: KeyedSubtree(
                  key: feedbackSidebarKey,
                  child: const SizedBox(width: 120, height: 40),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    container
        .read(noticeProvider.notifier)
        .push(
          const NoticeMessage(
            id: 'done',
            severity: NoticeSeverity.success,
            title: '分析完成，候选片段已准备好',
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byKey(const Key('feedback-guide')), findsOneWidget);
    expect(find.text('遇到问题？点这里反馈'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pump();
    expect(find.byKey(const Key('feedback-guide')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(feedbackGuideShownKey), isTrue);

    container
        .read(noticeProvider.notifier)
        .push(
          const NoticeMessage(
            id: 'fail',
            severity: NoticeSeverity.error,
            title: '导出失败',
          ),
        );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    expect(find.byKey(const Key('feedback-guide')), findsNothing);
  });
}
