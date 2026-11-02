import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:desktop/core/app_log.dart';
import 'package:desktop/features/home/project_name_dialog.dart';
import 'package:desktop/features/review/player_group_editor.dart';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/providers/player_groups_provider.dart';
import 'package:desktop/providers/project_state.dart';

String _log() {
  final file = appLogFileOverride!;
  return file.existsSync() ? file.readAsStringSync() : '';
}

void main() {
  setUp(() {
    final file = appLogFileOverride!;
    if (file.existsSync()) file.deleteSync();
  });

  group('项目名称弹窗', () {
    Future<void> pumpHost(WidgetTester tester) async {
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
      showProjectNameDialog(
        hostContext,
        initialName: '原名',
        onSubmit: (name) async => true,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('记录打开、获得焦点、失去焦点，不记输入内容', (tester) async {
      await pumpHost(tester);
      await tester.enterText(find.byType(TextField), '秘密新名字');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final log = _log();
      expect(log, contains('[info] [input] 打开项目名称输入框'));
      expect(log, contains('[info] [input] 项目名称 获得焦点'));
      expect(log, contains('[info] [input] 项目名称 失去焦点'));
      expect(log, isNot(contains('秘密新名字')));
      expect(log, isNot(contains('原名')));
    });

    testWidgets('关掉重开，打开与获得焦点各记两次', (tester) async {
      await pumpHost(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await pumpHost(tester);

      final log = _log();
      expect('打开项目名称输入框'.allMatches(log).length, 2);
      expect('项目名称 获得焦点'.allMatches(log).length, 2);
      expect('项目名称 失去焦点'.allMatches(log).length, 1);
    });
  });

  group('审核页备注弹窗', () {
    Future<void> pumpReview(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectProvider.overrideWith(
              () => _NoteReviewNotifier(
                const ProjectState(
                  job: {'state': 'completed'},
                  candidates: [
                    {
                      'id': 'candidate-1',
                      'event_time_ms': 12000,
                      'default_start_ms': 6000,
                      'default_end_ms': 15000,
                    },
                  ],
                ),
              ),
            ),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: BheLocalizations.localizationsDelegates,
            supportedLocales: BheLocalizations.supportedLocales,
            home: const Scaffold(body: ReviewScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('打开、获得焦点、失焦各记一行，不记输入内容', (tester) async {
      SharedPreferences.setMockInitialValues({
        onboardingStepsPrefsKey: allOnboardingStepIds,
      });
      await pumpReview(tester);

      await tester.tap(find.byTooltip('编辑备注'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '秘密备注');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final log = _log();
      expect(log, contains('[info] [input] 候选备注 打开'));
      expect(log, contains('[info] [input] 候选备注 获得焦点'));
      expect(log, contains('[info] [input] 候选备注 失去焦点'));
      expect(log, isNot(contains('秘密备注')));
    });
  });

  group('球员分组编辑窗口', () {
    Future<void> pumpEditor(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        playerGroupsPrefsKey: '[{"name":"Saturday","players":["Chris","Alex"]}]',
        defaultPlayerGroupPrefsKey: 'Saturday',
      });
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(playerGroupsProvider.notifier).ready;
      final group = container.read(playerGroupsProvider).first;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: BheLocalizations.localizationsDelegates,
            supportedLocales: BheLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => PlayerGroupEditor(group: group),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
    }

    testWidgets('窗口打开记一行，两个输入框各自记焦点变化，不记输入内容', (tester) async {
      await pumpEditor(tester);

      await tester.enterText(
        find.byKey(const Key('player-group-new-player')),
        '秘密球员',
      );
      await tester.tap(find.byKey(const Key('player-group-add-player')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final log = _log();
      expect(log, contains('[info] [input] 打开球员分组输入框'));
      expect(log, contains('[info] [input] 球员分组·分组名称 获得焦点'));
      expect(log, contains('[info] [input] 球员分组·球员姓名 获得焦点'));
      expect(log, contains('[info] [input] 球员分组·球员姓名 失去焦点'));
      expect(log, isNot(contains('秘密球员')));
      expect(log, isNot(contains('Chris')));
    });
  });
}

/// 不连引擎：备注保存只更新本地状态。
class _NoteReviewNotifier extends ProjectNotifier {
  _NoteReviewNotifier(this.initialState);

  final ProjectState initialState;

  @override
  ProjectState build() => initialState;

  @override
  Future<void> updateCandidateNote(String id, String note) async {
    state = state.copyWith(
      candidates: state.candidates
          .map(
            (candidate) => candidate['id']?.toString() == id
                ? <String, dynamic>{...candidate, 'note': note}
                : candidate,
          )
          .toList(),
    );
  }
}
