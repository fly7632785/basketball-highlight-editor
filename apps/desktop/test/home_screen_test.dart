import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/home/home_screen.dart';

void main() {
  testWidgets('loads and displays recent project cards', (tester) async {
    var loadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          onNewProject: () {},
          onReview: () {},
          onLoadRecentProjects: () async {
            loadCount += 1;
          },
          recentProjects: const [
            {
              'project_root': '/tmp/projects/game-1',
              'project': {'name': '周末训练赛'},
              'video': {'source_path': '/tmp/game.mp4'},
              'statistics': {'goal_count': 4, 'candidate_count': 7},
            },
          ],
        ),
      ),
    );
    await tester.pump();

    expect(loadCount, 1);
    expect(find.text('最近项目'), findsOneWidget);
    expect(find.text('周末训练赛'), findsOneWidget);
    expect(find.text('4 个已确认 · 7 个候选'), findsOneWidget);
  });

  testWidgets('opens a recent project card', (tester) async {
    String? openedRoot;
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          onNewProject: () {},
          onReview: () {},
          onOpenRecentProject: (root) async {
            openedRoot = root;
          },
          recentProjects: const [
            {
              'project_root': '/tmp/projects/game-1',
              'project': {'name': '周末训练赛'},
            },
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('周末训练赛'));
    await tester.tap(find.text('周末训练赛'));
    await tester.pump();

    expect(openedRoot, '/tmp/projects/game-1');
  });
}
