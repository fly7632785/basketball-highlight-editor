import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/home/home_screen.dart';
import 'package:desktop/providers/project_state.dart';

/// 假 Notifier:返回固定 ProjectState(含最近项目),并记录 openProject 调用。
class _FakeProjectNotifier extends ProjectNotifier {
  String? openedRoot;
  String? deletedRoot;

  @override
  ProjectState build() => const ProjectState(
    recentProjects: [
      {
        'project_root': '/tmp/projects/game-1',
        'project': {'name': '周末训练赛'},
        'video': {'source_path': '/tmp/game.mp4', 'duration_ms': 3723000},
        'statistics': {'included_count': 4, 'candidate_count': 7},
      },
    ],
  );

  @override
  Future<bool> openProject(String root) async {
    openedRoot = root;
    return true;
  }

  @override
  Future<void> deleteProject(String root) async {
    deletedRoot = root;
  }

  @override
  Future<void> loadRecentProjects() async {
    state = state.copyWith(recentProjects: const []);
  }
}

void main() {
  testWidgets('renders project workspace and recent project row', (
    tester,
  ) async {
    late _FakeProjectNotifier fake;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(() {
            fake = _FakeProjectNotifier();
            return fake;
          }),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('项目库'), findsOneWidget);
    expect(find.text('最近使用'), findsOneWidget);
    expect(find.text('周末训练赛'), findsOneWidget);
    expect(find.text('已保留'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('tapping a recent project card opens it', (tester) async {
    late _FakeProjectNotifier fake;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(() {
            fake = _FakeProjectNotifier();
            return fake;
          }),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('周末训练赛'));
    await tester.tap(find.text('周末训练赛'));
    await tester.pumpAndSettle();

    expect(fake.openedRoot, '/tmp/projects/game-1');
  });

  testWidgets(
    'deleting a recent project is directly discoverable and confirmed',
    (tester) async {
      late _FakeProjectNotifier fake;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectProvider.overrideWith(() {
              fake = _FakeProjectNotifier();
              return fake;
            }),
          ],
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final menuButton = find.byTooltip('项目操作');
      expect(menuButton, findsOneWidget);
      await tester.ensureVisible(menuButton);
      await tester.tap(menuButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除项目').first);
      await tester.pumpAndSettle();

      expect(find.text('删除项目？'), findsOneWidget);
      await tester.tap(find.text('删除项目').last);
      await tester.pumpAndSettle();

      expect(fake.deletedRoot, '/tmp/projects/game-1');
      expect(find.text('周末训练赛'), findsNothing);
    },
  );

  testWidgets('shows empty state when there are no recent projects', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [projectProvider.overrideWith(_EmptyProjectNotifier.new)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有项目'), findsOneWidget);
  });
}

class _EmptyProjectNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();
}
