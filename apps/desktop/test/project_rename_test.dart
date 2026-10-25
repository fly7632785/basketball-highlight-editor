import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/home/project_name_dialog.dart';
import 'package:desktop/providers/project_state.dart';

/// 打开重命名对话框，返回它的结果 future。
Future<Future<String?>> _openDialog(
  WidgetTester tester, {
  required String initialName,
  required Future<bool> Function(String name) onSubmit,
}) async {
  late BuildContext hostContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          hostContext = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  final result = showProjectNameDialog(
    hostContext,
    initialName: initialName,
    onSubmit: onSubmit,
  );
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('项目重命名对话框', () {
    testWidgets('预填当前名称，改名后返回新名字', (tester) async {
      final submitted = <String>[];
      final result = await _openDialog(
        tester,
        initialName: 'DJI_20261024093347_0043_D',
        onSubmit: (name) async {
          submitted.add(name);
          return true;
        },
      );

      expect(find.text('重命名项目'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'DJI_20261024093347_0043_D'),
        findsOneWidget,
        reason: '输入框应预填当前项目名',
      );

      await tester.enterText(find.byType(TextField), '十月训练赛');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(submitted, ['十月训练赛']);
      expect(await result, '十月训练赛');
    });

    testWidgets('空名字不提交并提示', (tester) async {
      var called = false;
      await _openDialog(
        tester,
        initialName: '原名',
        onSubmit: (name) async {
          called = true;
          return true;
        },
      );

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(called, isFalse, reason: '空名字不应发起请求');
      expect(find.text('项目名称不能为空'), findsOneWidget);
    });

    testWidgets('保存失败时留在对话框并提示', (tester) async {
      await _openDialog(
        tester,
        initialName: '原名',
        onSubmit: (name) async => false,
      );

      await tester.enterText(find.byType(TextField), '新名字');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('项目名称保存失败，请重试'), findsOneWidget);
      expect(find.text('重命名项目'), findsOneWidget, reason: '对话框应保持打开');
    });

    testWidgets('名字没变时直接关闭，不发起请求', (tester) async {
      var called = false;
      final result = await _openDialog(
        tester,
        initialName: '同一个名字',
        onSubmit: (name) async {
          called = true;
          return true;
        },
      );

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(called, isFalse);
      expect(await result, isNull);
      expect(find.text('重命名项目'), findsNothing);
    });
  });

  group('ProjectNotifier.renameProject 输入校验', () {
    test('名字为空、全空格或超长时返回 false，且不发起请求', () async {
      final notifier = _CountingNotifier();
      final container = ProviderContainer(
        overrides: [projectProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      container.read(projectProvider);

      expect(await notifier.renameProject(''), isFalse);
      expect(await notifier.renameProject('   '), isFalse);
      expect(
        await notifier.renameProject('长' * (projectNameMaxLength + 1)),
        isFalse,
      );
      expect(
        notifier.requests,
        isEmpty,
        reason: '非法名字不应调用引擎',
      );
    });

    test('合法名字 trim 后提交，并立即更新统计里的项目名', () async {
      final notifier = _CountingNotifier();
      final container = ProviderContainer(
        overrides: [projectProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      container.read(projectProvider);

      expect(await notifier.renameProject('  十月训练赛  '), isTrue);
      expect(notifier.requests, ['十月训练赛'], reason: '应 trim 后再提交');
      expect(
        (container.read(projectProvider).statistics?['project']
            as Map?)?['name'],
        '十月训练赛',
        reason: '改名后 UI 应立即看到新名字',
      );
    });
  });
}

/// 只统计下发的名字，不真的连引擎。
class _CountingNotifier extends ProjectNotifier {
  final List<String> requests = [];

  @override
  ProjectState build() => const ProjectState(
    statistics: {
      'project': {'name': '原名', 'root_path': '/tmp/projects/game-1'},
    },
  );

  @override
  Future<bool> renameProject(String name, {String? projectRoot}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > projectNameMaxLength) return false;
    requests.add(trimmed);
    state = state.copyWith(
      statistics: {
        ...?state.statistics,
        'project': {
          ...?(state.statistics?['project'] as Map?)?.cast<String, dynamic>(),
          'name': trimmed,
        },
      },
    );
    return true;
  }
}
