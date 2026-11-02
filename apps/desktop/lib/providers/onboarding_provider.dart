import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_log.dart';
import 'project_state.dart' show recentProjectRootsPrefsKey;

const String onboardingSeenPrefsKey = 'bhe.onboarding.seen';
const String onboardingReviewPage = 'review';
const String onboardingExportPage = 'export';
const List<String> onboardingPages = [
  onboardingReviewPage,
  onboardingExportPage,
];

class OnboardingState {
  const OnboardingState({
    this.loaded = false,
    this.seen = const <String>{},
    this.replay = const <String, int>{},
  });

  final bool loaded;
  final Set<String> seen;

  /// 每个页面的“重看”计数，变化即表示要从第一步重新开始。
  final Map<String, int> replay;
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
      final saved = prefs.getStringList(onboardingSeenPrefsKey);
      if (saved != null) {
        state = OnboardingState(
          loaded: true,
          seen: {...saved, ...state.seen},
          replay: state.replay,
        );
        return;
      }
      final upgraded = prefs.containsKey(recentProjectRootsPrefsKey);
      state = OnboardingState(
        loaded: true,
        seen: upgraded ? onboardingPages.toSet() : state.seen,
        replay: state.replay,
      );
      if (upgraded) await _persist();
    } catch (error) {
      appLog('warn', 'onboarding', '读取引导状态失败，本次不弹引导: $error');
      state = OnboardingState(
        loaded: true,
        seen: onboardingPages.toSet(),
        replay: state.replay,
      );
    }
  }

  Future<void> markSeen(String page) async {
    if (state.seen.contains(page)) return;
    state = OnboardingState(
      loaded: state.loaded,
      seen: {...state.seen, page},
      replay: state.replay,
    );
    await _persist();
  }

  /// 设置里的“重置新手引导”：清空看过记录，下次进入各页面会再弹。
  Future<void> reset() async {
    state = OnboardingState(loaded: true, replay: state.replay);
    await _persist();
  }

  /// 页面上的“?”：不管看没看过，从第一步重看。
  void replay(String page) {
    state = OnboardingState(
      loaded: state.loaded,
      seen: state.seen,
      replay: {...state.replay, page: (state.replay[page] ?? 0) + 1},
    );
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 空列表也要存：没有这个键会被当成“升级用户”。
      await prefs.setStringList(onboardingSeenPrefsKey, state.seen.toList());
    } catch (error) {
      appLog('warn', 'onboarding', '保存引导状态失败: $error');
    }
  }
}

final onboardingProvider =
    NotifierProvider<OnboardingNotifier, OnboardingState>(
      OnboardingNotifier.new,
    );
