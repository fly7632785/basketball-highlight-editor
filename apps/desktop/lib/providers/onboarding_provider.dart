import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import 'project_state.dart' show recentProjectRootsPrefsKey;

/// 旧版（只按页面记）的键，只用来迁移。
const String onboardingLegacySeenPrefsKey = 'bhe.onboarding.seen';
const String onboardingStepsPrefsKey = 'bhe.onboarding.steps_seen';

const String onboardingImportPage = 'import';
const String onboardingReviewPage = 'review';
const String onboardingExportPage = 'export';

/// 每页有哪些步骤（按出现顺序）。“看过”按步骤记：升级后新增的步骤只弹新的，
/// 已经看过的不重复。新增步骤时在这里登记，并在对应页面写文案。
/// 导入页分四个阶段（选视频、分析范围、检测区域、确认并分析），步骤 id 以阶段名开头。
const Map<String, List<String>> onboardingStepIds = {
  onboardingImportPage: [
    'import.steps',
    'import.pick',
    'range.window',
    'calibrate.hoop',
    'calibrate.regions',
    'analysis.clip',
    'analysis.mode',
    'analysis.start',
  ],
  onboardingReviewPage: [
    'review.video',
    'review.queue',
    'review.filter',
    'review.batch',
    'review.shortcuts',
    'review.tag',
    'review.range',
    'review.source',
    'review.missed',
  ],
  onboardingExportPage: ['export.mode', 'export.tag', 'export.start'],
};

final List<String> allOnboardingStepIds = [
  for (final ids in onboardingStepIds.values) ...ids,
];

/// 旧版按页面记录时，一个页面“看过”意味着这些步骤看过。
const Map<String, List<String>> _legacyPageSteps = {
  'review': ['review.video', 'review.queue'],
  'export': ['export.mode', 'export.start'],
};

class OnboardingState {
  const OnboardingState({
    this.loaded = false,
    this.seen = const <String>{},
    this.replay = const <String, int>{},
    this.resets = 0,
  });

  final bool loaded;

  /// 已看过的步骤 id。
  final Set<String> seen;

  /// 每个页面的“重看”计数，变化即表示要从第一步重新开始。
  final Map<String, int> replay;

  /// 「重置新手引导」的次数；页面据此清掉本次会话里的“已关闭”标志，重置后能再弹。
  final int resets;
}

/// 新手引导的“看过”状态，按页面记录，存在本地偏好里。
///
/// 升级用户（偏好里已有最近项目但没有引导记录）一律视为看过，不弹；
/// 偏好读失败时同样不弹，只在“?”里留入口。
class OnboardingNotifier extends Notifier<OnboardingState> {
  @override
  OnboardingState build() {
    unawaited(_load());
    return const OnboardingState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(onboardingStepsPrefsKey);
      if (saved != null) {
        state = OnboardingState(
          loaded: true,
          seen: {...saved, ...state.seen},
          replay: state.replay,
          resets: state.resets,
        );
        return;
      }
      final legacy = prefs.getStringList(onboardingLegacySeenPrefsKey);
      final upgraded = prefs.containsKey(recentProjectRootsPrefsKey);
      final migrated = <String>{
        if (legacy != null)
          for (final page in legacy) ...?_legacyPageSteps[page],
        if (legacy == null && upgraded) ...allOnboardingStepIds,
      };
      state = OnboardingState(
        loaded: true,
        seen: {...migrated, ...state.seen},
        replay: state.replay,
        resets: state.resets,
      );
      if (migrated.isNotEmpty) await _persist();
    } catch (error) {
      appLog('warn', 'onboarding', '读取引导状态失败，本次不弹引导: $error');
      state = OnboardingState(
        loaded: true,
        seen: allOnboardingStepIds.toSet(),
        replay: state.replay,
        resets: state.resets,
      );
    }
  }

  /// 把这些步骤记为看过（按步骤，不是按页面）。
  Future<void> markSeen(Iterable<String> stepIds) async {
    final added = stepIds.toSet().difference(state.seen);
    if (added.isEmpty) return;
    state = OnboardingState(
      loaded: state.loaded,
      seen: {...state.seen, ...added},
      replay: state.replay,
      resets: state.resets,
    );
    await _persist();
  }

  /// 设置里的“重置新手引导”：清空看过记录，下次进入各页面会再弹。
  Future<void> reset() async {
    state = OnboardingState(
      loaded: true,
      replay: state.replay,
      resets: state.resets + 1,
    );
    await _persist();
  }

  /// 页面上的“?”：不管看没看过，从第一步重看。
  void replay(String page) {
    state = OnboardingState(
      loaded: state.loaded,
      seen: state.seen,
      replay: {...state.replay, page: (state.replay[page] ?? 0) + 1},
      resets: state.resets,
    );
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 空列表也要存：没有这个键会被当成“升级用户”。
      await prefs.setStringList(onboardingStepsPrefsKey, state.seen.toList());
    } catch (error) {
      appLog('warn', 'onboarding', '保存引导状态失败: $error');
    }
  }
}

final onboardingProvider =
    NotifierProvider<OnboardingNotifier, OnboardingState>(
      OnboardingNotifier.new,
    );
