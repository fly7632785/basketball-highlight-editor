import 'package:desktop/features/review/tier_selection.dart';
import 'dart:async';

import 'package:desktop/core/engine_client.dart';
import 'package:desktop/core/engine_session.dart';
import 'package:desktop/core/project_session.dart';
import 'package:desktop/providers/notice_provider.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tag toggle and clear undo restore the whole group alongside review undo', () async {
    final h = await _Harness.create();
    await h.notifier.changeCandidateTags('A', toggleId:'p1');
    await h.notifier.changeCandidateTags('A', toggleId:'p2');
    expect(candidateTagIds(h.local('A')), ['p1','p2']);
    await h.notifier.reviewCandidate('A','excluded');
    await h.notifier.changeCandidateTags('A', replaceIds:[]);
    expect(candidateTagIds(h.local('A')), isEmpty);
    await h.notifier.undoReview();
    expect(candidateTagIds(h.local('A')), ['p1','p2']);
    expect(h.local('A')['review_status'], 'excluded');
    await h.notifier.undoReview();
    expect(h.local('A')['review_status'], 'pending');
    expect(candidateTagIds(h.local('A')), ['p1','p2']);
    await h.notifier.undoReview();
    expect(candidateTagIds(h.local('A')), ['p1']);
  });

  test('相同的待保存审核共享失败结果，回滚后可以重试', () async {
    final h = await _Harness.create();
    final gate = h.transport.holdReview(h.root, 'A');
    final first = h.notifier.reviewCandidate('A', 'excluded');
    await gate.entered.future;
    var duplicateCompleted = false;
    final duplicate = h.notifier.reviewCandidate('A', 'excluded');
    unawaited(duplicate.then((_) => duplicateCompleted = true));
    await Future<void>.delayed(Duration.zero);
    final completedBeforeSave = duplicateCompleted;

    gate.release.completeError(
      const EngineException('ENGINE_ERROR', 'save failed'),
    );
    final results = await Future.wait([first, duplicate]);

    expect(completedBeforeSave, isFalse);
    expect(results, [false, false]);
    expect(h.local('A')['review_status'], 'pending');
    expect(h.persisted('A')['review_status'], 'pending');
    expect(h.transport.reviewCalls, hasLength(1));
    expect(await h.notifier.reviewCandidate('A', 'excluded'), isTrue);
    expect(h.persisted('A')['review_status'], 'excluded');
    expect(h.transport.reviewCalls, hasLength(2));
  });

  test('静默审核排队中再次要求提示时，保存成功后只提示一次', () async {
    final h = await _Harness.create();
    final gate = h.transport.holdReview(h.root, 'A');
    final first = h.notifier.reviewCandidate('A', 'excluded', showNotice: false);
    final duplicate = h.notifier.reviewCandidate('A', 'excluded');
    await gate.entered.future;
    gate.release.complete();

    expect(await Future.wait([first, duplicate]), [true, true]);
    expect(h.transport.reviewCalls, hasLength(1));
    expect(
      h.container.read(noticeProvider).where((n) => n.title == '已排除候选'),
      hasLength(1),
    );
  });

  test('尚未启动的相同审核也只发送一次请求', () async {
    final h = await _Harness.create();
    final gate = h.transport.holdReview(h.root, 'A');
    final first = h.notifier.reviewCandidate('A', 'included');
    final duplicate = h.notifier.reviewCandidate('A', 'goal');
    final shared = identical(first, duplicate);
    await gate.entered.future;
    gate.release.complete();

    expect(await Future.wait([first, duplicate]), [true, true]);
    expect(shared, isTrue);
    expect(h.transport.reviewCalls, hasLength(1));
    await h.notifier.undoReview();
    expect(h.persisted('A')['review_status'], 'pending');
    await h.notifier.undoReview();
    expect(h.transport.reviewCalls, hasLength(2));
  });

  for (final secondSucceeds in [false, true]) {
    test('连续审核首次失败、第二次${secondSucceeds ? '成功后撤销' : '失败后回滚'}恢复已保存状态', () async {
      final h = await _Harness.create();
      h.persisted('A').addAll({
        'review_reason': 'uncertain',
        'note': 'existing note',
      });
      await h.notifier.refreshCandidates();
      final firstGate = h.transport.holdReview(h.root, 'A');
      final secondGate = h.transport.holdReview(h.root, 'A');
      final first = h.notifier.reviewCandidate(
        'A',
        'excluded',
        reason: 'no_shot',
      );
      await firstGate.entered.future;
      final second = h.notifier.reviewCandidate('A', 'goal', reason: 'made');
      firstGate.release.completeError(
        const EngineException('ENGINE_ERROR', 'first save failed'),
      );
      expect(await first, isFalse);
      await secondGate.entered.future;
      final optimisticStatus = h.local('A')['review_status'];
      final savedStatus = h.persisted('A')['review_status'];
      if (secondSucceeds) {
        secondGate.release.complete();
      } else {
        secondGate.release.completeError(
          const EngineException('ENGINE_ERROR', 'second save failed'),
        );
      }
      expect(await second, secondSucceeds);

      expect(optimisticStatus, 'goal');
      expect(savedStatus, 'pending');
      expect(
        h.local('A')['review_status'],
        secondSucceeds ? 'goal' : 'pending',
      );
      expect(
        h.persisted('A')['review_status'],
        secondSucceeds ? 'goal' : 'pending',
      );
      await h.notifier.undoReview();
      expect(h.local('A')['review_status'], 'pending');
      expect(h.local('A')['selection_status'], 'included');
      expect(h.local('A')['review_reason'], 'uncertain');
      expect(h.local('A')['note'], 'existing note');
      expect(h.persisted('A')['review_status'], 'pending');
      expect(h.persisted('A')['review_reason'], 'uncertain');
      expect(h.persisted('A')['note'], 'existing note');
      expect(h.statusCalls, [
        'A:excluded',
        'A:goal',
        if (secondSucceeds) 'A:pending',
      ]);
      await h.notifier.undoReview();
      expect(h.transport.reviewCalls, hasLength(secondSucceeds ? 3 : 2));
    });
  }

  test('不同原因分别排队，较早请求完成不清除较新待保存记录', () async {
    final h = await _Harness.create();
    final firstGate = h.transport.holdReview(h.root, 'A');
    final secondGate = h.transport.holdReview(h.root, 'A');
    final first = h.notifier.reviewCandidate(
      'A',
      'excluded',
      reason: 'no_shot',
    );
    await firstGate.entered.future;
    final second = h.notifier.reviewCandidate(
      'A',
      'excluded',
      reason: 'uncertain',
    );
    firstGate.release.complete();
    expect(await first, isTrue);
    await secondGate.entered.future;
    final duplicate = h.notifier.reviewCandidate(
      'A',
      'excluded',
      reason: 'uncertain',
    );
    final shared = identical(second, duplicate);
    secondGate.release.complete();

    expect(await Future.wait([second, duplicate]), [true, true]);
    expect(shared, isTrue);
    expect(h.transport.reviewCalls.map((c) => c['reason']), [
      'no_shot',
      'uncertain',
    ]);
    expect(h.persisted('A')['review_reason'], 'uncertain');
    await h.notifier.undoReview();
    expect(h.persisted('A')['review_status'], 'excluded');
    expect(h.persisted('A')['review_reason'], 'no_shot');
    await h.notifier.undoReview();
    expect(h.persisted('A')['review_status'], 'pending');
  });

  for (final reopenSameProject in [true, false]) {
    test('${reopenSameProject ? '关闭重开' : '切换项目'}后不复用旧审核结果或回滚新状态', () async {
      final h = await _Harness.create();
      final oldGate = h.transport.holdReview(h.root, 'A');
      final old = h.notifier.reviewCandidate('A', 'excluded');
      await oldGate.entered.future;
      final oldDuplicate = h.notifier.reviewCandidate('A', 'excluded');
      final nextRoot = reopenSameProject ? h.root : '/virtual/review-project-2';
      h.notifier.closeProject();
      h.attach(nextRoot, videoId: 'video-2');
      await h.notifier.refreshCandidates();
      final newGate = h.transport.holdReview(nextRoot, 'A');
      final next = h.notifier.reviewCandidate('A', 'excluded');
      final nextDuplicate = h.notifier.reviewCandidate('A', 'excluded');
      oldGate.release.completeError(
        const EngineException('ENGINE_ERROR', 'old save failed'),
      );
      final oldResults = await Future.wait([old, oldDuplicate]);
      await newGate.entered.future;
      final lateDuplicate = h.notifier.reviewCandidate('A', 'excluded');
      final shared =
          identical(next, nextDuplicate) && identical(next, lateDuplicate);
      final localBeforeSave = h.local('A')['review_status'];
      newGate.release.complete();

      expect(await Future.wait([next, nextDuplicate, lateDuplicate]), [
        true,
        true,
        true,
      ]);
      expect(oldResults, [false, false]);
      expect(shared, isTrue);
      expect(localBeforeSave, 'excluded');
      expect(h.transport.reviewCalls, hasLength(2));
      expect(h.transport.reviewCalls.last['project_root'], nextRoot);
      await h.notifier.undoReview();
      expect(h.persisted('A')['review_status'], 'pending');
      await h.notifier.undoReview();
      expect(h.transport.reviewCalls, hasLength(3));
    });
  }

  test('A 已保存而 B 待保存时撤销，先恢复 B，再恢复 A', () async {
    final h = await _Harness.create();
    await h.notifier.reviewCandidate('A', 'excluded');
    final gate = h.transport.holdReview(h.root, 'B');
    final pending = h.notifier.reviewCandidate('B', 'excluded');
    await gate.entered.future;
    final undo = h.notifier.undoReview();
    gate.release.complete();
    expect(await pending, isTrue);
    await undo;

    expect(h.persisted('A')['review_status'], 'excluded');
    expect(h.persisted('B')['review_status'], 'pending');
    expect(h.local('B')['review_status'], 'pending');
    await h.notifier.undoReview();
    expect(h.statusCalls, [
      'A:excluded',
      'B:excluded',
      'B:pending',
      'A:pending',
    ]);
    await h.notifier.undoReview();
    expect(h.transport.reviewCalls, hasLength(4));
  });

  test('首次审核尚未保存且历史为空时，撤销仍等待并恢复它', () async {
    final h = await _Harness.create();
    final gate = h.transport.holdReview(h.root, 'A');
    final review = h.notifier.reviewCandidate('A', 'excluded');
    await gate.entered.future;
    final undo = h.notifier.undoReview();
    gate.release.complete();
    expect(await review, isTrue);
    await undo;

    expect(h.statusCalls, ['A:excluded', 'A:pending']);
    expect(h.local('A')['review_status'], 'pending');
    expect(h.persisted('A')['review_status'], 'pending');
  });

  test('最新排队审核失败时，撤销最近一次成功的审核', () async {
    final h = await _Harness.create();
    await h.notifier.reviewCandidate('A', 'excluded');
    final gate = h.transport.holdReview(h.root, 'B');
    final review = h.notifier.reviewCandidate('B', 'excluded');
    await gate.entered.future;
    final undo = h.notifier.undoReview();
    gate.release.completeError(
      const EngineException('ENGINE_ERROR', 'save failed'),
    );
    expect(await review, isFalse);
    await undo;

    expect(h.statusCalls, ['A:excluded', 'B:excluded', 'A:pending']);
    expect(h.local('A')['review_status'], 'pending');
    expect(h.local('B')['review_status'], 'pending');
    await h.notifier.undoReview();
    expect(h.transport.reviewCalls, hasLength(3));
  });

  test('并发撤销共享一次操作，后续撤销仍能恢复前一项', () async {
    final h = await _Harness.create();
    await h.notifier.reviewCandidate('A', 'excluded');
    await h.notifier.reviewCandidate('B', 'excluded');
    final gate = h.transport.holdReview(h.root, 'B');
    final first = h.notifier.undoReview();
    await gate.entered.future;
    var duplicateCompleted = false;
    final duplicate = h.notifier.undoReview();
    unawaited(duplicate.then((_) => duplicateCompleted = true));
    await Future<void>.delayed(Duration.zero);
    final completedBeforeSave = duplicateCompleted;
    gate.release.complete();
    await Future.wait([first, duplicate]);

    expect(completedBeforeSave, isFalse);
    expect(h.statusCalls, ['A:excluded', 'B:excluded', 'B:pending']);
    await h.notifier.undoReview();
    expect(h.statusCalls, [
      'A:excluded',
      'B:excluded',
      'B:pending',
      'A:pending',
    ]);
  });

  test('撤销保存失败时保留历史，重试可以恢复同一项', () async {
    final h = await _Harness.create();
    await h.notifier.reviewCandidate('A', 'excluded');
    final gate = h.transport.holdReview(h.root, 'A');
    final undo = h.notifier.undoReview();
    await gate.entered.future;
    gate.release.completeError(
      const EngineException('ENGINE_ERROR', 'undo failed'),
    );
    await undo;

    expect(h.local('A')['review_status'], 'excluded');
    expect(h.persisted('A')['review_status'], 'excluded');
    expect(
      h.container.read(noticeProvider).last.severity,
      NoticeSeverity.error,
    );
    await h.notifier.undoReview();
    expect(h.statusCalls, ['A:excluded', 'A:pending', 'A:pending']);
    expect(h.persisted('A')['review_status'], 'pending');
    await h.notifier.undoReview();
    expect(h.transport.reviewCalls, hasLength(3));
  });

  test('等待保存期间项目代次变化，旧撤销不写入或消费新项目历史', () async {
    final h = await _Harness.create();
    await h.notifier.reviewCandidate('A', 'excluded');
    final gate = h.transport.holdReview(h.root, 'B');
    final review = h.notifier.reviewCandidate('B', 'excluded');
    await gate.entered.future;
    final switching = h.notifier.startNewProject();
    final undo = h.notifier.undoReview();
    gate.release.complete();
    expect(await review, isTrue);
    expect(await switching, isTrue);
    await undo;

    expect(h.statusCalls, ['A:excluded', 'B:excluded']);
    expect(h.container.read(projectProvider).candidates, isEmpty);
    expect(
      h.container.read(noticeProvider).any((n) => n.title == '已撤销上一次审核'),
      isFalse,
    );
    expect(
      h.container
          .read(noticeProvider)
          .any((n) => n.severity == NoticeSeverity.error),
      isFalse,
    );
    h.attach('/virtual/review-project-2', videoId: 'video-2');
    await h.notifier.refreshCandidates();
    await h.notifier.reviewCandidate('A', 'excluded');
    await h.notifier.undoReview();
    expect(h.persisted('A')['review_status'], 'pending');
    expect(h.transport.reviewCalls.last['project_root'], h.root);
  });
}

