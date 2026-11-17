import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:desktop/providers/onboarding_provider.dart';
import 'package:desktop/features/review/review_screen.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:desktop/features/review/tier_selection.dart';

import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual X on weak auto exclusion must send a user decision', () async {
    final h = await _Harness.create();
    h.persisted('A').addAll({
      'tier': 'suspect',
      'tier_source': 'algorithm',
      'review_status': 'excluded',
      'review_reason': 'auto_rim_check',
      'selection_status': 'pending',
      'tags': [
        {'id': 'p1', 'name': 'Synthetic'},
      ],
    });
    await h.notifier.refreshCandidates();
    final success = await h.notifier.reviewCandidate(
      'A',
      'excluded',
      showNotice: false,
    );
    expect(success, isTrue);
    expect(
      h.transport.reviewCalls,
      hasLength(1),
      reason:
          'Manual rejection must replace an automatic reason, even if the legacy status string is already excluded.',
    );
    expect(h.local('A')['tier'], 'excluded');
    expect(h.persisted('A')['review_reason'], isNull);
    expect(h.local('A')['tier_source'], 'user');
    expect(
      TierSelection(tiers: {'excluded'}, tags: {'p1'}).apply([h.local('A')]),
      hasLength(1),
    );
    await h.notifier.undoReview();
    expect(h.local('A')['tier'], 'suspect');
    expect(h.local('A')['tier_source'], 'algorithm');
    expect(h.local('A')['review_reason'], 'auto_rim_check');
  });
  test(
    'matching automatic goal is saved as a human decision only once',
    () async {
      final h = await _Harness.create();
      h.persisted('A').addAll({
        'tier': 'must',
        'tier_source': 'algorithm',
        'review_status': 'goal',
        'review_reason': null,
      });
      await h.notifier.refreshCandidates();
      expect(
        await h.notifier.reviewCandidate('A', 'goal', showNotice: false),
        isTrue,
      );
      expect(h.transport.reviewCalls, hasLength(1));
      expect(h.local('A')['tier_source'], 'user');
      expect(
        await h.notifier.reviewCandidate('A', 'goal', showNotice: false),
        isTrue,
      );
      expect(h.transport.reviewCalls, hasLength(1));
    },
  );
  testWidgets(
    'actual X key on an automatic excluded suspect saves manual exclusion',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        onboardingStepsPrefsKey: allOnboardingStepIds,
      });
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = await _Harness.create();
      h.persisted('A').addAll({
        'tier': 'suspect',
        'tier_source': 'algorithm',
        'review_status': 'excluded',
        'review_reason': 'auto_rim_check',
        'selection_status': 'pending',
        'event_time_ms': 5000,
        'default_start_ms': 4000,
        'default_end_ms': 6000,
      });
      h.persisted('B').addAll({
        'tier': 'excluded',
        'review_status': 'excluded',
      });
      await h.notifier.refreshCandidates();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: appTheme(Brightness.dark),
            home: const Scaffold(body: ReviewScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('candidate-row-A')), findsOneWidget);
      final must = tester.widget<Material>(
        find.byKey(const ValueKey('review-status-must')),
      );
      final suspect = tester.widget<Material>(
        find.byKey(const ValueKey('review-status-suspect')),
      );
      expect(
        must.color,
        isNot(suspect.color),
        reason: 'Only suspect has the selected segment background.',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pumpAndSettle();

      final actualCalls = h.transport.reviewCalls.length;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        actualCalls,
        1,
        reason: 'The actual X key must persist the human decision.',
      );
      expect(h.local('A')['tier'], 'excluded');
    },
  );
}

class _Harness {
  _Harness(this.transport, this.session, this.container, this.notifier);

  final _ReviewTransport transport;
  final ProjectSession session;
  final ProviderContainer container;
  final ProjectNotifier notifier;
  String get root => session.projectRoot!;

  static Future<_Harness> create() async {
    final transport = _ReviewTransport();
    final session = ProjectSession(EngineSession(transport));
    final container = ProviderContainer(
      overrides: [projectSessionProvider.overrideWithValue(session)],
    );
    final notifier = container.read(projectProvider.notifier);
    final harness = _Harness(transport, session, container, notifier);
    harness.attach('/virtual/review-project-1');
    addTearDown(container.dispose);
    await notifier.refreshCandidates();
    return harness;
  }

  void attach(String root, {String videoId = 'video-1'}) {
    transport.projects.putIfAbsent(
      root,
      () => {
        for (final id in ['A', 'B'])
          id: <String, dynamic>{
            'id': id,
            'review_status': 'pending',
            'selection_status': 'included',
          },
      },
    );
    session.restore(
      ProjectSessionCheckpoint(
        projectRoot: root,
        projectId: root,
        videoId: videoId,
      ),
    );
  }

  JsonMap local(String id) => container
      .read(projectProvider)
      .candidates
      .singleWhere((c) => c['id'] == id);
  JsonMap persisted(String id) => transport.projects[root]![id]!;
}

class _ReviewTransport implements EngineTransport {
  final projects = <String, Map<String, JsonMap>>{};
  final reviewCalls = <JsonMap>[];
  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    final root = payload['project_root'] as String;
    switch (command) {
      case 'start_review':
        return {'review_started_at': 'synthetic'};
      case 'extract_preview':
        return {'path': null};
      case 'list_candidates':
        return {
          'candidates': [
            for (final c in projects[root]!.values)
              Map<String, dynamic>.from(c),
          ],
          'players': <JsonMap>[],
        };
      case 'add_candidate_player':
      case 'remove_candidate_player':
      case 'set_candidate_players':
        final id = payload['candidate_id'] as String;
        final candidate = projects[root]![id]!;
        final ids = candidateTagIds(candidate).toSet();
        if (command == 'set_candidate_players') {
          ids.clear();
          ids.addAll((payload['player_ids'] as List).cast<String>());
        } else if (command == 'remove_candidate_player') {
          ids.remove(payload['player_id']);
        } else {
          ids.add(payload['player_id'] as String);
        }
        projects[root]![id] = {
          ...candidate,
          'tags': [
            for (final id in ids) {'id': id, 'name': id},
          ],
        };
        return {'updated': 1};
      case 'review_candidate':
        reviewCalls.add(Map<String, dynamic>.from(payload));
        final id = payload['candidate_id'] as String;
        final status = payload['status'] as String;
        projects[root]![id] = {
          ...projects[root]![id]!,
          'review_status': status,
          'selection_status': status == 'excluded' ? 'excluded' : 'included',
          'review_reason': payload['reason'],
          'note': payload['note'],
        };
        return {'updated': true};
      case 'get_statistics':
        return {'statistics': <String, dynamic>{}};
      default:
        throw StateError('Unexpected review command: $command');
    }
  }
}
