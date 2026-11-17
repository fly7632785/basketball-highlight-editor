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
  Future<bool> openProject(
    String root, {
    String? relinkVideoButtonLabel,
    String? videoTypeLabel,
  }) async {
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
  testWidgets('renders slogan and recent project card', (tester) async {
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

    expect(find.text('把整场比赛，变成你的高光。'), findsOneWidget);
    expect(find.text('最近项目'), findsOneWidget);
    expect(find.text('周末训练赛'), findsOneWidget);
    expect(find.textContaining('4 保留'), findsOneWidget);
  });

  testWidgets('unknown recent counts never appear as an empty project', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [projectProvider.overrideWith(_UnknownCountsNotifier.new)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('待同步'), findsOneWidget);
    expect(find.text('暂无候选'), findsNothing);
    expect(find.textContaining('0 保留'), findsNothing);
    expect(find.textContaining('0 候选'), findsNothing);
    expect(find.textContaining('— ·'), findsOneWidget);
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

      final actions = find.byTooltip('项目操作');
      expect(actions, findsOneWidget);
      await tester.ensureVisible(actions);
      await tester.tap(actions);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除项目'));
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
    expect(find.text('还没有打开的项目'), findsOneWidget);
  });

  testWidgets('project covers render and fall back without crashing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [projectProvider.overrideWith(_CoverProjectNotifier.new)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('project-cover-/p/cover')), findsOneWidget);
    expect(find.byKey(const ValueKey('current-project-cover')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('current project card shows progress and the next step', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [projectProvider.overrideWith(_CurrentProjectNotifier.new)],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('继续上次'), findsOneWidget);
    expect(find.text('三分'), findsOneWidget);
    expect(find.text('三分.mp4'), findsOneWidget);
    expect(find.text('待审核'), findsOneWidget);
    expect(find.text('继续审核'), findsOneWidget);
    expect(find.text('01:57'), findsOneWidget);
  });
}

class _CoverProjectNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState(
    video: {'id': 'v1', 'duration_ms': 117000, 'source_path': '/v/a.mp4'},
    statistics: {
      'project': {'name': '封面项目'},
    },
    candidates: [
      {'id': 'c1', 'review_status': 'pending'},
    ],
    recentProjects: [
      {
        'project_root': '/p/cover',
        'project': {'name': '封面项目'},
        'video': {'id': 'v1', 'source_path': '/v/a.mp4', 'duration_ms': 117000},
        'statistics': {'included_count': 1, 'candidate_count': 1},
        'cover_path': '/missing/cover.jpg',
      },
    ],
  );
}

class _CurrentProjectNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState(
    video: {'id': 'v1', 'duration_ms': 117000, 'source_path': '/v/三分.mp4'},
    statistics: {
      'project': {'name': '三分'},
    },
    candidates: [
      {'id': 'c1', 'review_status': 'pending'},
      {'id': 'c2', 'review_status': 'excluded'},
    ],
  );
}

class _EmptyProjectNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();
}

class _UnknownCountsNotifier extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState(
    recentProjects: [
      {
        'project_root': '/tmp/synthetic-unknown',
        'project': {'name': '计数未知'},
        'video': {'duration_ms': 60000},
        'statistics': {'candidate_count': null, 'included_count': null},
      },
    ],
  );
}