class _Gate {
  final entered = Completer<void>();
  final release = Completer<void>();
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
    addTearDown(() async {
      await notifier.flushReviewQueue();
      container.dispose();
    });
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
  List<String> get statusCalls => [
    for (final call in transport.reviewCalls)
      '${call['candidate_id']}:${call['status']}',
  ];
}

class _ReviewTransport implements EngineTransport {
  final projects = <String, Map<String, JsonMap>>{};
  final reviewCalls = <JsonMap>[];
  final gates = <(String, String), List<_Gate>>{};

  _Gate holdReview(String root, String id) {
    final gate = _Gate();
    gates.putIfAbsent((root, id), () => []).add(gate);
    return gate;
  }

  @override
  Future<JsonMap> request(String command, JsonMap payload) async {
    final root = payload['project_root'] as String;
    switch (command) {
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
        if(command == 'set_candidate_players') { ids.clear(); ids.addAll((payload['player_ids'] as List).cast<String>()); }
        else if(command == 'remove_candidate_player') { ids.remove(payload['player_id']); }
        else { ids.add(payload['player_id'] as String); }
        projects[root]![id] = {...candidate, 'tags':[for(final id in ids) {'id':id,'name':id}]};
        return {'updated':1};
      case 'review_candidate':
        reviewCalls.add(Map<String, dynamic>.from(payload));
        final id = payload['candidate_id'] as String;
        final pending = gates[(root, id)];
        if (pending != null && pending.isNotEmpty) {
          final gate = pending.removeAt(0);
          gate.entered.complete();
          await gate.release.future;
        }
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
